module Xeno
  # One turn = one job. All correctness (claim, fencing, replay) lives in
  # TurnRunner + the database; the queue only provides at-least-once
  # delivery and retry backoff.
  class TurnJob < ApplicationJob
    queue_as :default

    retry_on StandardError, wait: :polynomially_longer, attempts: 5
    discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound

    def perform(turn_id)
      turn = Turn.find(turn_id)
      TurnRunner.new(turn).run
    end
  end
end
