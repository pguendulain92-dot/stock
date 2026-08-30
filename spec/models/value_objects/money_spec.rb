# frozen_string_literal: true

require "rails_helper"

RSpec.describe ValueObjects::Money do
  describe "construcción" do
    it "acepta centavos y moneda" do
      money = described_class.new(cents: 1_999, currency: "usd")
      expect(money.cents).to eq(1_999)
      expect(money.currency).to eq("USD")   # normaliza a mayúsculas
    end

    it "construye desde un importe humano SIN error de punto flotante" do
      # Este es EL test que justifica que exista la clase.
      money = described_class.from_amount("19.99", "USD")
      expect(money.cents).to eq(1_999)
    end

    it "maneja monedas sin subunidad (CLP, JPY)" do
      expect(described_class.from_amount("1500", "CLP").cents).to eq(1_500)
      expect(described_class.new(cents: 1_500, currency: "CLP").to_s).to eq("CLP 1500")
    end
  end

  describe "aritmética" do
    let(:diez) { described_class.new(cents: 1_000, currency: "USD") }
    let(:cinco) { described_class.new(cents: 500, currency: "USD") }

    it "suma y resta" do
      expect((diez + cinco).cents).to eq(1_500)
      expect((diez - cinco).cents).to eq(500)
    end

    it "multiplica por un escalar" do
      expect((diez * 3).cents).to eq(3_000)
    end

    it "RECHAZA multiplicar dinero por dinero" do
      expect { diez * cinco }.to raise_error(ArgumentError, /dinero por dinero/)
    end

    it "RECHAZA operar monedas distintas" do
      euros = described_class.new(cents: 100, currency: "EUR")
      expect { diez + euros }.to raise_error(described_class::CurrencyMismatch)
    end

    it "niega con el operador unario" do
      expect((-diez).cents).to eq(-1_000)
    end
  end

  describe "comparación" do
    it "ordena por centavos" do
      valores = [ 300, 100, 200 ].map { |c| described_class.new(cents: c, currency: "USD") }
      expect(valores.sort.map(&:cents)).to eq([ 100, 200, 300 ])
    end

    it "compara por VALOR, no por identidad (semántica de Value Object)" do
      a = described_class.new(cents: 100, currency: "USD")
      b = described_class.new(cents: 100, currency: "USD")

      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)   # -> sirve como clave de Hash y en un Set
      expect(a).not_to equal(b)      # -> son objetos distintos
    end
  end

  describe "serialización" do
    it "expone centavos, moneda y formato para que el front no adivine la escala" do
      expect(described_class.new(cents: 1_999, currency: "USD").as_json)
        .to eq(cents: 1_999, currency: "USD", formatted: "USD 19.99")
    end
  end

  describe "inmutabilidad" do
    it "no tiene setters" do
      money = described_class.new(cents: 100, currency: "USD")
      expect(money).not_to respond_to(:cents=)
    end

    it "`with` devuelve una copia nueva sin mutar el original" do
      original = described_class.new(cents: 100, currency: "USD")
      copia = original.with(cents: 500)

      expect(original.cents).to eq(100)
      expect(copia.cents).to eq(500)
    end
  end
end
