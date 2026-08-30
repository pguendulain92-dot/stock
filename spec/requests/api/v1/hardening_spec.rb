# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# Tests de regresión de los agujeros que encontró la auditoría del código.
# Cada uno describe el bug que existía, no sólo el comportamiento deseado.
# ==============================================================================
RSpec.describe "API v1 · endurecimiento", type: :request do
  let(:user) { create(:user, :manager) }
  let(:token) { ApiToken.issue!(user:, name: "spec", scopes: ApiToken::SCOPES).plaintext }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  describe "techo de paginación" do
    before { create_list(:product, 3) }

    # `?limit=1000000` instanciaba un millón de objetos ActiveRecord: DoS de
    # una línea. Vale para cualquier número del usuario que controle un recurso.
    it "acota un limit absurdo en vez de obedecerlo" do
      get "/api/v1/products?limit=1000000", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "limit")).to eq(100)
    end

    it "ignora un limit no numérico en vez de romper" do
      get "/api/v1/products?limit=todos", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "limit")).to eq(25)
    end

    it "respeta un limit razonable" do
      get "/api/v1/products?limit=2", headers: headers
      expect(response.parsed_body["data"].size).to eq(2)
    end
  end

  describe "errores 400 en JSON" do
    let!(:product) { create(:product, sku: "H-1") }
    let!(:warehouse) { create(:warehouse, code: "H-WH") }

    # Sin rescue_from, esto devolvía la página HTML public/400.html en
    # desarrollo y un 500 en producción — nunca el 400 del contrato.
    it "un JSON malformado devuelve 400 en JSON, no una página HTML" do
      post "/api/v1/stock/receive", params: "{no es json", headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.dig("error", "code")).to eq("malformed_body")
    end

    it "no filtra el detalle del parser en el mensaje" do
      post "/api/v1/stock/receive", params: '{"sku": "SECRETO', headers: headers
      expect(response.body).not_to include("SECRETO")
    end

    it "una cantidad no entera devuelve 400 en JSON" do
      post "/api/v1/stock/receive",
           params: { sku: product.sku, warehouse_code: warehouse.code, quantity: "diez" }.to_json,
           headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.dig("error", "code")).to eq("bad_request")
    end
  end

  describe "idempotencia: la clave no se quema con un error del cliente" do
    let!(:warehouse) { create(:warehouse, code: "H-WH2") }
    let(:key) { SecureRandom.uuid }

    # Antes: si la acción levantaba y un rescue_from la atrapaba, la fila
    # quedaba en 'processing' y TODO reintento con esa clave recibía 409
    # durante 24 h. Un error transitorio del cliente le quemaba la clave.
    it "permite reintentar con la misma clave después de un 404" do
      post "/api/v1/stock/receive",
           params: { sku: "NO-EXISTE", warehouse_code: warehouse.code, quantity: 1 }.to_json,
           headers: headers.merge("Idempotency-Key" => key)
      expect(response).to have_http_status(:not_found)
      expect(IdempotencyKey.find_by(key:).status).to eq("failed")

      producto = create(:product, sku: "AHORA-SI")
      post "/api/v1/stock/receive",
           params: { sku: producto.sku, warehouse_code: warehouse.code, quantity: 1 }.to_json,
           headers: headers.merge("Idempotency-Key" => key)

      # Body distinto -> 422 por reuso, NO 409 por "en curso". Que sea 422
      # significa que la clave se liberó y el mecanismo funciona.
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("idempotency_key_reuse")
    end
  end

  describe "fuga de información en errores" do
    it "un 409 por duplicado NO expone el mensaje crudo de PostgreSQL" do
      create(:product, sku: "DUP-1")

      post "/api/v1/products",
           params: { product: { sku: "DUP-1", name: "Duplicado", cost_cents: 1, price_cents: 2 } }.to_json,
           headers: headers

      expect(response.body).not_to include("PG::")
      expect(response.body).not_to match(/index_\w+/)
      expect(response.body).not_to include("DETAIL")
    end
  end
end
