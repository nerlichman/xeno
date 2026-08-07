Xeno.configure do |config|
  # HTTP auth is FAIL-CLOSED: every endpoint (except health) returns 401
  # until you set this. The lambda receives the request; return something
  # falsy to reject, or a truthy value to accept — whatever you return
  # becomes the session's principal (visible to tools and approval lambdas).
  #
  # config.authenticate = ->(request) do
  #   token = request.headers["Authorization"]&.delete_prefix("Bearer ")
  #   { "user" => "api" } if ActiveSupport::SecurityUtils.secure_compare(
  #     token.to_s, Rails.application.credentials.xeno_api_key.to_s
  #   )
  # end

  # Per-turn model-call budget (runaway protection).
  # config.max_steps = 20

  # How long a silent turn is presumed alive before another worker may
  # reclaim it. Keep it above your slowest model call.
  # config.turn_stale_after = 5.minutes
end
