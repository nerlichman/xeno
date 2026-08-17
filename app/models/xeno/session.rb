# frozen_string_literal: true

module Xeno
  # = Sessions
  #
  # A session is one durable conversation with the agent. It can live for days or weeks and
  # survive deploys, crashes, and restarts, because everything it is lives in rows: the transcript
  # chat, the turn ledger, and the append-only event stream.
  #
  # A session is identified two ways. The id is the stable handle for inspection and streaming.
  # The continuation_token is the resume handle a channel owns — this Slack thread, this HTTP
  # client — unique among active sessions and released when the session ends, so the same token
  # can start fresh.
  class Session < ApplicationRecord
    enum :status, %w[running waiting completed failed].index_with(&:itself), validate: true

    belongs_to :chat, class_name: "Xeno::Chat"
    has_many :turns, class_name: "Xeno::Turn", dependent: :destroy
    has_many :events, class_name: "Xeno::Event", dependent: :destroy
    has_many :pending_messages, class_name: "Xeno::PendingMessage", dependent: :destroy

    # Opens a session for a first user message: builds the transcript chat per the resolved agent
    # definition, stamps channel + principal, and stages turn 1. The caller enqueues the returned
    # turn's job after the transaction commits (Session.start! does both).
    def self.open!(message:, channel: nil, principal: nil, continuation_token: nil, definition: Xeno.definition)
      transaction do
        chat = Chat.new
        options = definition.config.model_options
        chat.apply_runtime_options!(options)
        chat.provider = options[:provider].to_s if options[:provider]
        chat.model = definition.config.resolved_model
        chat.save!

        session = create!(
          agent: definition.name,
          chat: chat,
          channel: channel,
          principal: principal,
          continuation_token: continuation_token
        )
        session.emit("session.started", { agent: definition.name, channel: channel })
        session.stage_turn!(message, definition: definition)
        session
      end
    end

    # Convenience for callers without transactional needs: open + enqueue.
    def self.start!(message:, **options)
      session = open!(message: message, **options)
      session.turns.last.enqueue!
      session
    end

    # Stages the next turn for one or more messages: persists each user message, refreshes
    # instructions, and appends the turn row. Runs in the caller's process so TurnJob replays never
    # double-add the user message.
    #
    # defer_transcript: the turn row carries the messages and the runner writes them at claim time.
    # Required whenever an earlier turn may still be mid-flight — appending user rows behind
    # unanswered tool calls would wedge every later generate.
    def stage_turn!(messages, definition: Xeno.definition, emit_received: true, defer_transcript: false)
      contents = Array(messages)
      transaction do
        unless defer_transcript
          # with_instructions triggers the first to_llm build, so a fresh chat record must get its
          # runtime options back first. nil clears: an agent whose instructions were removed sheds
          # the stale system row.
          chat.apply_runtime_options!(definition.config.model_options)
          chat.with_instructions(definition.instructions_for(session: self))
          contents.each { |content| chat.add_message(role: :user, content: content) }
        end
        turn = Turn.append!(self, user_message: { contents: contents }, transcript_deferred: defer_transcript)
        if emit_received
          contents.each { |content| emit("message.received", { content: content, turn_id: turn.id }) }
        end
        emit("turn.started", { turn_id: turn.id, sequence: turn.sequence })
        turn
      end
    end

    # The channel entry point for follow-up messages. While a turn is active the message queues in
    # pending_messages and folds into the next turn; a parked session drains immediately, so the
    # message becomes a visible staged turn. An idle session stages and enqueues right away.
    def receive_message!(content)
      if turns.active.exists?
        transaction do
          pending_messages.create!(payload: { "content" => content })
          emit("message.received", { content: content, queued: true })
        end
        drain_pending_messages! if reload.waiting?
        nil
      else
        turn = stage_turn!(content)
        turn.enqueue!
        turn
      end
    end

    # Folds every queued message into one next turn, called when a turn parks or ends and on
    # messages to a parked session. Always defers the transcript: the drained turn may sit behind
    # unanswered tool calls, so its user rows are written only at claim — turn order and transcript
    # order can never diverge. Row locks make a racing drain fold each message exactly once.
    def drain_pending_messages!(definition: Xeno.definition)
      turn = nil
      transaction do
        queued = pending_messages.order(:id).lock.to_a
        next if queued.empty?

        contents = queued.map { |m| m.payload["content"] }
        turn = stage_turn!(contents, definition: definition, emit_received: false, defer_transcript: true)
        queued.each(&:destroy!)
      end
      turn
    end

    # Steering (opt-in per message): stop what the agent is doing and make this message the next
    # turn. A parked or pending turn settles its dangling tool calls and cancels immediately; a
    # running turn cancels cooperatively at the next step boundary. If the cancel loses the race
    # with a completing turn, steering degrades to a normal follow-up — never an error.
    def steer!(content, definition: Xeno.definition)
      turn = turns.active.order(:sequence).first

      case turn&.status
      when nil # idle: steer degrades to a plain follow-up message
        staged = stage_turn!(content, definition: definition)
        staged.enqueue!
        staged
      when "running"
        transaction do
          pending_messages.create!(payload: { "content" => content })
          emit("message.received", { content: content, queued: true, steer: true })
        end
        chat.cancel! # cooperative; the runner settles, cancels, and drains
        nil
      else # pending or waiting — no process owns it; replace it now
        transaction do
          settle_unanswered_tool_calls!(turn, reason: "steered by user")
          turn.update!(status: "cancelled")
          emit("turn.cancelled", { turn_id: turn.id, steer: true })
          update!(status: "running") if waiting?
        end
        staged = stage_turn!(content, definition: definition)
        staged.enqueue!
        staged
      end
    end

    # Stages a compaction turn (summarize-and-replace, executed by the runner under a normal claim).
    # It queues behind any active or parked turn via the ordinary session-ordering machinery and
    # never appends a synthetic user message.
    def stage_compaction_turn!(reason:, used: nil, limit: nil)
      transaction do
        request = { "reason" => reason, "used" => used, "limit" => limit }.compact
        turn = Turn.append!(self, kind: "compaction", user_message: { "compaction" => request })
        emit("compaction.requested", { "turn_id" => turn.id }.merge(request))
        emit("turn.started", { turn_id: turn.id, sequence: turn.sequence })
        turn
      end
    end

    def emit(event_type, data = {})
      Event.append!(self, event_type, data)
    end

    # Called before a turn dies with tool calls still unanswered: every dangling call gets a tool
    # result in the transcript. Without this the unanswered rows make every later generate a
    # provider 400 and the session is bricked. A completed action injects its recorded output;
    # everything else gets a denial, recorded on the action row.
    def settle_unanswered_tool_calls!(turn, reason:)
      chat_record = Chat.find(chat_id)
      llm = chat_record.to_llm
      last_assistant = llm.messages.reverse.find { |m| m.role == :assistant }
      return unless last_assistant&.tool_call?

      answered = llm.messages.select { |m| m.role == :tool }.map(&:tool_call_id).compact.to_set
      last_assistant.tool_calls.values.reject { |call| answered.include?(call.id) }.each do |call|
        action = turn.actions.find_by(tool_call_id: call.id)
        if action&.completed?
          content = action.output&.fetch("content", nil).to_s
          status = "completed"
        else
          content = JSON.generate({ denied: true, reason: reason })
          status = "denied"
        end

        transaction do
          action.update!(status: "denied", output: { "content" => content }) if action && status == "denied"
          chat_record.add_message(role: :tool, content: content, tool_call_id: call.id)
        end
        emit("action.result", { turn_id: turn.id, call_id: call.id, tool: call.name, status: status })
      end
    end

    # The session-scoped KV store (see Xeno::SessionState).
    def state
      @state_handle ||= SessionState.new(self)
    end

    def active?
      running? || waiting?
    end

    # Terminal states release the continuation token (a finished session must not squat a channel
    # thread's token); a copy stays in metadata for audit.
    def finish!(new_status)
      raise ArgumentError, "not a terminal status: #{new_status}" unless %w[completed failed].include?(new_status)

      transaction do
        audit = (metadata || {}).merge("released_continuation_token" => continuation_token)
        # State is working memory for the conversation; reset clears it.
        update!(status: new_status, continuation_token: nil, metadata: audit, state: {})
        emit("session.#{new_status}")
      end
    end
  end
end
