# frozen_string_literal: true

module Xeno
  # The channel registry. A channel (a) normalizes platform input into user
  # messages, (b) owns the session's continuation token, and (c) decides
  # delivery of agent output. HTTP is built in; agent/channels/*.rb declare
  # the rest via the DSL:
  #
  #   Xeno.channel :slack do
  #     signing_secret Rails.application.credentials.dig(:slack, :signing_secret)
  #     bot_token     Rails.application.credentials.dig(:slack, :bot_token)
  #   end
  #
  # Delivery is a failable nicety: the durable truth lives in the transcript
  # and event rows, so a failed post logs and moves on.
  module Channels
    module_function

    def registry
      @registry ||= {}
    end

    def register(name, channel)
      registry[name.to_sym] = channel
    end

    def build(name, &block)
      case name.to_sym
      when :slack
        Slack.new(&block)
      else
        raise Xeno::Error, "unknown channel type: #{name} (v0.1 ships :slack; http is built in)"
      end
    end

    def for_session(session)
      registry[session.channel&.to_sym]
    end

    def deliver_completion(session, content)
      for_session(session)&.deliver_completion(session, content)
    rescue StandardError => e
      Rails.logger.warn("xeno: channel delivery failed for session #{session.id}: #{e.class}: #{e.message}")
    end

    def deliver_input_request(session, actions)
      for_session(session)&.deliver_input_request(session, actions)
    rescue StandardError => e
      Rails.logger.warn("xeno: channel input-request delivery failed for session #{session.id}: #{e.class}: #{e.message}")
    end

    # A per-reply delta sink (post-then-edit streaming) when the session's
    # channel opts in; nil otherwise. Failable nicety like all delivery.
    def streamer_for(session)
      channel = for_session(session)
      return nil unless channel.respond_to?(:streamer_for)

      channel.streamer_for(session)
    rescue StandardError => e
      Rails.logger.warn("xeno: channel streamer setup failed for session #{session.id}: #{e.class}: #{e.message}")
      nil
    end
  end

  def self.channel(name, &block)
    channel = Channels.build(name, &block)
    Channels.register(name, channel)
    channel
  end
end
