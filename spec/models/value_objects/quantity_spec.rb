# frozen_string_literal: true

require "rails_helper"

RSpec.describe ValueObjects::Quantity do
  it "no deja operar unidades distintas (el bug que el tipo previene)" do
    kilos = described_class.new(amount: 5, unit: "kg")
    unidades = described_class.new(amount: 3, unit: "unit")

    expect { kilos + unidades }.to raise_error(described_class::UnitMismatch)
  end

  it "rechaza una unidad desconocida" do
    expect { described_class.new(amount: 1, unit: "parsecs") }
      .to raise_error(described_class::InvalidUnit, /parsecs/)
  end

  it "exige un entero de verdad" do
    # Integer() explota con basura, a diferencia de to_i que devuelve 0 callado.
    expect { described_class.new(amount: "diez") }.to raise_error(ArgumentError)
  end

  it "suma y resta dentro de la misma unidad" do
    a = described_class.new(amount: 10, unit: "kg")
    b = described_class.new(amount: 4, unit: "kg")

    expect((a + b).amount).to eq(14)
    expect((a - b).amount).to eq(6)
  end

  it "permite cantidades negativas (un egreso del ledger)" do
    expect(described_class.new(amount: -5).negative?).to be(true)
    expect(described_class.new(amount: -5).abs.amount).to eq(5)
  end

  it "es comparable" do
    a = described_class.new(amount: 1, unit: "kg")
    b = described_class.new(amount: 2, unit: "kg")
    expect(a).to be < b
    expect([ b, a ].min).to eq(a)
  end
end
