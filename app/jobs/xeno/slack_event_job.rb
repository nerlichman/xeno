# frozen_string_literal: true

module Xeno
  # Processes one verified Slack event off the webhook path: the endpoint acks inside Slack's
  # 3-second window and hands the payload here. Retry storms die at the event_id dedup row, and a
  # session can never be double-opened — the thread's continuation token is unique among active
  # sessions.
  class SlackEventJob < ApplicationJob # :nodoc:
    queue_as :default

    discard_on ActiveJob::DeserializationError

    def perform(payload)
      channel = Channels.registry[:slack]
      return unless channel

      channel.handle_event(payload)
    end
  end
end
