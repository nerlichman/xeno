# frozen_string_literal: true

module Xeno
  # Resolving parked work: approvals, denials, and question answers. Each
  # resolution updates the action and — once no other action on the turn is
  # still awaiting input — flips the turn back to pending and enqueues the
  # resume job. A parked session holds zero compute; this is the only way
  # back in.
  module Inputs # :nodoc:
    module_function

    def approve!(action, principal: nil)
      resolve(action) do
        action.update!(status: "approved", resolved_at: Time.current, resolved_by: principal)
        mirror_decision(action, "approved")
      end
    end

    def deny!(action, reason: nil, principal: nil)
      resolve(action) do
        content = JSON.generate({ denied: true, reason: reason || "denied by user" })
        action.update!(
          status: "denied",
          output: { "content" => content },
          resolved_at: Time.current,
          resolved_by: principal
        )
        mirror_decision(action, "denied")
      end
    end

    def answer!(action, answer, principal: nil)
      raise ArgumentError, "not a question: #{action.tool_name}" unless action.kind == "question"

      resolve(action) do
        action.update!(
          status: "completed",
          output: { "content" => JSON.generate({ answer: answer }) },
          resolved_at: Time.current,
          resolved_by: principal
        )
      end
    end

    # The action row stays authoritative (kind, payload, who, when); the
    # decision is mirrored onto the standard tool-call column so any
    # RubyLLM-aware tooling reads it natively. Questions have no place
    # there and are not mirrored.
    def mirror_decision(action, decision)
      return unless action.kind == "tool"

      record = RubyLLM::ActiveRecord::ToolCall.find_by(tool_call_id: action.tool_call_id)
      record&.update!(approval: decision)
    end

    # Shared plumbing: guard the state, apply the resolution, resume when
    # the turn has nothing else to wait for. Resolution, status flip, and
    # the resume enqueue commit in ONE transaction: on a DB-backed queue
    # (Solid Queue shares the app database, and ActiveJob 8.1 enqueues
    # in-transaction by default) a crash can never separate "approved" from
    # "job exists" — either everything landed or the input is still pending
    # and the human just retries. Backends that defer or lose the enqueue
    # fall back to the reaper's sweeps.
    def resolve(action)
      unless action.status == "pending_approval"
        raise Xeno::Error, "action #{action.id} is not awaiting input (status: #{action.status})"
      end

      ActiveRecord::Base.transaction do
        yield
        resume_turn(action.turn)
      end
      action
    end

    # Resuming with unanswered inputs would generate against partial tool
    # results (an invalid provider state) — the runner would just re-park,
    # so don't bother waking it until everything is resolved.
    def resume_turn(turn)
      return if turn.actions.where(status: "pending_approval").exists?

      # Resumes are human-driven and unbounded — counted apart from the
      # failure `attempts` so approvals can never poison the turn (H2).
      resumed = Turn.where(id: turn.id, status: "waiting")
                    .update_all("status = 'pending', resumes = resumes + 1")
      return unless resumed == 1

      turn.session.update!(status: "running") if turn.session.status == "waiting"
      turn.enqueue!
      turn
    end
  end
end
