Xeno::Engine.routes.draw do
  scope "v1" do
    get "health", to: "health#show"

    post "sessions", to: "sessions#create"
    post "sessions/:id/messages", to: "sessions#message", as: :session_messages
    post "sessions/:id/inputs", to: "sessions#input", as: :session_inputs
    post "sessions/:id/cancel", to: "sessions#cancel", as: :session_cancel
    post "sessions/:id/compact", to: "sessions#compact", as: :session_compact
    post "sessions/:id/reset", to: "sessions#reset", as: :session_reset
    get "sessions/:id/stream", to: "streams#show", as: :session_stream

    post "dev/schedules/:name", to: "dev#dispatch_schedule", as: :dev_schedule_dispatch

    post "channels/slack/events", to: "slack#events", as: :slack_events
  end

  # The dev chat UI (development only; the controller 404s elsewhere).
  get "dev", to: "dev_ui#index", as: :dev_ui
  post "dev/sessions", to: "dev_ui#create", as: :dev_sessions
  get "dev/sessions/:id", to: "dev_ui#show", as: :dev_session
  post "dev/sessions/:id/messages", to: "dev_ui#message", as: :dev_session_message
  post "dev/sessions/:id/inputs", to: "dev_ui#input", as: :dev_session_input
  post "dev/sessions/:id/compact", to: "dev_ui#compact", as: :dev_session_compact
end
