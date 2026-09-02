Rails.application.routes.draw do
  root "documents#new"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Sidekiq's dashboard, for watching the queue while developing. Deliberately
  # development-only: it exposes job arguments and lets anyone who reaches it
  # retry or delete jobs, and this app has no authentication.
  if Rails.env.development?
    require "sidekiq/web"
    mount Sidekiq::Web => "/sidekiq"
  end
end
