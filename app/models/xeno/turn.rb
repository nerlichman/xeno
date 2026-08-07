module Xeno
  # One user message and all work until the agent responds. Runs as one
  # ActiveJob. Correctness lives here, in the database, not in the queue:
  #
  # 1. Atomic claim (CAS on claim_token) — one worker owns the turn.
  # 2. Heartbeat — the owner touches heartbeat_at at step boundaries; a
  #    stale heartbeat lets the next attempt reclaim (checkpoint replay
  #    makes takeover safe).
  # 3. Fencing token — every write is conditioned on claim_token = mine, so
  #    a zombie that wakes up after being reaped affects zero rows.
  # 4. Max attempts — poison turns become turn.failed, not infinite retries.
  class Turn < ApplicationRecord
    STATUSES = %w[pending running waiting completed failed cancelled].freeze
    KINDS = %w[message compaction].freeze

    belongs_to :session, class_name: "Xeno::Session"
    has_many :actions, class_name: "Xeno::Action", dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :kind, inclusion: { in: KINDS }

    # Appends the next turn to the session, sequence assigned race-safely.
    # The INSERT runs in its own savepoint (requires_new): stage_turn! calls
    # this inside a transaction, and on Postgres a failed INSERT otherwise
    # aborts the whole transaction — the retry would raise
    # PG::InFailedSqlTransaction instead of recovering.
    def self.append!(session, user_message:, transcript_deferred: false, kind: "message")
      attempts = 0
      begin
        sequence = (where(session_id: session.id).maximum(:sequence) || 0) + 1
        transaction(requires_new: true) do
          create!(session: session, sequence: sequence, user_message: user_message,
                  transcript_deferred: transcript_deferred, kind: kind)
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 5
        raise
      end
    end

    def enqueue!
      TurnJob.perform_later(id)
    end

    # The atomic claim. Returns the fencing token on success, nil when
    # another worker owns the turn (exit quietly) or it isn't claimable.
    # Claimable: pending, or running with a stale heartbeat (dead owner).
    # Poison turns are failed here instead of retrying forever.
    #
    # `attempts` counts FAILURES, not claims: a stale-running reclaim is
    # crash evidence and counts here; a transient error counts in
    # release_for_retry!; an approval/question resume counts in `resumes`
    # and never against the poison ladder (H2).
    def claim!
      current = self.class.find(id)

      if current.attempts >= Xeno.config.max_turn_attempts
        poisoned = self.class.where(id: id, claim_token: current.claim_token)
                       .where.not(status: %w[completed failed cancelled])
                       .update_all(status: "failed", error: { "message" => "max attempts (#{current.attempts}) exhausted" })
        if poisoned == 1
          # A poisoned TURN leaves the SESSION running (idle, can take the
          # next message); settle any dangling tool calls so it stays usable.
          session.settle_unanswered_tool_calls!(self, reason: "turn failed (max attempts exhausted)")
          session.emit("turn.failed", { turn_id: id, error: "max attempts exhausted" })
        end
        return nil
      end

      stale_before = Xeno.config.turn_stale_after.ago
      earlier_active = self.class
        .where(session_id: session_id)
        .where("sequence < ?", sequence)
        .where(status: %w[pending running waiting])

      claimed = self.class
        .where(id: id, claim_token: current.claim_token)
        .where("status = 'pending' OR (status = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?))", stale_before)
        .where.not(earlier_active.arel.exists) # turns run in session order
        .update_all([
          "status = 'running', claim_token = ?, " \
          "attempts = attempts + (CASE WHEN status = 'running' THEN 1 ELSE 0 END), " \
          "heartbeat_at = ?",
          current.claim_token + 1, Time.current
        ])

      claimed == 1 ? current.claim_token + 1 : nil
    end

    # Transient failure: record the error, count the failure against the
    # poison ladder, and hand the claim back (status pending) so the queue
    # retry can claim immediately.
    def release_for_retry!(token, error)
      current = self.class.find(id)
      fenced_update!(token,
        status: "pending",
        attempts: current.attempts + 1,
        error: { "class" => error.class.name, "message" => error.message })
    end

    # Fenced write: touches the heartbeat iff we still own the claim.
    # Raises Xeno::Fenced when a zombie discovers it was reaped.
    def heartbeat!(token)
      fenced_update!(token, heartbeat_at: Time.current)
    end

    def fenced_update!(token, attributes)
      rows = self.class.where(id: id, claim_token: token).update_all(attributes)
      raise Xeno::Fenced, "turn #{id}: claim #{token} was fenced out" unless rows == 1

      true
    end

    def record_step!(token)
      current = self.class.find(id)
      if current.steps_count >= Xeno.config.max_steps
        raise Xeno::MaxStepsExceeded, "turn #{id}: exceeded #{Xeno.config.max_steps} steps"
      end

      fenced_update!(token, steps_count: current.steps_count + 1, heartbeat_at: Time.current)
      current.steps_count + 1
    end
  end
end
