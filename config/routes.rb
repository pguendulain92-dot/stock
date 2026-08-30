# frozen_string_literal: true

Rails.application.routes.draw do
  # ── Autenticación web (sesiones con cookie) ─────────────────────────────────
  resource :session
  resources :passwords, param: :token

  # ── UI HTML (Hotwire) ───────────────────────────────────────────────────────
  root "dashboard#index"
  get "dashboard", to: "dashboard#index"

  resources :products do
    member { patch :discard }
  end
  resources :warehouses, only: %i[index show new create edit update]
  resources :suppliers, only: %i[index show new create edit update]

  resources :stock_items, only: %i[index show] do
    collection { get :low_stock }
    member do
      post :receive
      post :issue
      post :adjust
    end
  end

  resources :stock_movements, only: %i[index]
  resources :stock_transfers, only: %i[index show new create] do
    member do
      # ⚠️ `dispatch` es un método RESERVADO de ActionController::Metal (es el
      # que el router usa para invocar la acción: `controller.dispatch(name,
      # request, response)`). Si definís `def dispatch` en un controller, pisás
      # el motor de Rails y TODAS las acciones de ese controller revientan con
      # "wrong number of arguments (given 3, expected 0)". La URL puede seguir
      # llamándose /dispatch; lo que cambia es el nombre del MÉTODO.
      # Otros nombres a evitar en un controller: `process`, `render`, `params`,
      # `send`, `status`, `response`, `request`, `action_name`, `performed?`.
      post :dispatch, action: :dispatch_transfer
      post :receive, action: :receive_transfer
    end
  end

  # ── API JSON ────────────────────────────────────────────────────────────────
  #
  # VERSIONADO POR PATH (/api/v1/...). Las alternativas:
  #   * Header (Accept: application/vnd.stock.v2+json) -> más "purista" REST,
  #     pero imposible de probar desde el browser y confunde a los caches.
  #   * Query param (?version=2) -> se pierde en redirects y logs.
  #   * Path -> feo para los puristas, PERO es explícito, cacheable, se ve en los
  #     logs y podés enrutar v1/v2 a servicios distintos en el balanceador.
  #     Es lo que usan Stripe, GitHub y prácticamente todos. Path gana.
  #
  # `defaults: { format: :json }` evita que un `/api/v1/products.html` intente
  # renderizar una vista que no existe y tire un 500 en vez de un 406.
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      # `param: :id` recibe el SKU: la API habla en claves NATURALES.
      resources :products, only: %i[index show create update destroy]
      resources :warehouses, only: %i[index show]
      resources :stock_items, only: %i[index show]
      resources :stock_movements, only: %i[index]

      resources :reservations, only: %i[index show create destroy] do
        member { post :commit }
      end

      resources :stock_transfers, only: %i[index show create] do
        member do
          # Ver la nota sobre `dispatch` en las rutas HTML de arriba.
          post :dispatch, action: :dispatch_transfer
          post :receive, action: :receive_transfer
        end
      end

      # Operaciones (verbos, no recursos). REST puro diría "creá un recurso
      # Movement", y de hecho eso hace por debajo — pero `POST /stock/receive`
      # comunica la INTENCIÓN, y la intención es lo que el ledger necesita
      # registrar (recibir != ajustar, aunque las dos sumen 10 unidades).
      # Esto es RPC-sobre-HTTP y está bien: no seas dogmático con REST cuando el
      # dominio es de comandos.
      post "stock/receive", to: "stock_operations#receive"
      post "stock/issue",   to: "stock_operations#issue"
      post "stock/adjust",  to: "stock_operations#adjust"

      get "reports/low_stock",      to: "reports#low_stock"
      get "reports/valuation",      to: "reports#valuation"
      get "reports/reconciliation", to: "reports#reconciliation"
    end
  end

  # ── Operación / observabilidad ──────────────────────────────────────────────

  # Health check para el load balancer. Devuelve 200 si la app bootea.
  get "up" => "rails/health#show", as: :rails_health_check

  # Dashboard de jobs. `constraints` con un lambda: sólo admins.
  # Montar un engine de administración SIN restricción es un clásico de
  # pentesting — /sidekiq abierto al mundo aparece en el top de bug bounties.
  constraints(->(req) {
    session = Session.find_by(id: req.cookie_jar.signed[:session_id])
    session&.user&.admin?
  }) do
    mount MissionControl::Jobs::Engine, at: "/jobs"
  end
end
