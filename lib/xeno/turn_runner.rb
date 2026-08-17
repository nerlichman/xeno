# frozen_string_literal: true

module Xeno
  # Drives one turn to completion or to a park, checkpointing every move in the database. Uses
  # RubyLLM's decomposed loop — `generate`, self-executed tools, `add_message` injection — and never
  # `run_tools` (no approval gate, no per-call checkpoint) or `complete` (a turn must bound its
  # model calls).
  #
  # Invariants:
  # - A tool execution and its transcript injection commit in one
  #   transaction; recorded calls are never re-run.
  # - Every write is fenced on the claim token; a zombie affects zero rows.
  # - Trailing blank assistant rows (mid-generate crash artifacts) are
  #   removed before anything else.
  class TurnRunner # :nodoc:
    include Compaction

    attr_reader :turn, :session, :definition, :token

    def initialize(turn, definition: Xeno.definition)
      @turn = turn
      @session = turn.session
      @definition = definition
    end

    def run
      @token = turn.claim!
      return :not_claimed unless token

      ActiveSupport::Notifications.instrument("xeno.turn", turn_id: turn.id, session_id: session.id) do
        run_claimed
      end
    rescue Xeno::Fenced
      :fenced
    end

    private

    def run_claimed
      # A pristine record instance: a memoized to_llm built elsewhere (e.g. by stage_turn! in this
      # same process) would ignore the runtime attrs prepare_chat sets (protocol,
      # assume_model_exists).
      @chat = Chat.find(session.chat_id)
      clear_stale_cancellation

      if turn.kind == "compaction"
        run_compaction
        return :completed
      end

      prepare_chat
      remove_crash_artifacts
      stage_deferred_transcript!

      loop do
        checkpoint_shutdown!

        calls = unanswered_tool_calls
        if calls.any?
          resolve_tool_calls(calls)
        elsif @chat.complete?
          break
        else
          generate_step
        end
      end

      complete_turn
      :completed
    rescue Xeno::Interrupted
      interrupt_turn
      :interrupted
    rescue Xeno::Parked => parked
      # Schedules have no human to wait for: a gated tool (or ask_question) in a schedule run
      # deterministically fails the turn.
      if session.channel == "schedule"
        fail_schedule_park
        :failed
      else
        park_turn(parked.actions)
        :parked
      end
    rescue RubyLLM::CancelledError
      cancel_turn
      :cancelled
    rescue Xeno::BudgetExceeded => e
      session.emit("budget.exceeded", {
        turn_id: turn.id, axis: e.axis, used: e.used, limit: e.limit
      })
      fail_turn(e)
      :failed
    rescue Xeno::MaxStepsExceeded => e
      fail_turn(e)
      :failed
    rescue Xeno::Fenced
      raise
    rescue StandardError => e
      release_for_retry(e)
      raise
    end

    # assume_model_exists and protocol are not persisted on the chat record — every process
    # re-applies them from the definition before the first to_llm build (which with_tools triggers).
    def prepare_chat
      @chat.apply_runtime_options!(definition.config.model_options)
      @chat.with_tools(Xeno::AskQuestion, *definition.tool_classes)
    end

    # A cancellation flag set before this turn claimed targeted work that no longer exists; clear
    # it. Cancellation is cooperative, so a cancel landing between the claim and this clear is an
    # accepted loss.
    def clear_stale_cancellation
      Chat.where(id: @chat.id, cancelled: true).update_all(cancelled: false)
    end

    # A kill mid-generate leaves a blank assistant row. Trailing blank assistant rows are crash
    # artifacts; delete them.
    def remove_crash_artifacts
      loop do
        last = @chat.messages_association.order(:id).last
        break unless last&.role == "assistant" && last.content.blank? && !last.tool_call?

        last.destroy!
        @chat.messages_association.reset
      end
      sync_llm_messages
    end

    def sync_llm_messages
      @chat.reload
    end

    # A drained turn carries its user messages in the turn row until it is claimed; appending
    # earlier would corrupt a mid-flight transcript. The appends and the flag flip commit together
    # and the flip is fenced, so a crash replays and a zombie stages nothing. Instructions refresh
    # here too.
    def stage_deferred_transcript!
      return unless turn.transcript_deferred?

      contents = Array(turn.user_message&.fetch("contents", nil))
      ActiveRecord::Base.transaction do
        @chat.with_instructions(definition.instructions_for(session: session))
        contents.each { |content| @chat.add_message(role: :user, content: content) }
        turn.fenced_update!(token, transcript_deferred: false)
      end
      sync_llm_messages
    end

    # Unanswered tool calls from the last assistant message, in request order.
    def unanswered_tool_calls
      llm = @chat.to_llm
      last_assistant = llm.messages.reverse.find { |m| m.role == :assistant }
      return [] unless last_assistant&.tool_call?

      answered = llm.messages.select { |m| m.role == :tool }.map(&:tool_call_id).compact.to_set
      last_assistant.tool_calls.values.reject { |call| answered.include?(call.id) }
    end

    # Resolves the batch: replays recorded work, injects denials, executes what may run, and
    # collects what needs a human. Ungated calls in a mixed batch execute before the park; the
    # resume replays their recorded results.
    def resolve_tool_calls(calls)
      blocking = []

      calls.each do |call|
        kind = call.name == "ask_question" ? "question" : "tool"
        action = Action.record!(turn, call, kind: kind)

        next if replay_completed_action(action, call)
        next if replay_denied_action(action, call)
        next if replay_failed_action(action, call)

        case action.status
        when "pending_approval"
          blocking << action # parked before; still unresolved
        when "approved"
          execute_action(action, call)
        else # pending
          if kind == "question"
            blocking << request_input(action, call)
          elsif approval_required?(call)
            blocking << request_input(action, call)
          else
            execute_action(action, call)
          end
        end
      end

      raise Xeno::Parked.new(actions: blocking) if blocking.any?
    end

    def approval_required?(call)
      tool_class = definition.tools[call.name]
      return false unless tool_class.respond_to?(:approval)

      # A tool declaring RubyLLM's requires_approval without a xeno policy gets the gate. An
      # explicit xeno policy, even :never, wins.
      if tool_class.respond_to?(:approval_declared?) && !tool_class.approval_declared? &&
         tool_class.respond_to?(:requires_approval?) && tool_class.requires_approval?
        return true
      end

      policy = tool_class.approval
      case policy
      when :never, nil then false
      when :always then true
      when :once then !previously_approved?(call.name)
      when Proc then !!policy.call(approval_context(call))
      else
        raise Xeno::Error, "unknown approval policy #{policy.inspect} on #{tool_class}"
      end
    end

    # :once — an approval granted earlier in this session covers later calls.
    def previously_approved?(tool_name)
      Action.joins(:turn)
            .where(xeno_turns: { session_id: session.id })
            .where(tool_name: tool_name)
            .where.not(resolved_at: nil)
            .where(status: %w[approved completed])
            .exists?
    end

    def approval_context(call)
      ApprovalContext.new(
        session: session, turn: turn,
        tool_name: call.name, arguments: call.arguments,
        principal: session.principal
      )
    end

    def request_input(action, call)
      action.update!(status: "pending_approval")
      session.emit("input.requested", {
        turn_id: turn.id,
        action_id: action.id,
        call_id: call.id,
        kind: action.kind,
        tool: call.name,
        arguments: call.arguments
      })
      action
    end

    def replay_denied_action(action, call)
      return false unless action.status == "denied"

      unless answered?(call)
        content = action.output&.fetch("content", nil) || JSON.generate({ denied: true })
        inject_result(call, content)
        session.emit("action.result", {
          turn_id: turn.id, call_id: call.id, tool: call.name, status: "denied"
        })
      end
      true
    end

    def answered?(call)
      @chat.to_llm.messages.any? { |m| m.role == :tool && m.tool_call_id == call.id }
    end

    # A completed action whose result is not yet in the transcript — an answered question, or a
    # self-heal after replay. Inject the recorded output; never re-execute.
    def replay_completed_action(action, call)
      return false unless action.completed?

      unless answered?(call)
        inject_result(call, action.output&.fetch("content", nil).to_s)
        session.emit("action.result", {
          turn_id: turn.id, call_id: call.id, tool: call.name, status: "completed"
        })
      end
      true
    end

    # A raising tool must not reach the queue's retry ladder — without the action-row checkpoint
    # every retry would re-execute it. The exception becomes an error tool result the model can
    # recover from, and the failed action replays like any other checkpoint.
    def execute_action(action, call)
      tool_class = definition.tools[call.name]
      failure = nil
      content =
        if tool_class
          arguments, argument_errors = Arguments.coerce(tool_class, call.arguments)
          if argument_errors.any?
            failure = Xeno::Error.new("invalid arguments: #{argument_errors.join('; ')}")
            JSON.generate({ error: "invalid arguments for #{call.name}", details: argument_errors })
          else
            begin
              result = ActiveSupport::Notifications.instrument("xeno.action", turn_id: turn.id, tool: call.name) do
                tool = tool_class.new
                tool.session = session
                with_heartbeat { tool.call(arguments, tool_call: call) }
              end
              stringify_result(result)
            rescue StandardError => e
              failure = e
              JSON.generate({ error: "#{call.name} raised #{e.class.name}: #{e.message}" })
            end
          end
        else
          JSON.generate({ error: "unknown tool: #{call.name}" })
        end

      turn.heartbeat!(token)
      ActiveRecord::Base.transaction do
        action.update!(status: failure ? "failed" : "completed", output: { "content" => content })
        inject_result(call, content)
      end
      if failure
        session.emit("step.failed", { turn_id: turn.id, tool: call.name, error: failure.message })
      end
      session.emit("action.result", {
        turn_id: turn.id, call_id: call.id, tool: call.name, status: failure ? "failed" : "completed"
      })
    end

    # A failed action is a checkpoint too: the recorded error result is injected on replay — the
    # tool is never re-executed.
    def replay_failed_action(action, call)
      return false unless action.status == "failed"

      unless answered?(call)
        inject_result(call, action.output&.fetch("content", nil).to_s)
        session.emit("action.result", {
          turn_id: turn.id, call_id: call.id, tool: call.name, status: "failed"
        })
      end
      true
    end

    def inject_result(call, content)
      @chat.add_message(role: :tool, content: content, tool_call_id: call.id)
    end

    # Keeps the claim alive through model calls and tool bodies, the calls that can outlast
    # turn_stale_after. A sibling thread with its own DB connection beats heartbeat_at until the
    # block returns; a fenced beat means the turn was reclaimed, so it stops.
    def with_heartbeat
      interval = Xeno.config.heartbeat_interval.to_f
      # A non-positive interval (turn_stale_after 0 in tests) means every heartbeat is already stale
      # — a beater would just hammer the DB.
      return yield unless interval.positive?

      stop = Thread::Queue.new
      beater = Thread.new do
        loop do
          break if stop.pop(timeout: interval)
          break unless beat_quietly
        end
      end
      yield
    ensure
      if beater
        stop.push(:stop)
        beater.join(2)
      end
    end

    def beat_quietly
      ActiveRecord::Base.connection_pool.with_connection { turn.heartbeat!(token) }
      true
    rescue Xeno::Fenced
      false
    rescue StandardError
      true # a transient DB hiccup must not kill the beat
    end

    def stringify_result(result)
      content, _attachments = RubyLLM::Tool.split_result(result)
      content
    end

    def generate_step
      enforce_budgets!
      step_index = turn.record_step!(token)
      session.emit("step.started", { turn_id: turn.id, step: step_index })

      # A channel that streams (Slack post-then-edit) gets the deltas; the sink is a failable nicety
      # and never touches the turn's fate.
      streamer = Channels.streamer_for(session)
      response = ActiveSupport::Notifications.instrument("xeno.step", turn_id: turn.id, step: step_index) do
        with_heartbeat do
          if streamer
            @chat.generate { |chunk| streamer.push(chunk) }
          else
            @chat.generate
          end
        end
      end

      session.emit("step.completed", {
        turn_id: turn.id, step: step_index,
        tool_calls: (response.tool_calls || {}).values.map { |c| { id: c.id, name: c.name } }
      })

      if response.tool_call?
        session.emit("actions.requested", {
          turn_id: turn.id,
          calls: response.tool_calls.values.map { |c| { id: c.id, name: c.name, arguments: c.arguments } }
        })
      else
        emit_completion_events(response)
        # The streamer writes the durable final text into its message; when that lands, the
        # completion post would be a duplicate.
        @stream_delivered = true if streamer&.finish(response.content)
      end

      response
    end

    # Budgets are checked before each model call, from the per-attempt usage ledger (retries
    # included). The call that crosses a cap finishes — usage is only known afterwards — and the
    # next call trips. Checked here rather than at claim so a pure-replay turn still settles.
    def enforce_budgets!
      check_budget_axis!("input", :input_tokens, Xeno.config.max_input_tokens_per_session)
      check_budget_axis!("output", :output_tokens, Xeno.config.max_output_tokens_per_session)
    end

    def check_budget_axis!(axis, column, global)
      limit = definition.config.token_limit(column, global)
      return unless limit

      used = @chat.ruby_llm_usages.sum(column).to_i
      raise Xeno::BudgetExceeded.new(axis: axis, used: used, limit: limit) if used >= limit
    end

    def emit_completion_events(message)
      if message.thinking&.text.present?
        session.emit("reasoning.completed", { turn_id: turn.id, thinking: message.thinking.text })
      end
      session.emit("message.completed", { turn_id: turn.id, content: message.content })
    end

    def complete_turn
      turn.fenced_update!(token, status: "completed", heartbeat_at: Time.current)
      session.emit("turn.completed", { turn_id: turn.id, sequence: turn.sequence })
      deliver_final_answer
      maybe_stage_compaction
      advance_session
    end

    # Channel delivery (Slack thread reply, etc.) — a failable nicety; the durable truth is already
    # in the transcript and events. Skipped when a streamer already delivered this reply
    # (post-then-edit).
    def deliver_final_answer
      return if @stream_delivered

      final = @chat.messages_association.where(role: "assistant").order(:id).last
      Channels.deliver_completion(session, final.content) if final&.content.present?
    end

    # After a terminal turn: fold queued messages into the next turn and chain the next pending
    # turn's job — completion is what wakes later turns. A session retired mid-turn stops advancing.
    def advance_session
      return unless session.reload.active?

      session.drain_pending_messages!(definition: definition)
      session.turns.where(status: "pending").order(:sequence).first&.enqueue!
    end

    # Parking: the pending actions are recorded, the turn waits, and the job ends — no process
    # waits. Input resolution enqueues the resume; queued messages become a staged (deferred) next
    # turn immediately.
    def park_turn(actions = [])
      turn.fenced_update!(token, status: "waiting")
      session.update!(status: "waiting")
      session.emit("session.waiting", { turn_id: turn.id })
      session.drain_pending_messages!(definition: definition)
      Channels.deliver_input_request(session, actions) if actions.any?
    end

    def fail_schedule_park
      session.settle_unanswered_tool_calls!(turn, reason: "schedule runs cannot wait for human input")
      fail_turn(Xeno::Error.new("schedule run required human input (approval or question)"))
    end

    def cancel_turn
      session.settle_unanswered_tool_calls!(turn, reason: "cancelled by user")
      turn.fenced_update!(token, status: "cancelled")
      session.emit("turn.cancelled", { turn_id: turn.id })
      advance_session
    end

    def fail_turn(error)
      turn.fenced_update!(token, status: "failed", error: { "class" => error.class.name, "message" => error.message })
      session.emit("turn.failed", { turn_id: turn.id, error: error.message })
      advance_session
    end

    # Transient failure: count it, hand the claim back (status pending) so the retry can claim
    # immediately, and let the error propagate to the queue's retry machinery.
    def release_for_retry(error)
      turn.release_for_retry!(token, error)
    rescue Xeno::Fenced
      nil
    end

    # Between steps, a stopping worker hands the turn back instead of dying mid-step and waiting out
    # stale-heartbeat reclaim. Every move so far is checkpointed, so the next worker fast-forwards.
    def checkpoint_shutdown!
      raise Xeno::Interrupted, "worker is shutting down" if stopping?
    end

    def stopping?
      check = Xeno.config.stopping_check
      return !!check.call if check

      TurnJob.queue_adapter.stopping?
    rescue NoMethodError
      false # an adapter without the probe never interrupts
    end

    # Not a failure and not crash evidence: the claim is released with the ladder untouched and the
    # turn re-enqueues itself. A lost re-enqueue is caught by the reaper's stale-pending sweep.
    def interrupt_turn
      turn.fenced_update!(token, status: "pending", heartbeat_at: Time.current)
      turn.enqueue!
    rescue Xeno::Fenced
      nil
    end
  end
end
