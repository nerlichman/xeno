# frozen_string_literal: true

module Xeno
  # Finds turns that should be running but have no live owner and re-enqueues them. Duplicate-safe:
  # the claim CAS makes a redundant TurnJob exit quietly, and a poisoned turn fails at claim time.
  #
  # ReaperJob rides Solid Queue's recurring machinery. Other queue backends trigger it however they
  # run periodic work: Xeno::ReaperJob.perform_later or `bin/rails xeno:reap`.
  module Reaper # :nodoc:
    module_function

    # One sweep. Rescues, in order:
    # 1. running turns with a stale heartbeat — the owner died or the
    #    queue exhausted its retries; claim! reclaims these directly.
    # 2. stale pending turns — staged or released for retry, but the job
    #    never came back.
    # 3. waiting turns with nothing left to wait for — every action
    #    resolved but the resume enqueue never happened.
    # Genuinely parked turns are never touched.
    def sweep!(stale_before: Xeno.config.turn_stale_after.ago)
      rescued = []

      Turn.where(status: "running")
          .where("heartbeat_at IS NULL OR heartbeat_at < ?", stale_before)
          .find_each do |turn|
        turn.enqueue!
        rescued << turn
      end

      Turn.where(status: "pending")
          .where(updated_at: ...stale_before)
          .find_each do |turn|
        turn.enqueue!
        rescued << turn
      end

      Turn.where(status: "waiting")
          .where(updated_at: ...stale_before)
          .find_each do |turn|
        next if turn.actions.where(status: "pending_approval").exists?

        rescued << turn if Inputs.resume_turn(turn)
      end

      rescued
    end
  end
end
