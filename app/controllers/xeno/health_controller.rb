# frozen_string_literal: true

module Xeno
  # The one unauthenticated endpoint: liveness only, leaks nothing.
  class HealthController < ApiController # :nodoc:
    skip_before_action :authenticate!

    def show
      render json: { status: "ok" }
    end
  end
end
