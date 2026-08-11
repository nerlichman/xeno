# frozen_string_literal: true

module Xeno
  # The second half of the failure matrix: nothing else owns turns that
  # fall out of the retry ladder. The reaper finds work that SHOULD be
  # running but has no live owner and re-enqueues it. Duplicate-safe by
  # construction — the claim CAS means a redundant TurnJob exits quietly,
  # and a poisoned turn fails properly at claim time.
  #
  # Wiring: ReaperJob rides Solid Queue's recurring machinery (a managed
  # entry written by Schedules.sync! in mounted mode, storage/recurring.yml
  # in standalone mode). Other queue backends trigger it however they run
  # periodic work: `Xeno::ReaperJob.perform_later` or `bin/rails xeno:reap`.
  module Reaper # :nodoc:
    module_function

    # One sweep. Rescues, in order:
    # 1. running turns with a stale heartbeat — the owner died mid-step
    #    (kill -9) or the queue exhausted its retries with the job in the
    #    failed set; claim! reclaims these directly.
    # 2. stale pending turns — staged or released-for-retry, but no job
    #    ever came back (lost/discarded job).
    # 3. waiting turns with nothing left to wait for — every action
    #    resolved but the resume enqueue never happened (crash between
    #    resolve and enqueue). Genuinely parked turns are never touched.
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
