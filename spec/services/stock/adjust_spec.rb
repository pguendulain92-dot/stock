# frozen_string_literal: true

require "rails_helper"

RSpec.describe Stock::Adjust do
  let(:user) { create(:user, :manager) }
  let(:product) { create(:product) }
  let(:warehouse) { create(:warehouse) }
  let(:recorder) { Outbox::NullRecorder.new }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 50) }

  def adjust(counted, reason: "Conteo cíclico")
    described_class.call(product:, warehouse:, counted_quantity: counted,
                         user:, reason:, event_recorder: recorder)
  end

  it "registra la DIFERENCIA como movimiento, no sobreescribe la cantidad" do
    movement = adjust(47).value

    expect(movement.kind).to eq("count_correction")
    expect(movement.quantity).to eq(-3)        # <- el HECHO es la diferencia
    expect(movement.quantity_after).to eq(47)
    expect(item.reload.quantity_on_hand).to eq(47)
  end

  it "registra una diferencia positiva (apareció mercadería)" do
    expect(adjust(55).value.quantity).to eq(5)
  end

  it "guarda el conteo y el valor previo en la metadata (auditoría)" do
    movement = adjust(47).value
    expect(movement.metadata).to include("counted" => 47, "previous" => 50)
  end

  it "no hace nada si el conteo coincide" do
    result = adjust(50)
    expect(result).to be_ok
    expect(result.value).to be_nil
    expect(StockMovement.count).to eq(0)
  end

  it "EXIGE un motivo: un ajuste sin explicación no es auditable" do
    expect(adjust(10, reason: nil).error.code).to eq(:reason_required)
    expect(adjust(10, reason: "  ").error.code).to eq(:reason_required)
  end

  it "rechaza un conteo negativo" do
    expect(adjust(-1).error.code).to eq(:invalid_quantity)
  end

  it "actualiza last_counted_at" do
    expect { adjust(47) }.to change { item.reload.last_counted_at }.from(nil)
  end

  it "el ledger sigue cerrando después del ajuste" do
    # OJO: la factory `:stock_item` setea quantity_on_hand DIRECTAMENTE, sin
    # movimientos que la respalden — o sea que ya arranca "descuadrada" respecto
    # del ledger. Eso es cómodo para la mayoría de los tests, pero acá estamos
    # justamente verificando la invariante, así que construimos el stock inicial
    # con el service, como pasa en la vida real.
    item.destroy!
    Stock::Receive.call(product:, warehouse:, quantity: 50, user:, event_recorder: recorder)
    expect(StockItems::Reconciliation.call).to be_empty

    adjust(47)

    expect(StockItems::Reconciliation.call).to be_empty
    expect(StockItem.find_by(product:, warehouse:).quantity_on_hand).to eq(47)
  end
end
