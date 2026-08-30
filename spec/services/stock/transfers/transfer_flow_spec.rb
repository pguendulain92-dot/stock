# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# El flujo completo de una transferencia. Es el test que demuestra la propiedad
# más importante del diseño: EL INVENTARIO TOTAL SE CONSERVA en cada paso,
# gracias al depósito virtual de tránsito.
# ==============================================================================
RSpec.describe "Flujo de transferencia entre depósitos" do
  let(:user) { create(:user, :operator) }
  let(:recorder) { Outbox::NullRecorder.new }
  let(:origen) { create(:warehouse, code: "ORIG") }
  let(:destino) { create(:warehouse, code: "DEST") }
  let!(:transito) { create(:warehouse, :transit) }
  let(:producto_a) { create(:product, sku: "AAA-1") }
  let(:producto_b) { create(:product, sku: "BBB-2") }

  before do
    Stock::Receive.call(product: producto_a, warehouse: origen, quantity: 100, user:, event_recorder: recorder)
    Stock::Receive.call(product: producto_b, warehouse: origen, quantity: 50, user:, event_recorder: recorder)
  end

  let(:transfer) do
    t = StockTransfer.create!(source_warehouse: origen, destination_warehouse: destino, requested_by: user)
    t.lines.create!(product: producto_a, quantity_requested: 40)
    t.lines.create!(product: producto_b, quantity_requested: 20)
    t
  end

  def total_unidades(product)
    StockItem.where(product:).sum(:quantity_on_hand)
  end

  describe "despacho" do
    subject(:despachar) do
      Stock::Transfers::Dispatch.call(transfer:, user:, event_recorder: recorder)
    end

    it "mueve la mercadería del origen al depósito EN TRÁNSITO" do
      despachar

      expect(StockItem.find_by(product: producto_a, warehouse: origen).quantity_on_hand).to eq(60)
      expect(StockItem.find_by(product: producto_a, warehouse: transito).quantity_on_hand).to eq(40)
      expect(StockItem.find_by(product: producto_a, warehouse: destino)).to be_nil
    end

    it "CONSERVA el inventario total (la ecuación contable cierra)" do
      antes = total_unidades(producto_a)
      despachar
      expect(total_unidades(producto_a)).to eq(antes)
    end

    it "pasa la transferencia a in_transit" do
      despachar
      expect(transfer.reload).to be_in_transit
      expect(transfer.dispatched_at).to be_present
    end

    it "escribe dos movimientos por línea (salida + entrada a tránsito)" do
      expect { despachar }.to change(StockMovement, :count).by(4)   # 2 líneas x 2
    end

    it "rechaza despachar dos veces" do
      despachar
      segundo = Stock::Transfers::Dispatch.call(transfer: transfer.reload, user:, event_recorder: recorder)
      expect(segundo.error.code).to eq(:invalid_transition)
    end

    it "falla completo si UNA línea no tiene stock (atomicidad)" do
      transfer.lines.create!(product: create(:product), quantity_requested: 5)

      result = Stock::Transfers::Dispatch.call(transfer:, user:, event_recorder: recorder)

      expect(result).to be_failure
      # NADA se movió: ni siquiera las líneas que sí tenían stock.
      expect(StockItem.find_by(product: producto_a, warehouse: origen).quantity_on_hand).to eq(100)
      expect(transfer.reload).to be_draft
    end
  end

  describe "recepción" do
    before { Stock::Transfers::Dispatch.call(transfer:, user:, event_recorder: recorder) }

    it "recepción completa: el tránsito queda en cero" do
      Stock::Transfers::Receive.call(transfer: transfer.reload, user:, event_recorder: recorder)

      expect(StockItem.find_by(product: producto_a, warehouse: destino).quantity_on_hand).to eq(40)
      expect(StockItem.find_by(product: producto_a, warehouse: transito).quantity_on_hand).to eq(0)
      expect(transfer.reload).to be_received
    end

    it "recepción PARCIAL: el faltante se imputa como scrap contra el tránsito" do
      Stock::Transfers::Receive.call(
        transfer: transfer.reload, user:, event_recorder: recorder,
        received_quantities: { producto_a.id => 37, producto_b.id => 20 }
      )

      expect(StockItem.find_by(product: producto_a, warehouse: destino).quantity_on_hand).to eq(37)
      # Los 3 que faltan NO quedan flotando en tránsito: se dan de baja.
      expect(StockItem.find_by(product: producto_a, warehouse: transito).quantity_on_hand).to eq(0)
      expect(transfer.reload.shrinkage).to eq(3)

      scrap = StockMovement.where(kind: "scrap").last
      expect(scrap.quantity).to eq(-3)
      expect(scrap.warehouse).to eq(transito)
    end

    it "rechaza recibir más de lo despachado" do
      result = Stock::Transfers::Receive.call(
        transfer: transfer.reload, user:, event_recorder: recorder,
        received_quantities: { producto_a.id => 999, producto_b.id => 20 }
      )
      expect(result.error.code).to eq(:invalid_quantity)
    end

    it "EXIGE informar todas las líneas despachadas (no adivina el resto)" do
      # Si aceptáramos un hash parcial habría que suponer algo, y las dos
      # suposiciones posibles son destructivas: dar por recibido lo que no
      # llegó (inventa stock) o dar por perdido lo que no se informó (lo
      # destruye como merma). Mejor exigir que el operador se pronuncie.
      result = Stock::Transfers::Receive.call(
        transfer: transfer.reload, user:, event_recorder: recorder,
        received_quantities: { producto_a.id => 40 }
      )

      expect(result.error.code).to eq(:incomplete_receipt)
      expect(result.error.details[:missing_product_ids]).to eq([ producto_b.id ])
      expect(transfer.reload).to be_in_transit   # nada cambió
    end

    it "el ledger cierra al final de todo el flujo" do
      Stock::Transfers::Receive.call(transfer: transfer.reload, user:, event_recorder: recorder)
      expect(StockItems::Reconciliation.call).to be_empty
    end
  end

  describe "prevención de deadlocks" do
    it "bloquea los stock_items SIEMPRE en el mismo orden (por id)" do
      # No podemos observar el lock directamente, pero sí verificar que la query
      # de bloqueo lleva ORDER BY id: ese es el mecanismo que evita el ciclo.
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end

      Stock::Transfers::Dispatch.call(transfer:, user:, event_recorder: recorder)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      lock_query = queries.find { |q| q.include?("FOR UPDATE") && q.include?("stock_items") }
      expect(lock_query).to be_present
      expect(lock_query).to match(/ORDER BY.*id/i)
    end
  end
end
