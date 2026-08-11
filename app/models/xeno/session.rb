# frozen_string_literal: true

module Xeno
  # The durable conversation: lives for days or weeks, owns the transcript
  # chat, the turn ledger, and the append-only event stream. Identified by
  # id (inspect/stream handle) and at most one continuation_token (the
  # channel-owned resume handle, unique among active sessions).
  class Session < ApplicationRecord
    enum :status, %w[running waiting completed failed].index_with(&:itself), validate: true

    belongs_to :chat, class_name: "Xeno::Chat"
    has_many :turns, class_name: "Xeno::Turn", dependent: :destroy
    has_many :events, class_name: "Xeno::Event", dependent: :destroy
    has_many :pending_messages, class_name: "Xeno::PendingMessage", dependent: :destroy

    # Opens a session for a first user message: builds the transcript chat
    # per the resolved agent definition, stamps channel + principal, and
    # stages turn 1. The caller enqueues the returned turn's job after the
    # transaction commits (Session.start! does both).
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

    # Stages the next turn for one or more messages: persists each user
    # message into the transcript, refreshes instructions (each turn picks up
    # edited instructions without a restart), and
    # appends the turn row. Runs in the caller's process so TurnJob replays
    # never double-add the user message.
    #
    # defer_transcript: the turn row carries the messages but nothing is
    # written into the transcript yet — the runner stages it when the turn
    # is claimed. Required whenever an EARLIER turn may still be mid-flight
    # (drained turns): appending user rows behind a parked turn's unanswered
    # tool calls would wedge every later generate (providers demand tool
    # results immediately after the assistant's tool_calls message).
    def stage_turn!(messages, definition: Xeno.definition, emit_received: true, defer_transcript: false)
      contents = Array(messages)
      transaction do
        unless defer_transcript
          # with_instructions triggers the first to_llm build, so a fresh chat
          # record must get its runtime options back first. nil clears: an
          # agent whose instructions were removed sheds the stale system row.
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

    # The channel entry point for follow-up messages. While a turn is active
    # (one active turn per session) the message queues in pending_messages
    # and is folded into the next turn; a PARKED session drains immediately
    # (the message becomes a visible staged turn instead of sitting invisible
    # until someone resolves the input).
    # An idle session stages and enqueues a turn right away.
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

    # Folds every queued message into ONE next turn. Called when a turn
    # parks or reaches a terminal status (and on messages to a parked
    # session). Always defers the transcript: the drained turn may sit
    # behind a parked turn whose tool calls are still unanswered, so its
    # user rows are written only when the runner claims it — turn order and
    # transcript order can never diverge. Row locks make a racing drain
    # (park vs. incoming message) fold each message exactly once.
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

    # Steering (opt-in per message): stop what the agent is doing and make
    # THIS message the next turn. The active turn dies safely — a parked or
    # pending turn settles its dangling tool calls (recorded answers
    # injected, unapproved gates denied — the H1 machinery) and cancels
    # immediately; a running turn cancels cooperatively (the steer message
    # queues and the runner's cancel path folds it into the next turn at the
    # next step boundary). If the cancel loses the race with a completing
    # turn, steering degrades to a normal follow-up — never an error.
    def steer!(content, definition: Xeno.definition)
      turn = turns.active.order(:sequence).first

      case turn&.status
      when nil # idle: steer is just a message
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

    # Stages a compaction turn (summarize-and-replace, executed by the
    # runner under a normal claim). It queues behind any active or parked
    # turn via the ordinary session-ordering machinery — the
    # queued-behind-the-active-turn semantics — and never appends a
    # synthetic user message.
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

    # Called before a turn dies with tool calls still unanswered (cancel
    # while parked, schedule park failure): every dangling call gets a tool
    # result in the transcript. Without this the assistant tool_call rows
    # stay unanswered forever and every later generate is a provider 400 —
    # the session is bricked. A completed action (e.g. an answered question
    # whose resume never ran) injects its recorded output; everything else
    # gets a denial, recorded on the action row as the audit trail.
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

    # Terminal states release the continuation token (a finished session must
    # not squat a channel thread's token); a copy stays in metadata for audit.
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
