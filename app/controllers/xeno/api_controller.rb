# frozen_string_literal: true

module Xeno
  # Base for every engine endpoint. Auth fails closed: without a configured
  # authenticate lambda, everything is 401. The lambda receives the request;
  # a falsy return is a 401; its truthy return value is the request
  # principal (stamped onto sessions by the HTTP channel).
  class ApiController < ActionController::API # :nodoc:
    before_action :authenticate!

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "not found" }, status: :not_found
    end

    rescue_from ActionController::ParameterMissing do |error|
      render json: { error: error.message }, status: :bad_request
    end

    rescue_from Xeno::Error do |error|
      render json: { error: error.message }, status: :conflict
    end

    # The development fallback principal (no auth lambda configured). It
    # matches every session — in development only — so the dev UI and
    # localhost curl stay usable.
    DEV_PRINCIPAL = { "user" => "dev" }.freeze

    private

    def authenticate!
      checker = Xeno.config.authenticate

      # Development with no auth configured stays usable (the dev UI, curl on
      # localhost). Everywhere else the absence of a checker is a 401.
      if checker.nil? && Rails.env.development?
        @current_principal = DEV_PRINCIPAL
        return
      end

      @current_principal = checker && instance_exec(request, &checker)
      head :unauthorized unless @current_principal
    end

    def current_principal
      # Normalize truthy-but-not-descriptive results (true) to nil-principal.
      @current_principal == true ? nil : @current_principal
    end

    # Ownership rule: a session belongs to the principal stamped at create.
    # A non-matching caller gets the same 404 as a nonexistent id (no
    # existence leak). A lambda that returns bare `true` yields nil
    # principals everywhere — single-tenant mode, every authenticated
    # caller matches (documented in docs/runtime.md).
    def find_owned_session!
      session = Session.find(params[:id])
      raise ActiveRecord::RecordNotFound unless owns?(session)

      session
    end

    def owns?(session)
      # Object identity on purpose: only the fallback path above grants the
      # wildcard, never a configured lambda that happens to return the same
      # hash.
      return true if Rails.env.development? && @current_principal.equal?(DEV_PRINCIPAL)

      session.principal == current_principal.as_json
    end
  end
end
