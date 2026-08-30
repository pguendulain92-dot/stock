# frozen_string_literal: true

require "rails_helper"

RSpec.describe Products::Search do
  let!(:tornillo) { create(:product, sku: "TOR-001", name: "Tornillo hexagonal 5mm") }
  let!(:martillo) { create(:product, sku: "MAR-500", name: "Martillo carpintero") }
  let!(:baja) { create(:product, :discarded, sku: "OLD-001", name: "Producto viejo") }

  it "devuelve una Relation, NO un array (así el que llama puede seguir componiendo)" do
    expect(described_class.call).to be_a(ActiveRecord::Relation)
  end

  it "excluye los productos dados de baja por defecto" do
    expect(described_class.call).to include(tornillo, martillo)
    expect(described_class.call).not_to include(baja)
  end

  it "los incluye si se lo pedís explícitamente" do
    expect(described_class.call(include_discarded: true)).to include(baja)
  end

  describe "búsqueda por término" do
    it "encuentra por SKU exacto" do
      expect(described_class.call(term: "TOR-001")).to contain_exactly(tornillo)
    end

    it "es case-insensitive en el SKU" do
      expect(described_class.call(term: "tor-001")).to contain_exactly(tornillo)
    end

    it "encuentra por substring del nombre" do
      expect(described_class.call(term: "hexagonal")).to contain_exactly(tornillo)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ESCAPE DE COMODINES: sin `sanitize_sql_like`, un usuario escribe "%" y
    # fuerza un escaneo completo de la tabla. Es un DoS de un carácter.
    # ─────────────────────────────────────────────────────────────────────────
    it "escapa los comodines de LIKE en vez de interpretarlos" do
      resultados = described_class.call(term: "%")
      expect(resultados).to be_empty   # "%" se busca literalmente, no matchea nada
    end

    it "escapa el guion bajo (que en LIKE es 'cualquier carácter')" do
      create(:product, sku: "AXB-1", name: "Otro")
      expect(described_class.call(term: "A_B-1")).to be_empty
    end
  end

  describe "ordenamiento" do
    it "acepta sólo criterios de una ALLOW-LIST" do
      # Un `sort` inventado NO se interpola en el SQL: cae al default.
      expect { described_class.call(sort: "name; DROP TABLE products").to_a }.not_to raise_error
      expect(Product.count).to eq(3)
    end

    it "SIEMPRE desempata por id (si no, la paginación repite o saltea filas)" do
      sql = described_class.call(sort: "name").to_sql
      expect(sql).to match(/ORDER BY.*"name" ASC.*"id" ASC/i)
    end
  end

  describe "prevención de N+1", :n_plus_one do
    it "trae la categoría con includes" do
      create_list(:product, 5, :with_category)

      # Con Bullet.raise = true, si esto generara N+1 el test ROMPE.
      described_class.call.to_a.each { |p| p.category&.name }
    end
  end
end
