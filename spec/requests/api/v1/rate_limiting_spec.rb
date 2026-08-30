# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# Tests del rate limiting. Dos capas, dos formas de testear.
#
# OJO CON EL ESTADO COMPARTIDO: los contadores viven en un cache que sobrevive
# entre ejemplos. Si no lo limpiás, el test 2 arranca con el contador del test 1
# y falla de forma intermitente. Es la causa #1 de flakiness en estos specs.
# ==============================================================================
RSpec.describe "API v1 · Rate limiting", type: :request do
  let(:user) { create(:user, :manager) }
  let(:api_token) { ApiToken.issue!(user:, name: "spec", scopes: ApiToken::SCOPES) }
  let(:headers) { { "Authorization" => "Bearer #{api_token.plaintext}", "Content-Type" => "application/json" } }

  before do
    Rails.cache.clear
    Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)
  end

  describe "capa 2: ActionController#rate_limit (por token, por controller)" do
    it "corta EXACTAMENTE al superar el límite de reportes (20/min)" do
      20.times do
        get "/api/v1/reports/reconciliation", headers: headers
        expect(response).to have_http_status(:ok)
      end

      get "/api/v1/reports/reconciliation", headers: headers
      expect(response).to have_http_status(:too_many_requests)
    end

    it "devuelve Retry-After y un cuerpo accionable" do
      21.times { get "/api/v1/reports/reconciliation", headers: headers }

      expect(response.headers["Retry-After"]).to be_present
      body = response.parsed_body
      expect(body.dig("error", "code")).to eq("rate_limit_exceeded")
      expect(body.dig("error", "details", "retry_after")).to be_a(Integer)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TEST DE REGRESIÓN DE UN BUG REAL.
    # Sin `name:` en cada `rate_limit`, la clave de cache es la misma para el
    # límite global de BaseController y para el de ReportsController: comparten
    # contador, cada request lo incrementa dos veces y el límite de 20 corta
    # en 10. Este test lo detecta.
    # ─────────────────────────────────────────────────────────────────────────
    it "los distintos rate_limit NO comparten contador (name: distinto)" do
      15.times { get "/api/v1/reports/reconciliation", headers: headers }
      # Con el bug, en la request 11 ya devolvía 429.
      expect(response).to have_http_status(:ok)
    end

    it "el contador es POR TOKEN: otro token arranca de cero" do
      21.times { get "/api/v1/reports/reconciliation", headers: headers }
      expect(response).to have_http_status(:too_many_requests)

      otro = ApiToken.issue!(user: create(:user, :manager), name: "otro", scopes: ApiToken::SCOPES)
      get "/api/v1/reports/reconciliation",
          headers: { "Authorization" => "Bearer #{otro.plaintext}" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "capa 1: Rack::Attack (borde, antes de Rails)" do
    # Rack::Attack está desactivado por defecto en test para no ensuciar los
    # demás specs; lo prendemos sólo acá.
    around do |example|
      Rack::Attack.enabled = true
      example.run
      Rack::Attack.enabled = false
    end

    it "limita los intentos de login por IP" do
      6.times do
        post "/session", params: { email_address: "x@y.z", password: "mal" }
      end

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["RateLimit-Limit"]).to eq("5")
      expect(response.headers["Retry-After"]).to be_present
    end

    it "el cuerpo del 429 es JSON parseable, no una página de error" do
      6.times { post "/session", params: { email_address: "x@y.z", password: "mal" } }

      body = JSON.parse(response.body)
      expect(body.dig("error", "code")).to eq("rate_limit_exceeded")
    end

    it "bloquea rutas de escaneo de vulnerabilidades" do
      get "/.env"
      expect(response).to have_http_status(:forbidden)
    end

    it "NUNCA limita el health check (si lo limitás, el balanceador te saca de rotación)" do
      400.times { get "/up" }
      expect(response).to have_http_status(:ok)
    end
  end
end
