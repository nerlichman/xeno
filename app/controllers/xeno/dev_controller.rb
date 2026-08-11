# frozen_string_literal: true

module Xeno
  # Development conveniences. Schedules never fire on cadence in dev; this
  # endpoint triggers one by name. Refuses to exist outside
  # development (XENO_DEV_ROUTES=1 lets tests exercise it).
  class DevController < ApiController # :nodoc:
    before_action :ensure_development

    def dispatch_schedule
      name = params[:name].to_s
      unless Xeno.definition.schedules.key?(name)
        return render json: { error: "unknown schedule: #{name}" }, status: :not_found
      end

      ScheduleJob.perform_later(name)
      render json: { dispatched: name }, status: :accepted
    end

    private

    def ensure_development
      head :not_found unless Xeno.dev_routes_enabled?
    end
  end
end
