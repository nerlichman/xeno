# frozen_string_literal: true

module Xeno
  # The mounted dev chat UI: chat with the agent, watch the event stream live (over xeno's own SSE
  # endpoint), and approve/deny/answer parked work. Development only.
  class DevUiController < ApplicationController # :nodoc:
    before_action :ensure_development

    def index
      @sessions = Session.order(id: :desc).limit(50)
    end

    def create
      session_record = Session.start!(
        message: params.require(:message),
        channel: "dev",
        principal: { "user" => "dev-ui" }
      )
      redirect_to dev_session_path(session_record)
    end

    def show
      @session = Session.find(params[:id])
      @messages = @session.chat.messages_association.order(:id)
      @pending_actions = Action.joins(:turn)
                               .where(xeno_turns: { session_id: @session.id }, status: "pending_approval")
                               .order(:id)
      @events = @session.events.order(:index)
    end

    def message
      session_record = Session.find(params[:id])
      content = params.require(:message)
      if ActiveModel::Type::Boolean.new.cast(params[:steer])
        session_record.steer!(content)
      else
        session_record.receive_message!(content)
      end
      redirect_to dev_session_path(session_record)
    end

    def compact
      session_record = Session.find(params[:id])
      unless session_record.turns.where(kind: "compaction", status: %w[pending running]).exists?
        session_record.stage_compaction_turn!(reason: "manual").enqueue!
      end
      redirect_to dev_session_path(session_record)
    end

    def input
      session_record = Session.find(params[:id])
      action = Action.joins(:turn)
                     .where(xeno_turns: { session_id: session_record.id })
                     .find(params.require(:action_id))

      principal = { "user" => "dev-ui" }
      case params[:decision]
      when "approve" then Inputs.approve!(action, principal: principal)
      when "deny" then Inputs.deny!(action, reason: params[:reason], principal: principal)
      else Inputs.answer!(action, params.require(:answer), principal: principal)
      end

      redirect_to dev_session_path(session_record)
    end

    private

    def ensure_development
      head :not_found unless Xeno.dev_routes_enabled?
    end
  end
end
