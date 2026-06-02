require "sidekiq/web"

Rails.application.routes.draw do
  # Sidekiq Web UI (sin auth en este scope — documentado como future work).
  mount Sidekiq::Web => "/sidekiq"

  # Health check endpoint usado por Render para verificar que el container responde.
  get "up" => "rails/health#show", as: :rails_health_check

  resources :work_orders, only: %i[index new create show] do
    member do
      post :reanalyze
      post :cancel
    end

    # Lazy-loaded Turbo Frame panel on the show page. Lists every
    # AnalyzeWorkOrderJob attempt for the OT with status, tokens, cost,
    # and latency.
    resources :agent_runs, only: %i[index]
  end

  root "work_orders#index"
end
