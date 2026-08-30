# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 · Reservas", type: :request do
  let(:user) { create(:user, :operator) }
  let(:token) { ApiToken.issue!(user:, name: "spec", scopes: ApiToken::SCOPES).plaintext }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  let(:product) { create(:product, sku: "RES-001") }
  let(:warehouse) { create(:warehouse, code: "BA-01") }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100) }

  def reservar(quantity: 10, **extra)
    post "/api/v1/reservations",
         params: { sku: product.sku, warehouse_code: warehouse.code, quantity:, **extra }.to_json,
         headers: headers
  end

  describe "POST /api/v1/reservations" do
    it "crea la reserva y baja el disponible sin tocar el stock físico" do
      reservar(quantity: 30)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["status"]).to eq("held")
      expect(data["quantity"]).to eq(30)

      item.reload
      expect(item.quantity_on_hand).to eq(100)
      expect(item.quantity_available).to eq(70)
    end

    it "422 cuando no hay disponible suficiente" do
      reservar(quantity: 90)
      reservar(quantity: 30)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("insufficient_available_stock")
      expect(response.parsed_body.dig("error", "details")).to include("available" => 10)
    end

    describe "TTL" do
      it "usa el default si no lo mandás" do
        reservar
        expect(Time.zone.parse(response.parsed_body.dig("data", "expires_at")))
          .to be_within(10.seconds).of(StockReservation::DEFAULT_TTL.from_now)
      end

      it "respeta el ttl_seconds del cliente" do
        reservar(ttl_seconds: 600)
        expect(Time.zone.parse(response.parsed_body.dig("data", "expires_at")))
          .to be_within(10.seconds).of(10.minutes.from_now)
      end

      # ─────────────────────────────────────────────────────────────────────
      # TODO valor numérico que venga del usuario y controle un recurso
      # (tiempo, tamaño, cantidad) necesita un TECHO. Sin el clamp, un cliente
      # pide ttl_seconds=999999999 y te inmoviliza stock por 30 años.
      # ─────────────────────────────────────────────────────────────────────
      it "ACOTA un ttl absurdo en vez de aceptarlo" do
        reservar(ttl_seconds: 999_999_999)
        expect(Time.zone.parse(response.parsed_body.dig("data", "expires_at")))
          .to be_within(1.minute).of(7.days.from_now)
      end

      it "ACOTA un ttl demasiado corto" do
        reservar(ttl_seconds: 1)
        expect(Time.zone.parse(response.parsed_body.dig("data", "expires_at")))
          .to be_within(10.seconds).of(60.seconds.from_now)
      end

      it "ignora un ttl no numérico en vez de romper" do
        reservar(ttl_seconds: "un ratito")
        expect(response).to have_http_status(:created)
      end
    end
  end

  describe "POST /api/v1/reservations/:id/commit" do
    it "confirma la salida y baja las dos cantidades" do
      reservar(quantity: 30)
      id = response.parsed_body.dig("data", "id")

      post "/api/v1/reservations/#{id}/commit", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "status")).to eq("committed")

      item.reload
      expect(item.quantity_on_hand).to eq(70)
      expect(item.quantity_reserved).to eq(0)
    end

    it "410 Gone si la reserva venció" do
      reservar(quantity: 30)
      id = response.parsed_body.dig("data", "id")
      StockReservation.find(id).update_column(:expires_at, 1.minute.ago)

      post "/api/v1/reservations/#{id}/commit", headers: headers

      expect(response).to have_http_status(:gone)
      expect(response.parsed_body.dig("error", "code")).to eq("reservation_expired")
    end
  end

  describe "DELETE /api/v1/reservations/:id" do
    it "libera la reserva y devuelve el disponible" do
      reservar(quantity: 30)
      id = response.parsed_body.dig("data", "id")

      delete "/api/v1/reservations/#{id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(item.reload.quantity_available).to eq(100)
    end

    it "liberar dos veces devuelve 200, no un error (es idempotente)" do
      reservar(quantity: 30)
      id = response.parsed_body.dig("data", "id")

      delete "/api/v1/reservations/#{id}", headers: headers
      delete "/api/v1/reservations/#{id}", headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/reservations" do
    it "lista y filtra por estado" do
      reservar(quantity: 10)
      reservar(quantity: 5)
      id = response.parsed_body.dig("data", "id")
      delete "/api/v1/reservations/#{id}", headers: headers

      get "/api/v1/reservations?status=held", headers: headers

      expect(response.parsed_body["data"].size).to eq(1)
      expect(response.parsed_body.dig("meta", "total_count")).to eq(1)
    end
  end
end
