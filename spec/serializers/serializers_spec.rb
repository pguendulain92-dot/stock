# frozen_string_literal: true

require "rails_helper"

# Los serializers son POROs: los tests son puro Ruby, sin HTTP ni framework.
# Testear el CONTRATO de la API acá (y no sólo en los request specs) hace que
# un cambio accidental en el JSON rompa un test rápido y localizado.
RSpec.describe "Serializers" do
  describe ProductSerializer do
    let(:product) { create(:product, sku: "ABC-1", name: "Cosa", cost_cents: 1_000, price_cents: 2_500) }

    it "expone sólo los campos del contrato" do
      json = described_class.new(product).as_json

      expect(json.keys).to contain_exactly(
        :id, :sku, :name, :unit, :active, :discarded, :cost, :price, :created_at, :updated_at
      )
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ESTE TEST ES EL QUE JUSTIFICA NO USAR `render json: modelo`.
    # Si mañana alguien agrega una columna con datos sensibles, `to_json` la
    # publicaría sola. Con serializer explícito, este test falla primero.
    # ─────────────────────────────────────────────────────────────────────────
    it "NO filtra columnas internas aunque existan en el modelo" do
      json = described_class.new(product).as_json
      expect(json).not_to have_key(:lock_version)
      expect(json).not_to have_key(:attributes_data)
      expect(json).not_to have_key(:discarded_at)
    end

    it "el dinero viaja con escala explícita, no como número suelto" do
      json = described_class.new(product).as_json
      expect(json[:cost]).to eq(cents: 1_000, currency: "USD", formatted: "USD 10.00")
    end

    it "la disponibilidad se INYECTA (no la consulta el serializer)" do
      json = described_class.new(product, availability: { on_hand: 5, reserved: 1, available: 4 }).as_json
      expect(json[:availability]).to eq(on_hand: 5, reserved: 1, available: 4)
    end

    it "`compact` saca las claves nulas para no mandar ruido" do
      json = described_class.new(product).as_json
      expect(json).not_to have_key(:category)   # el producto no tiene categoría
    end

    it "serializa colecciones" do
      product          # `let` es PEREZOSO: sin esta línea el primero no existe
      create(:product) # y el test contaría 1 en vez de 2. Trampa clásica de RSpec.
      expect(described_class.collection(Product.all).size).to eq(2)
    end
  end

  describe StockItemSerializer do
    let(:item) { create(:stock_item, quantity_on_hand: 100, quantity_reserved: 30) }

    it "devuelve las tres cantidades y el flag de reposición" do
      json = described_class.new(item.reload).as_json

      expect(json).to include(quantity_on_hand: 100, quantity_reserved: 30, quantity_available: 70)
      expect(json[:below_reorder_point]).to be(false)
    end

    it "EXPONE lock_version a propósito: habilita optimistic locking sobre HTTP" do
      json = described_class.new(item.reload).as_json
      expect(json[:lock_version]).to eq(item.lock_version)
    end
  end

  describe ErrorSerializer do
    it "arma un error uniforme desde un Result" do
      result = Result.failure(:insufficient_stock, "No alcanza", available: 3)
      json = described_class.from_result(result, status: 422)

      expect(json[:error]).to eq(code: "insufficient_stock", message: "No alcanza",
                                 details: { available: 3 })
      expect(json[:status]).to eq(422)
    end

    it "arma un error desde un registro inválido, campo por campo" do
      product = Product.new
      product.valid?

      json = described_class.from_record(product, status: 422)

      expect(json.dig(:error, :code)).to eq("validation_failed")
      # `errors.to_hash(true)` devuelve las claves como SÍMBOLOS. Al pasar por
      # `render json:` se convierten en strings; acá, en Ruby puro, siguen
      # siendo símbolos. Es una diferencia que confunde seguido.
      expect(json.dig(:error, :details)).to have_key(:sku)
    end

    it "omite `details` cuando está vacío en vez de mandar null" do
      json = described_class.simple(:not_found, "No está", status: 404)
      expect(json[:error]).not_to have_key(:details)
    end
  end
end
