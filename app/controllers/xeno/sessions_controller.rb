# frozen_string_literal: true

module Xeno
  # The HTTP channel: always mounted, fail-closed. The channel owns the
  # continuation token (the resume handle): create returns one, follow-up
  # messages must present it, terminal states release it, reset retires the
  # session so the same token can start fresh.
  class SessionsController < ApiController # :nodoc:
    # POST /v1/sessions { message:, continuation_token: (optional) }
    # Client-supplied tokens are restricted to the reserved `http:`
    # namespace — a crafted `slack:<channel>:<ts>` token would otherwise
    # hijack which Slack thread the agent posts into.
    def create
      message = params.require(:message)
      token = params[:continuation_token].presence
      if token && !token.start_with?("http:")
        return render json: { error: "client-supplied continuation_token must use the http: namespace" },
                      status: :unprocessable_entity
      end
      token ||= "http:#{SecureRandom.base58(24)}"

      session = Session.start!(
        message: message,
        channel: "http",
        principal: current_principal,
        continuation_token: token
      )

      render json: { session_id: session.id, continuation_token: session.continuation_token },
             status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { error: "continuation_token already in use by an active session" },
             status: :conflict
    end

    # POST /v1/sessions/:id/messages { message:, continuation_token:, steer: }
    # steer: true stops the active turn (settled safely) and makes this
    # message the next turn instead of queueing behind the current work.
    def message
      session = find_owned_session!

      return render json: { error: "session is finished — start a new one" }, status: :gone unless session.active?

      supplied = params[:continuation_token].to_s
      unless supplied.present? && session.continuation_token.present? &&
             ActiveSupport::SecurityUtils.secure_compare(supplied, session.continuation_token)
        return render json: { error: "continuation_token missing or wrong" }, status: :forbidden
      end

      content = params.require(:message)
      steer = ActiveModel::Type::Boolean.new.cast(params[:steer])
      turn = steer ? session.steer!(content) : session.receive_message!(content)
      render json: { session_id: session.id, queued: turn.nil?, turn_id: turn&.id, steered: steer || nil }.compact,
             status: :accepted
    end

    # POST /v1/sessions/:id/inputs { action_id:, decision: approve|deny, reason: } or { action_id:, answer: }
    def input
      session = find_owned_session!
      action = Action.joins(:turn).where(xeno_turns: { session_id: session.id })
                     .find(params.require(:action_id))

      if action.kind == "question"
        Inputs.answer!(action, params.require(:answer), principal: current_principal)
      else
        case params.require(:decision)
        when "approve" then Inputs.approve!(action, principal: current_principal)
        when "deny" then Inputs.deny!(action, reason: params[:reason], principal: current_principal)
        else
          return render json: { error: "decision must be approve or deny" }, status: :unprocessable_entity
        end
      end

      render json: { action_id: action.id, status: action.reload.status,
                     turn_status: action.turn.reload.status }
    end

    # POST /v1/sessions/:id/cancel — stop the active turn, session intact.
    # A parked/pending turn cancels immediately (no process holds it); a
    # running turn is cancelled cooperatively via the persisted flag the
    # runner's checker polls (takes effect within a chunk or step boundary).
    def cancel
      session = find_owned_session!
      turn = session.turns.where(status: %w[pending running waiting]).order(:sequence).first

      return render json: { error: "no active turn" }, status: :conflict unless turn

      if turn.status == "running"
        session.chat.cancel!
        render json: { turn_id: turn.id, cancelling: true }, status: :accepted
      else
        # Settle BEFORE cancelling: a parked turn's assistant tool_calls are
        # still unanswered, and leaving them dangling bricks the session
        # (every later generate replays the malformed transcript).
        session.settle_unanswered_tool_calls!(turn, reason: "cancelled by user")
        turn.update!(status: "cancelled")
        session.update!(status: "running") if session.status == "waiting"
        session.emit("turn.cancelled", { turn_id: turn.id })
        render json: { turn_id: turn.id, cancelled: true }
      end
    end

    # POST /v1/sessions/:id/compact — request a manual compaction. It runs
    # as a claimed turn, so it queues behind any active or parked turn and
    # executes the moment the session is free. Never appends a user message.
    def compact
      session = find_owned_session!

      return render json: { error: "session is finished" }, status: :gone unless session.active?
      if session.turns.where(kind: "compaction", status: %w[pending running]).exists?
        return render json: { error: "a compaction is already queued" }, status: :conflict
      end

      turn = session.stage_compaction_turn!(reason: "manual")
      turn.enqueue!
      render json: { session_id: session.id, turn_id: turn.id, status: "requested" }, status: :accepted
    end

    # POST /v1/sessions/:id/reset — retire the session (the /new command);
    # releases the continuation token so the same handle can start fresh.
    def reset
      session = find_owned_session!

      return render json: { error: "session already finished" }, status: :gone unless session.active?

      session.chat.cancel! if session.turns.where(status: "running").exists?
      released = session.continuation_token
      session.finish!("completed")

      render json: { session_id: session.id, released_continuation_token: released }
    end
  end
end
