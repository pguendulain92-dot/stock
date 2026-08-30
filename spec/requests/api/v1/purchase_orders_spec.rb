# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 · Órdenes de compra", type: :request do
  let(:user) { create(:user, :manager) }
  let(:token) { ApiToken.issue!(user:, name: "spec", scopes: ApiToken::SCOPES).plaintext }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  let!(:supplier) { create(:supplier, tax_id: "30712345678") }
  let!(:warehouse) { create(:warehouse, code: "BA-01") }
  let!(:p1) { create(:product, sku: "P-1") }
  let!(:p2) { create(:product, sku: "P-2") }

  def crear_orden(**overrides)
    payload = {
      purchase_order: {
        supplier_tax_id: "30712345678", warehouse_code: "BA-01", currency: "USD",
        lines: [ { sku: "P-1", quantity: 10, unit_cost_cents: 500 },
                 { sku: "P-2", quantity: 4, unit_cost_cents: 2_500 } ]
      }.merge(overrides)
    }
    post "/api/v1/purchase_orders", params: payload.to_json, headers: headers
  end

  describe "POST /api/v1/purchase_orders" do
    it "crea la orden con sus líneas y calcula el total" do
      crear_orden

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["reference"]).to match(/\APO-\d{4}-\d{6}\z/)
      expect(data["status"]).to eq("draft")
      expect(data["lines"].size).to eq(2)
      # 10 x 500 + 4 x 2500 = 15.000 centavos. El subtotal lo calcula Postgres
      # (columna generada), el total lo recalcula el callback de la línea.
      expect(data.dig("total", "cents")).to eq(15_000)
    end

    it "rechaza un proveedor inexistente con el campo señalado" do
      crear_orden(supplier_tax_id: "99999999999")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details", "errors")).to have_key("supplier_tax_id")
    end

    it "rechaza líneas vacías" do
      crear_orden(lines: [])
      expect(response.parsed_body.dig("error", "message")).to include("no puede estar vacío")
    end

    it "no deja la orden a medio crear cuando una línea es inválida" do
      expect {
        crear_orden(lines: [ { sku: "P-1", quantity: 1, unit_cost_cents: 100 },
                             { sku: "NO-EXISTE", quantity: 1, unit_cost_cents: 100 } ])
      }.not_to change(PurchaseOrder, :count)
    end
  end

  describe "ciclo de vida" do
    before { crear_orden }

    let(:reference) { PurchaseOrder.last.reference }

    it "submit pasa la orden a submitted y emite el evento" do
      expect {
        post "/api/v1/purchase_orders/#{reference}/submit", headers: headers
      }.to change(OutboxEvent, :count).by(1)

      expect(response.parsed_body.dig("data", "status")).to eq("submitted")
      expect(OutboxEvent.last.event_type).to eq("purchase_order.submitted")
    end

    it "no se puede enviar dos veces" do
      post "/api/v1/purchase_orders/#{reference}/submit", headers: headers
      post "/api/v1/purchase_orders/#{reference}/submit", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_transition")
    end

    describe "recepción" do
      before { post "/api/v1/purchase_orders/#{reference}/submit", headers: headers }

      it "recepción TOTAL: ingresa el stock con el costo de la orden" do
        post "/api/v1/purchase_orders/#{reference}/receive", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "status")).to eq("received")

        item = StockItem.find_by(product: p1, warehouse:)
        expect(item.quantity_on_hand).to eq(10)
        # El costo del movimiento sale de la LÍNEA de la orden, no del producto:
        # es lo que permite valuar el inventario a costo real de compra.
        expect(item.stock_movements.last.unit_cost_cents).to eq(500)
      end

      it "recepción PARCIAL deja la orden en partially_received" do
        post "/api/v1/purchase_orders/#{reference}/receive",
             params: { received: { "P-1" => 6 } }.to_json, headers: headers

        expect(response.parsed_body.dig("data", "status")).to eq("partially_received")
        expect(StockItem.find_by(product: p1, warehouse:).quantity_on_hand).to eq(6)
        expect(StockItem.find_by(product: p2, warehouse:)).to be_nil
      end

      it "rechaza recibir más de lo pedido" do
        post "/api/v1/purchase_orders/#{reference}/receive",
             params: { received: { "P-1" => 999 } }.to_json, headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_quantity")
      end

      it "el ledger cierra después de la recepción" do
        post "/api/v1/purchase_orders/#{reference}/receive", headers: headers
        expect(StockItems::Reconciliation.call).to be_empty
      end

      it "es idempotente con Idempotency-Key" do
        idem = headers.merge("Idempotency-Key" => SecureRandom.uuid)
        post "/api/v1/purchase_orders/#{reference}/receive", headers: idem
        post "/api/v1/purchase_orders/#{reference}/receive", headers: idem

        expect(StockItem.find_by(product: p1, warehouse:).quantity_on_hand).to eq(10)
      end
    end
  end

  describe "permisos" do
    it "un operador NO puede enviar una orden (es decisión de un manager)" do
      crear_orden
      operador = create(:user, :operator)
      tk = ApiToken.issue!(user: operador, name: "op", scopes: ApiToken::SCOPES).plaintext

      post "/api/v1/purchase_orders/#{PurchaseOrder.last.reference}/submit",
           headers: headers.merge("Authorization" => "Bearer #{tk}")

      expect(response).to have_http_status(:forbidden)
    end

    it "un token sin el scope purchases:write no puede crear" do
      tk = ApiToken.issue!(user:, name: "ro", scopes: %w[stock:read]).plaintext
      post "/api/v1/purchase_orders",
           params: { purchase_order: { supplier_tax_id: "x", warehouse_code: "y", lines: [] } }.to_json,
           headers: headers.merge("Authorization" => "Bearer #{tk}")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "details", "required_scope")).to eq("purchases:write")
    end
  end
end
