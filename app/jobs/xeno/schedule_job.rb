# frozen_string_literal: true

module Xeno
  # Fires one scheduled run: a fire-and-forget task-mode session under the
  # app principal. Solid Queue recurring entries (rake xeno:schedules:sync)
  # and the dev dispatch endpoint both enqueue this.
  #
  # At-least-once safe: queues redeliver, and Solid Queue's recurring
  # (task, run-at) dedup only covers the enqueue, not the execution. Each
  # enqueue carries one ActiveJob job_id; the dedup row claims it in the
  # SAME transaction that opens the session, so a redelivered tick can
  # never double-open — it re-enqueues the recorded turn instead (idle
  # no-op if the first delivery finished: the claim CAS decides).
  class ScheduleJob < ApplicationJob # :nodoc:
    queue_as :default

    discard_on ArgumentError

    DEDUP_SCOPE = "schedule_run".freeze

    def perform(name)
      definition = Xeno.definition
      schedule = definition.schedules[name]
      raise ArgumentError, "unknown schedule: #{name}" unless schedule

      turn = nil
      claimed = Session.transaction do
        Dedup.claim(DEDUP_SCOPE, job_id, metadata: { "schedule" => name }).tap do |row|
          next unless row

          session = Session.open!(
            message: schedule.prompt,
            channel: "schedule",
            principal: { "type" => "app", "schedule" => name },
            definition: definition
          )
          turn = session.turns.order(:sequence).last
          row.update!(metadata: row.metadata.merge("session_id" => session.id, "turn_id" => turn.id))
        end
      end

      turn ||= redelivered_turn(claimed)
      TurnJob.perform_now(turn.id) if turn
    end

    private

    # This job_id already ran (or died mid-run): pick up ITS turn instead of
    # opening a second session. The claim CAS makes this a no-op when the
    # first delivery actually finished.
    def redelivered_turn(claimed)
      return nil if claimed

      turn_id = Dedup.existing(DEDUP_SCOPE, job_id)&.metadata&.fetch("turn_id", nil)
      Turn.find_by(id: turn_id) if turn_id
    end
  end
end
