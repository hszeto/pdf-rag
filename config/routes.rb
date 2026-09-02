Rails.application.routes.draw do
  # One state-driven entry point: landing, plan, or error, per the session's
  # status. The session id rides Rails' signed cookie (D10), so no id appears
  # in any path and there is no session-creation endpoint.
  root "sessions#show"

  # One document per session; posting another replaces it (R3.1).
  resource :document, only: [ :create ]

  post   "heartbeat" => "sessions#heartbeat", as: :heartbeat
  delete "session"   => "sessions#destroy",   as: :session

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
