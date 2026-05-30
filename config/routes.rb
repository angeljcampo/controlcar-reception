require "sidekiq/web"

Rails.application.routes.draw do
  # Sidekiq Web UI (sin auth en este scope — documentado como future work).
  mount Sidekiq::Web => "/sidekiq"

  # Health check endpoint usado por Render para verificar que el container responde.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "work_orders#index"  # se habilita cuando exista el controller
end
