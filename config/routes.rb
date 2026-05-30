require "sidekiq/web"

Rails.application.routes.draw do
  # Sidekiq Web UI (sin auth en este scope — documentado como future work).
  mount Sidekiq::Web => "/sidekiq"

  # Health check endpoint usado por Render para verificar que el container responde.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :work_orders, only: %i[index new create show] do
    member do
      post :reanalyze
    end
  end

  root "work_orders#index"
end
