# frozen_string_literal: true

# ==============================================================================
# TEST UNITARIO PURO. Fijate que requiere `rails_helper` sólo porque Result vive
# bajo app/ y lo autocarga Zeitwerk; la clase en sí no toca base de datos ni
# framework. Estos tests corren en milisegundos y son los que más conviene tener.
# ==============================================================================
require "rails_helper"

RSpec.describe Result do
  describe ".success" do
    subject(:result) { described_class.success(42) }

    it { is_expected.to be_ok }
    it { is_expected.not_to be_failure }

    it "expone el valor" do
      expect(result.value).to eq(42)
    end

    it "no tiene error" do
      expect(result.error).to be_nil
    end

    it "es inmutable" do
      # `freeze` en el constructor: nadie puede mutar un Result después de crearlo.
      expect(result).to be_frozen
    end
  end

  describe ".failure" do
    subject(:result) { described_class.failure(:insufficient_stock, "No alcanza", available: 3) }

    it { is_expected.to be_failure }
    it { is_expected.not_to be_ok }

    it "guarda código, mensaje y detalles" do
      expect(result.error.code).to eq(:insufficient_stock)
      expect(result.error.message).to eq("No alcanza")
      expect(result.error.details).to eq(available: 3)
    end

    it "el error es un Data inmutable" do
      expect(result.error).to be_a(Result::Error)
      expect(result.error).to be_frozen
    end
  end

  describe "#then_try (composición monádica)" do
    it "encadena mientras haya éxito" do
      final = described_class.success(1)
                             .then_try { |v| described_class.success(v + 1) }
                             .then_try { |v| described_class.success(v * 10) }

      expect(final.value).to eq(20)
    end

    it "CORTA la cadena en el primer fallo y no ejecuta lo siguiente" do
      ejecutado = false

      final = described_class.success(1)
                             .then_try { described_class.failure(:boom, "explotó") }
                             .then_try { ejecutado = true; described_class.success(99) }

      expect(final).to be_failure
      expect(final.error.code).to eq(:boom)
      expect(ejecutado).to be(false)   # <- esto es lo importante del patrón
    end
  end

  describe "#map" do
    it "transforma el valor de éxito" do
      expect(described_class.success(2).map { |v| v * 5 }.value).to eq(10)
    end

    it "no toca el error" do
      failure = described_class.failure(:x, "y")
      expect(failure.map { raise "no debería llamarse" }).to eq(failure)
    end
  end

  describe "#value!" do
    it "devuelve el valor si está ok" do
      expect(described_class.success(:ok).value!).to eq(:ok)
    end

    it "levanta Result::Failure si falló" do
      expect { described_class.failure(:nope, "mal").value! }
        .to raise_error(Result::Failure, /nope: mal/)
    end
  end

  describe "pattern matching" do
    it "matchea por hash (deconstruct_keys)" do
      resultado = described_class.success({ id: 7 })

      salida = case resultado
      in { ok: true, value: { id: Integer => id } } then "ok #{id}"
      in { ok: false } then "error"
      end

      expect(salida).to eq("ok 7")
    end

    it "matchea el fallo y liga el error" do
      resultado = described_class.failure(:conflict, "chocó")

      salida = case resultado
      in { ok: true } then "ok"
      in { ok: false, error: { code: :conflict } } then "conflicto"
      end

      expect(salida).to eq("conflicto")
    end

    it "matchea por array (deconstruct)" do
      case described_class.success(5)
      in [ true, valor ]
        expect(valor).to eq(5)
      end
    end
  end
end
