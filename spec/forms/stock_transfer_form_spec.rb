# frozen_string_literal: true

require "rails_helper"

RSpec.describe StockTransferForm do
  let(:user) { create(:user, :manager) }
  let!(:origen) { create(:warehouse, code: "AAA") }
  let!(:destino) { create(:warehouse, code: "BBB") }
  let!(:p1) { create(:product, sku: "P-1") }
  let!(:p2) { create(:product, sku: "P-2") }

  def build_form(**overrides)
    form = described_class.new(
      source_warehouse_code: "AAA", destination_warehouse_code: "BBB", **overrides.except(:lines)
    )
    form.lines = overrides.fetch(:lines, [ { sku: "P-1", quantity: 5 } ])
    form.requested_by = user
    form
  end

  it "crea la transferencia y sus líneas en UNA transacción" do
    result = build_form(lines: [ { sku: "P-1", quantity: 5 }, { sku: "P-2", quantity: 3 } ]).save

    expect(result).to be_ok
    transfer = result.value
    expect(transfer.lines.count).to eq(2)
    expect(transfer.total_units_requested).to eq(8)
    expect(transfer.reference).to match(/\ATR-\d{4}-\d{6}\z/)
  end

  it "devuelve un Result (misma interfaz que los services: LSP)" do
    expect(build_form.save).to be_a(Result)
  end

  describe "validaciones del INPUT (no del modelo)" do
    it "rechaza un depósito inexistente" do
      result = build_form(source_warehouse_code: "ZZZ").save
      expect(result.error.code).to eq(:validation_failed)
      expect(result.error.details[:errors]).to have_key(:source_warehouse_code)
    end

    it "rechaza origen igual a destino" do
      expect(build_form(destination_warehouse_code: "AAA").save.error.message)
        .to include("debe ser distinto del origen")
    end

    it "rechaza una lista de líneas vacía" do
      expect(build_form(lines: []).save.error.message).to include("no puede estar vacío")
    end

    it "rechaza un SKU inexistente indicando el NÚMERO DE LÍNEA" do
      result = build_form(lines: [ { sku: "P-1", quantity: 1 }, { sku: "NO-EXISTE", quantity: 1 } ]).save
      expect(result.error.message).to include("línea 2").and include("NO-EXISTE")
    end

    it "rechaza cantidades no positivas" do
      expect(build_form(lines: [ { sku: "P-1", quantity: 0 } ]).save.error.message)
        .to include("cantidad debe ser positiva")
    end

    it "rechaza el mismo SKU repetido (el índice único lo rechazaría igual, pero con peor mensaje)" do
      result = build_form(lines: [ { sku: "P-1", quantity: 1 }, { sku: "P-1", quantity: 2 } ]).save
      expect(result.error.message).to include("repetido")
    end

    it "no deja NADA a medio crear cuando falla" do
      expect { build_form(lines: [ { sku: "NO-EXISTE", quantity: 1 } ]).save }
        .not_to change(StockTransfer, :count)
    end
  end

  describe "eficiencia" do
    it "busca TODOS los SKUs con una sola query, no uno por línea" do
      lineas = 20.times.map { { sku: "P-1", quantity: 1 } }
      form = build_form(lines: lineas)

      queries = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 if payload[:sql].include?("products")
      end
      form.valid?
      ActiveSupport::Notifications.unsubscribe(sub)

      expect(queries).to eq(1)   # sin el memo + index_by serían 20
    end
  end
end
