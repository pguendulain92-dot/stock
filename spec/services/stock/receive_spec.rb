# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# SPEC DE SERVICE OBJECT — el tipo de test más valioso de esta suite.
#
# Testea una REGLA DE NEGOCIO completa de punta a punta (base incluida) pero SIN
# HTTP. Es rápido, no depende de rutas ni de vistas, y si mañana cambia la API
# esta prueba sigue siendo válida. La pirámide de tests dice: la mayor parte de
# tu cobertura de lógica tiene que estar acá, no en los request specs.
# ==============================================================================
RSpec.describe Stock::Receive do
  let(:user) { create(:user, :operator) }
  let(:product) { create(:product, cost_cents: 500) }
  let(:warehouse) { create(:warehouse) }

  # INYECCIÓN DE DEPENDENCIAS: le pasamos un recorder que sólo acumula en
  # memoria. Así verificamos qué eventos se emitieron sin escribir en la tabla
  # outbox ni encolar jobs. Esto es DIP en acción, y sin ningún framework de DI.
  let(:recorder) { Outbox::NullRecorder.new }

  def receive(quantity, **options)
    described_class.call(product:, warehouse:, quantity:, user:,
                         event_recorder: recorder, **options)
  end

  describe "camino feliz" do
    it "crea el stock_item si no existía" do
      expect { receive(50) }.to change(StockItem, :count).by(1)
    end

    it "suma al stock físico" do
      receive(50)
      item = StockItem.find_by(product:, warehouse:)
      expect(item.quantity_on_hand).to eq(50)
      expect(item.quantity_available).to eq(50)
    end

    it "escribe UN asiento en el ledger con el saldo resultante" do
      result = receive(50)

      movement = result.value
      expect(movement).to be_a(StockMovement)
      expect(movement.kind).to eq("receipt")
      expect(movement.quantity).to eq(50)
      expect(movement.quantity_after).to eq(50)
      expect(movement.user).to eq(user)
    end

    it "acumula sobre lo que ya había" do
      receive(30)
      receive(20)
      expect(StockItem.find_by(product:, warehouse:).quantity_on_hand).to eq(50)
    end

    it "toma el costo del producto si no le pasás uno" do
      expect(receive(10).value.unit_cost_cents).to eq(500)
    end

    it "emite el evento de dominio con el estado resultante" do
      receive(50)

      evento = recorder.recorded.last
      expect(evento[:event_type]).to eq("stock.receipt")
      expect(evento[:payload]).to include(quantity: 50, quantity_on_hand: 50, product_sku: product.sku)
    end

    it "mantiene la invariante ledger == proyección" do
      receive(30)
      receive(20)
      expect(StockItems::Reconciliation.call).to be_empty
    end
  end

  describe "reglas de negocio" do
    it "rechaza cantidad cero o negativa SIN excepción, con un Result" do
      result = receive(0)
      expect(result).to be_failure
      expect(result.error.code).to eq(:invalid_quantity)
    end

    it "rechaza un depósito inactivo" do
      warehouse.update!(active: false)
      expect(receive(10).error.code).to eq(:warehouse_inactive)
    end

    it "rechaza un producto dado de baja" do
      product.discard!
      expect(receive(10).error.code).to eq(:product_discarded)
    end

    it "no deja rastro cuando falla (la transacción revierte todo)" do
      product.discard!
      expect { receive(10) }.not_to change(StockMovement, :count)
      expect(recorder.recorded).to be_empty
    end
  end

  describe "idempotencia" do
    it "con la misma clave, aplica UNA sola vez" do
      key = SecureRandom.uuid
      primero = receive(10, idempotency_key: key)
      segundo = receive(10, idempotency_key: key)

      expect(segundo.value.id).to eq(primero.value.id)
      expect(StockItem.find_by(product:, warehouse:).quantity_on_hand).to eq(10)
      expect(StockMovement.count).to eq(1)
    end

    it "claves distintas sí aplican dos veces" do
      receive(10, idempotency_key: "a")
      receive(10, idempotency_key: "b")
      expect(StockItem.find_by(product:, warehouse:).quantity_on_hand).to eq(20)
    end
  end

  describe "inyección del reloj" do
    it "usa el reloj que le pasás (sin sleep, sin esperar)" do
      momento = Time.zone.local(2026, 1, 15, 10, 30)
      # Un doble VERIFICADO: si `Time` no respondiera `current`, el test fallaría.
      reloj = class_double(Time, current: momento)

      result = described_class.call(product:, warehouse:, quantity: 5, user:,
                                    event_recorder: recorder, clock: reloj)

      expect(result.value.occurred_at).to be_within(1.second).of(momento)
    end
  end
end
