# frozen_string_literal: true

require "rails_helper"

RSpec.describe Stock::Issue do
  let(:user) { create(:user, :operator) }
  let(:product) { create(:product) }
  let(:warehouse) { create(:warehouse) }
  let(:recorder) { Outbox::NullRecorder.new }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100, quantity_reserved: 0) }

  def issue(quantity, **options)
    described_class.call(product:, warehouse:, quantity:, user:, event_recorder: recorder, **options)
  end

  it "descuenta del stock físico" do
    issue(30)
    expect(item.reload.quantity_on_hand).to eq(70)
  end

  it "el cliente manda una cantidad POSITIVA y el dominio le pone el signo" do
    movement = issue(30).value
    expect(movement.quantity).to eq(-30)
    expect(movement.kind).to eq("issue")
    expect(movement.quantity_after).to eq(70)
  end

  it "rechaza sacar más de lo que hay" do
    result = issue(500)
    expect(result.error.code).to eq(:insufficient_stock)
    expect(result.error.details).to include(requested: 500)
    expect(item.reload.quantity_on_hand).to eq(100)   # intacto
  end

  it "RESPETA LO RESERVADO: no podés sacar stock comprometido con otro" do
    item.update!(quantity_reserved: 90)   # disponible = 10

    result = issue(50)   # hay 100 físicos, pero sólo 10 disponibles

    expect(result).to be_failure
    expect(result.error.code).to eq(:insufficient_available_stock)
    expect(item.reload.quantity_on_hand).to eq(100)
  end

  it "permite sacar exactamente lo disponible (caso borde)" do
    item.update!(quantity_reserved: 90)   # 100 físicos, 10 disponibles

    expect(issue(10)).to be_ok

    item.reload
    expect(item.quantity_on_hand).to eq(90)     # salieron 10 de los 100
    expect(item.quantity_reserved).to eq(90)    # las reservas siguen ahí
    expect(item.quantity_available).to eq(0)    # y ya no queda nada disponible
  end

  it "falla si el producto no tiene stock en ese depósito" do
    otro = create(:warehouse)
    result = described_class.call(product:, warehouse: otro, quantity: 1, user:, event_recorder: recorder)
    expect(result.error.code).to eq(:stock_item_not_found)
  end

  it "no crea el stock_item por las dudas (a diferencia de Receive)" do
    otro = create(:warehouse)
    expect {
      described_class.call(product:, warehouse: otro, quantity: 1, user:, event_recorder: recorder)
    }.not_to change(StockItem, :count)
  end
end
