Rails.application.routes.draw do
  # One state-driven entry point: landing, processing, plan, or error, per the
  # session's status. The session id rides Rails' signed cookie (D10), so no id
  # appears in any path and there is no session-creation endpoint.
  root "sessions#show"

  # One document per session; posting another replaces it (R3.1).
  resource :document, only: [ :create ]

  # A question about the document already held by this session.
  resources :messages, only: [ :create ]

  post   "heartbeat" => "sessions#heartbeat", as: :heartbeat
  delete "session"   => "sessions#destroy",   as: :session

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Sidekiq's dashboard, for watching the queue while developing. Deliberately
  # development-only: it exposes job arguments and lets anyone who reaches it
  # retry or delete jobs, and this app has no authentication to put in front
  # of it.
  if Rails.env.development?
    require "sidekiq/web"
    mount Sidekiq::Web => "/sidekiq"
  end
end
