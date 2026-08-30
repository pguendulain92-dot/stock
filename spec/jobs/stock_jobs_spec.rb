# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Jobs de mantenimiento de stock", type: :job do
  let(:user) { create(:user, :operator) }
  let(:product) { create(:product) }
  let(:warehouse) { create(:warehouse) }
  let(:recorder) { Outbox::NullRecorder.new }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100) }

  describe Stock::ExpireReservationsJob do
    it "libera las reservas vencidas y deja las vivas" do
      vencida = Stock::Reserve.call(product:, warehouse:, quantity: 10, user:,
                                    event_recorder: recorder).value
      viva = Stock::Reserve.call(product:, warehouse:, quantity: 5, user:,
                                 event_recorder: recorder).value
      vencida.update_column(:expires_at, 1.minute.ago)

      resultado = described_class.perform_now

      expect(resultado[:expired]).to eq(1)
      expect(vencida.reload).to be_expired
      expect(viva.reload).to be_held
      expect(item.reload.quantity_available).to eq(95)
    end
  end

  describe Stock::ReconcileBalancesJob do
    it "reporta sano cuando el ledger cierra" do
      Stock::Receive.call(product:, warehouse: create(:warehouse), quantity: 10, user:,
                          event_recorder: recorder)
      # `item` viene de la factory, que setea la cantidad sin movimientos:
      # lo sacamos para que la comparación sea limpia.
      item.destroy!

      expect(described_class.perform_now).to include(healthy: true)
    end

    it "detecta una discrepancia (alguien escribió la cantidad sin pasar por el service)" do
      resultado = described_class.perform_now

      expect(resultado[:healthy]).to be(false)
      expect(resultado[:drifts]).to eq(1)
    end

    it "NO corrige por defecto: una discrepancia es un bug y hay que verla" do
      described_class.perform_now
      expect(item.reload.quantity_on_hand).to eq(100)
    end

    it "con autofix: true escribe un movimiento de corrección" do
      expect { described_class.perform_now(autofix: true) }
        .to change(StockMovement, :count).by(1)

      expect(StockItems::Reconciliation.call).to be_empty
      expect(StockMovement.last.kind).to eq("count_correction")
      expect(StockMovement.last.metadata).to include("autofix" => true)
    end
  end

  describe Stock::LowStockAlertJob do
    before { item.update!(quantity_on_hand: 5, reorder_point: 20) }

    it "emite un evento por cada item bajo el punto de reorden" do
      expect { described_class.perform_now }.to change(OutboxEvent, :count).by(1)

      evento = OutboxEvent.last
      expect(evento.event_type).to eq("stock.low_stock_detected")
      expect(evento.payload).to include("product_sku" => product.sku, "quantity_available" => 5)
    end

    it "DEDUPLICA: no vuelve a alertar del mismo item dentro de la ventana" do
      described_class.perform_now
      expect { described_class.perform_now }.not_to change(OutboxEvent, :count)
    end

    it "vuelve a alertar cuando pasa la ventana de silencio" do
      described_class.perform_now

      travel_to(described_class::SILENCE_WINDOW.from_now + 1.minute) do
        expect { described_class.perform_now }.to change(OutboxEvent, :count).by(1)
      end
    end

    it "sugiere reponer hasta el máximo si está configurado" do
      item.update!(maximum_level: 100, reorder_quantity: 30)
      described_class.perform_now

      expect(OutboxEvent.last.payload["suggested_order_quantity"]).to eq(95)
    end
  end

  describe Cleanup::ExpiredRecordsJob do
    it "borra claves de idempotencia vencidas, sesiones muertas y eventos viejos" do
      create(:user).then do |u|
        IdempotencyKey.create!(user: u, key: "vieja", request_path: "/x", request_method: "POST",
                               request_fingerprint: "abc", expires_at: 1.day.ago)
        IdempotencyKey.create!(user: u, key: "nueva", request_path: "/x", request_method: "POST",
                               request_fingerprint: "abc", expires_at: 1.day.from_now)
      end
      create(:outbox_event, published_at: 60.days.ago)
      create(:outbox_event, published_at: 1.day.ago)
      create(:outbox_event)   # pendiente: NO se borra nunca

      resultado = described_class.perform_now

      expect(resultado[:idempotency_keys]).to eq(1)
      expect(resultado[:outbox_events]).to eq(1)
      expect(IdempotencyKey.count).to eq(1)
      expect(OutboxEvent.count).to eq(2)
    end
  end
end
