# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product do
  # `subject` implícito + shoulda-matchers = specs de validación de una línea.
  subject { build(:product) }

  describe "validaciones" do
    it { is_expected.to validate_presence_of(:sku) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(200) }
    it { is_expected.to validate_inclusion_of(:unit).in_array(described_class::UNITS) }

    # OJO: este matcher hace un INSERT para probar la unicidad. Es de los pocos
    # que tocan la base, por eso el subject tiene que estar guardado o guardable.
    it { is_expected.to validate_uniqueness_of(:sku).case_insensitive }

    describe "formato del SKU" do
      it "acepta alfanuméricos, punto, guion y guion bajo" do
        expect(build(:product, sku: "ABC-123_X.1")).to be_valid
      end

      it "rechaza minúsculas... normalizándolas primero" do
        product = build(:product, sku: "abc-123")
        expect(product).to be_valid
        expect(product.sku).to eq("ABC-123")   # `normalizes` lo pasa a mayúsculas
      end

      it "rechaza caracteres no ASCII" do
        expect(build(:product, sku: "CAÑ-110")).not_to be_valid
      end

      # ─────────────────────────────────────────────────────────────────────
      # ESTE TEST VALE ORO Y CASI NADIE LO ESCRIBE.
      # En Ruby, ^ y $ significan principio/fin de LÍNEA. Si el regex usara
      # ^...$ en vez de \A...\z, un SKU con un salto de línea pasaría la
      # validación llevando un payload adentro. Es un vector real de inyección.
      # ─────────────────────────────────────────────────────────────────────
      it "rechaza un salto de línea con payload (anclas \\A y \\z, no ^ y $)" do
        expect(build(:product, sku: "VALIDO\n<script>alert(1)</script>")).not_to be_valid
      end
    end
  end

  describe "asociaciones" do
    it { is_expected.to belong_to(:category).optional }
    it { is_expected.to have_many(:stock_items) }
    it { is_expected.to have_many(:stock_movements) }
    it { is_expected.to have_many(:suppliers).through(:product_suppliers) }
  end

  describe "dinero" do
    # `build_stubbed` NO toca la base: crea un objeto con un id falso y
    # asociaciones stubbeadas. Es entre 5 y 10 veces más rápido que `create`.
    # Usalo SIEMPRE que el test no necesite persistencia real.
    let(:product) { build_stubbed(:product, cost_cents: 1_000, price_cents: 2_500, currency: "USD") }

    it "expone cost y price como Value Objects" do
      expect(product.cost).to be_a(ValueObjects::Money)
      expect(product.cost.cents).to eq(1_000)
    end

    it "calcula el margen" do
      expect(product.margin.cents).to eq(1_500)
      expect(product.margin_ratio).to eq(0.6)
    end

    it "no divide por cero si el precio es 0" do
      free = build_stubbed(:product, price_cents: 0, cost_cents: 100)
      expect(free.margin_ratio).to eq(0.0)
      expect(free.margin.cents).to eq(0)
    end

    it "acepta asignar un Money" do
      product.cost = ValueObjects::Money.from_amount("12.34", "USD")
      expect(product.cost_cents).to eq(1_234)
    end

    it "rechaza asignar cualquier otra cosa" do
      expect { product.cost = "carísimo" }.to raise_error(ArgumentError, /espera Money o Integer/)
    end
  end

  describe "soft delete" do
    let(:product) { create(:product) }

    it "marca discarded_at sin borrar la fila" do
      expect { product.discard! }.to change(product, :discarded?).from(false).to(true)
      expect(described_class.unscoped.where(id: product.id)).to exist
    end

    it "los scopes kept/discarded son EXPLÍCITOS (no hay default_scope)" do
      product.discard!
      # Si hubiera default_scope, este count daría 0 y te volverías loco.
      expect(described_class.count).to eq(1)
      expect(described_class.kept.count).to eq(0)
      expect(described_class.discarded.count).to eq(1)
    end
  end

  describe "constraints de la base (la red que las validaciones no atrapan)" do
    it "rechaza un costo negativo aunque saltees las validaciones" do
      product = create(:product)
      # `update_column` SALTEA validaciones y callbacks: va directo al UPDATE.
      # Es exactamente el camino por el que se cuela la basura... y acá se ve
      # que el CHECK constraint la frena igual.
      expect { product.update_column(:cost_cents, -1) }
        .to raise_error(ActiveRecord::StatementInvalid, /products_cost_check/)
    end

    it "rechaza una unidad inválida a nivel base" do
      product = create(:product)
      expect { product.update_column(:unit, "parsecs") }
        .to raise_error(ActiveRecord::StatementInvalid, /products_unit_check/)
    end
  end

  describe "optimistic locking" do
    it "levanta StaleObjectError si otro proceso ya modificó la fila" do
      product = create(:product)
      copia_a = described_class.find(product.id)
      copia_b = described_class.find(product.id)

      copia_a.update!(name: "Ganador")

      expect { copia_b.update!(name: "Perdedor") }
        .to raise_error(ActiveRecord::StaleObjectError)
    end
  end
end
