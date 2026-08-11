# frozen_string_literal: true

require "openssl"
require "net/http"

module Xeno
  module Channels
    # The Slack channel: Events API webhook with constant-time signature
    # verification, thread-scoped sessions (continuation token =
    # "slack:<channel>:<thread_ts>"), replies posted at turn completion,
    # and plain-text approvals ("approve"/"deny"/an answer) in the thread.
    #
    # v0.1 scope: mentions and DMs start sessions; thread replies continue
    # them. Post-then-edit streaming and Block Kit buttons are v0.2.
    class Slack
      SIGNATURE_VERSION = "v0".freeze
      TIMESTAMP_TOLERANCE = 300 # seconds; replayed webhooks are rejected

      APPROVE_WORDS = %w[approve approved yes y ok 👍].freeze
      DENY_WORDS = %w[deny denied no n reject rejected 👎].freeze

      def initialize(&block)
        @api_base = "https://slack.com/api"
        instance_eval(&block) if block
      end

      # --- the config DSL (setter-and-reader hybrids, like AgentConfig) ---

      def signing_secret(value = nil)
        @signing_secret = value if value
        @signing_secret
      end

      def bot_token(value = nil)
        @bot_token = value if value
        @bot_token
      end

      # Overridable for offline tests (the fake Slack API).
      def api_base(value = nil)
        @api_base = value if value
        @api_base
      end

      # Opt-in post-then-edit streaming: the reply posts on the first model
      # delta and is edited (~1s cadence, rate-limit aware) until the final
      # text lands. Off by default — replies post once at completion.
      def stream_replies(value = nil)
        @stream_replies = value unless value.nil?
        @stream_replies
      end

      # --- inbound: webhook verification + event handling ---

      def verify_signature(timestamp, signature, raw_body)
        return false if signing_secret.blank? || timestamp.blank? || signature.blank?
        return false if (Time.now.to_i - timestamp.to_i).abs > TIMESTAMP_TOLERANCE

        base = "#{SIGNATURE_VERSION}:#{timestamp}:#{raw_body}"
        digest = OpenSSL::HMAC.hexdigest("sha256", signing_secret, base)
        expected = "#{SIGNATURE_VERSION}=#{digest}"
        ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      end

      def handle_event(payload)
        event = payload["event"] || {}
        return if event["bot_id"].present? # never talk to ourselves

        case event["type"]
        when "app_mention"
          handle_message(event)
        when "message"
          # DMs only; edits/joins/etc. carry a subtype and are ignored.
          handle_message(event) if event["channel_type"] == "im" && event["subtype"].blank?
        end
      end

      # --- outbound: delivery ---

      def deliver_completion(session, content)
        channel_id, thread_ts = thread_for(session)
        return unless channel_id

        post_message(channel: channel_id, thread_ts: thread_ts, text: content.to_s)
      end

      # One per content-bearing model reply when stream_replies is on: the
      # runner pushes deltas, we post-then-edit in the thread.
      def streamer_for(session)
        return nil unless stream_replies

        channel_id, thread_ts = thread_for(session)
        return nil unless channel_id

        Streamer.new(self, channel: channel_id, thread_ts: thread_ts)
      end

      def deliver_input_request(session, actions)
        channel_id, thread_ts = thread_for(session)
        return unless channel_id

        prompts = actions.map do |action|
          if action.kind == "question"
            question = action.input&.dig("question")
            choices = Array(action.input&.dig("choices"))
            choices.any? ? "❓ #{question} (#{choices.join(' / ')})" : "❓ #{question}"
          else
            "⏸ Approval needed: `#{action.tool_name}(#{action.input.to_json})` — reply *approve* or *deny*."
          end
        end
        post_message(channel: channel_id, thread_ts: thread_ts, text: prompts.join("\n"))
      end

      # Raised by api_post on HTTP 429; carries Slack's Retry-After.
      class RateLimited < Xeno::Error
        attr_reader :retry_after

        def initialize(retry_after:)
          @retry_after = [ retry_after.to_f, 1.0 ].max
          super("slack rate limited (retry after #{@retry_after}s)")
        end
      end

      # Post-then-edit delivery for ONE streaming model reply. The first
      # content delta posts the thread message; later deltas edit it at most
      # once per EDIT_INTERVAL; finish writes the durable final text. Rate
      # limits defer the next edit (Retry-After); any hard failure turns
      # streaming off for this reply — the completion post is the fallback,
      # and the durable truth is rows either way.
      class Streamer
        EDIT_INTERVAL = 1.0 # seconds — comfortably under chat.update's tier

        def initialize(slack, channel:, thread_ts:)
          @slack = slack
          @channel = channel
          @thread_ts = thread_ts
          @buffer = +""
          @ts = nil
          @posted_text = nil
          @next_edit_at = 0.0
          @dead = false
        end

        def push(chunk)
          content = chunk.respond_to?(:content) ? chunk.content : nil
          return if @dead || content.to_s.empty?

          @buffer << content
          @ts.nil? ? start_message : edit_message(@buffer.dup)
        end

        # Returns true when this streamer delivered the reply (the runner
        # then skips the completion post); false hands delivery back.
        def finish(final_text)
          return false if @ts.nil?

          text = final_text.to_s
          return true if @posted_text == text

          wait = @next_edit_at - now
          sleep([ wait, 3.0 ].min) if wait.positive? # respect a pending rate-limit window
          @slack.api_post("chat.update", channel: @channel, ts: @ts, text: text)
          @posted_text = text
          true
        rescue StandardError => e
          Rails.logger.warn("xeno: slack streaming final edit failed: #{e.class}: #{e.message}")
          false
        end

        private

        def start_message
          payload = @slack.api_post("chat.postMessage",
                                    channel: @channel, thread_ts: @thread_ts, text: @buffer.dup)
          @ts = payload["ts"]
          @posted_text = @buffer.dup
          @next_edit_at = now + EDIT_INTERVAL
        rescue StandardError => e
          @dead = true
          Rails.logger.warn("xeno: slack streaming post failed: #{e.class}: #{e.message}")
        end

        def edit_message(text)
          return if now < @next_edit_at

          @slack.api_post("chat.update", channel: @channel, ts: @ts, text: text)
          @posted_text = text
          @next_edit_at = now + EDIT_INTERVAL
        rescue RateLimited => e
          @next_edit_at = now + e.retry_after
        rescue StandardError => e
          @dead = true
          Rails.logger.warn("xeno: slack streaming edit failed: #{e.class}: #{e.message}")
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # One JSON POST to the Slack Web API; 429 becomes RateLimited (with
      # Retry-After), any other failure raises Xeno::Error.
      def api_post(method, payload)
        uri = URI("#{api_base}/#{method}")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{bot_token}"
        request["Content-Type"] = "application/json; charset=utf-8"
        request.body = JSON.generate(payload)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 10) do |http|
          http.request(request)
        end
        parsed = JSON.parse(response.body) rescue {}

        raise RateLimited.new(retry_after: response["Retry-After"]) if response.code.to_i == 429
        unless response.is_a?(Net::HTTPSuccess) && parsed["ok"]
          raise Xeno::Error, "slack #{method} failed: #{response.code} #{parsed['error']}"
        end

        parsed
      end

      private

      def handle_message(event)
        text = strip_mention(event["text"].to_s).strip
        return if text.empty?

        channel_id = event["channel"]
        thread_ts = event["thread_ts"] || event["ts"]
        token = "slack:#{channel_id}:#{thread_ts}"
        principal = {
          "type" => "slack",
          "user_id" => event["user"],
          "team_id" => event["team"],
          "channel_id" => channel_id
        }

        session = Session.find_by(continuation_token: token)
        if session&.active?
          continue_session(session, text, principal)
        else
          Session.start!(message: text, channel: "slack", principal: principal, continuation_token: token)
        end
      end

      # A reply into a waiting thread resolves the FIRST pending input; an
      # unrelated reply is HELD as the next message (never auto-deny, never
      # a forced answer):
      # - approvals: approve/deny words resolve; anything else holds.
      # - questions with choices: match by 1-based index ("2"), by label
      #   (case-insensitive), or by exact option text; no match holds and
      #   the question stays pending.
      # - free-form questions (no choices): any text is the answer.
      def continue_session(session, text, principal)
        pending = Action.joins(:turn)
                        .where(xeno_turns: { session_id: session.id }, status: "pending_approval")
                        .order(:id)
                        .first

        if pending && session.status == "waiting"
          if pending.kind == "question"
            answer = match_answer(pending, text)
            if answer
              Inputs.answer!(pending, answer, principal: principal)
            else
              session.receive_message!(text) # held; the question stays pending
            end
          elsif APPROVE_WORDS.include?(text.downcase)
            Inputs.approve!(pending, principal: principal)
          elsif DENY_WORDS.include?(text.downcase)
            Inputs.deny!(pending, principal: principal)
          else
            session.receive_message!(text) # held; the approval stays pending
          end
        else
          session.receive_message!(text)
        end
      end

      # The resolved answer for a question, or nil to hold the reply.
      def match_answer(action, text)
        choices = Array(action.input&.dig("choices")).map(&:to_s)
        return text if choices.empty? # free-form: any text answers

        normalized = text.strip
        if normalized.match?(/\A\d+\z/)
          index = normalized.to_i
          return choices[index - 1] if index.between?(1, choices.size)
        end

        choices.find { |choice| choice.casecmp?(normalized) }
      end

      def strip_mention(text)
        text.gsub(/<@[A-Z0-9]+>/, " ")
      end

      def thread_for(session)
        token = session.continuation_token ||
                session.metadata&.dig("released_continuation_token")
        return nil unless token&.start_with?("slack:")

        _prefix, channel_id, thread_ts = token.split(":", 3)
        [ channel_id, thread_ts ]
      end

      def post_message(channel:, thread_ts:, text:)
        api_post("chat.postMessage", channel: channel, thread_ts: thread_ts, text: text)
      end
    end
  end
end
