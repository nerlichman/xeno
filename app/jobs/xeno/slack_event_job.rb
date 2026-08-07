module Xeno
  # Processes one verified Slack event off the webhook path. The endpoint
  # acks inside Slack's 3-second window and hands the payload here; session
  # work (DB writes, LLM turns via TurnJob) happens on the queue. Slack
  # retry storms die at the event_id dedup row (claimed atomically with
  # this enqueue); a session can never be double-opened by a retry — the
  # thread's continuation token is unique among active sessions.
  class SlackEventJob < ApplicationJob
    queue_as :default

    discard_on ActiveJob::DeserializationError

    def perform(payload)
      channel = Channels.registry[:slack]
      return unless channel

      channel.handle_event(payload)
    end
  end
end
