module Xeno
  # The Slack Events API endpoint. The generic auth lambda is skipped —
  # Slack's own request signature IS the authentication (verified in
  # constant time), and it fails closed: no configured slack channel = 404,
  # bad or stale signature = 401.
  class SlackController < ApiController
    skip_before_action :authenticate!

    def events
      channel = Channels.registry[:slack]
      return head :not_found unless channel

      raw = request.raw_post
      unless channel.verify_signature(
        request.headers["X-Slack-Request-Timestamp"],
        request.headers["X-Slack-Signature"],
        raw
      )
        return head :unauthorized
      end

      payload = JSON.parse(raw)
      return render json: { challenge: payload["challenge"] } if payload["type"] == "url_verification"

      enqueue_event(payload)
      head :ok
    end

    private

    # Fast ack (Slack retries anything that misses its 3s window) + retry
    # dedup: the event_id claim and the job enqueue commit together, so a
    # retry storm yields exactly one processing job — and a crash before
    # the ack leaves the claim unclaimed for the retry to win. Events
    # without an event_id (shouldn't happen for event_callback) process
    # without dedup rather than being dropped.
    def enqueue_event(payload)
      event_id = payload["event_id"]
      if event_id.present?
        Dedup.transaction do
          SlackEventJob.perform_later(payload) if Dedup.claim("slack_event", event_id)
        end
      else
        SlackEventJob.perform_later(payload)
      end
    end
  end
end
