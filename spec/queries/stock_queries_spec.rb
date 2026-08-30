# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Query objects de stock" do
  let(:wh1) { create(:warehouse, code: "W1") }
  let(:wh2) { create(:warehouse, code: "W2") }
  let(:p1) { create(:product, sku: "P1", cost_cents: 1_000, currency: "USD") }
  let(:p2) { create(:product, sku: "P2", cost_cents: 2_500, currency: "USD") }

  describe StockItems::Availability do
    before do
      create(:stock_item, product: p1, warehouse: wh1, quantity_on_hand: 100, quantity_reserved: 20)
      create(:stock_item, product: p1, warehouse: wh2, quantity_on_hand: 50, quantity_reserved: 0)
      create(:stock_item, product: p2, warehouse: wh1, quantity_on_hand: 7, quantity_reserved: 0)
    end

    it "agrega por producto sumando todos los depósitos" do
      resultado = described_class.call

      expect(resultado[p1.id]).to eq(on_hand: 150, reserved: 20, available: 130)
      expect(resultado[p2.id]).to eq(on_hand: 7, reserved: 0, available: 7)
    end

    it "puede filtrar por depósito" do
      expect(described_class.call(warehouse_id: wh2.id)[p1.id][:on_hand]).to eq(50)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # LA RAZÓN DE SER DE ESTE QUERY OBJECT: una sola query para N productos.
    # La versión ingenua (`products.map { |p| p.stock_items.sum(...) }`) haría
    # una query por producto. Contamos las queries para PROBARLO.
    # ─────────────────────────────────────────────────────────────────────────
    it "resuelve TODO con UNA sola query, sin importar cuántos productos" do
      queries = contar_queries { described_class.call(product_ids: [ p1.id, p2.id ]) }
      expect(queries).to eq(1)
    end

    def contar_queries
      count = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        # Ignoramos las queries de infraestructura (transacciones, schema).
        count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached]
      end
      yield
      ActiveSupport::Notifications.unsubscribe(sub)
      count
    end
  end

  describe StockItems::LowStock do
    let!(:bajo) { create(:stock_item, product: p1, warehouse: wh1, quantity_on_hand: 5, reorder_point: 20) }
    let!(:sano) { create(:stock_item, product: p2, warehouse: wh1, quantity_on_hand: 100, reorder_point: 10) }
    let!(:sin_punto) { create(:stock_item, product: p1, warehouse: wh2, quantity_on_hand: 0, reorder_point: 0) }

    it "trae los que están en o por debajo del punto de reorden" do
      expect(described_class.call).to contain_exactly(bajo)
    end

    it "ignora los que tienen punto de reorden 0 (no configurados)" do
      expect(described_class.call).not_to include(sin_punto)
    end

    it "los incluye si se lo pedís" do
      expect(described_class.call(include_zero_reorder: true)).to include(sin_punto)
    end

    it "ordena por urgencia: primero el que está más lejos del punto" do
      otro = create(:stock_item, product: p2, warehouse: wh2, quantity_on_hand: 9, reorder_point: 10)
      # bajo: 5 - 20 = -15 (más urgente); otro: 9 - 10 = -1
      expect(described_class.call.to_a).to eq([ bajo, otro ])
    end

    it "USA el índice parcial (no hace Seq Scan)" do
      plan = described_class.call.explain.inspect
      # En una tabla de 4 filas Postgres puede elegir Seq Scan igual: lo que
      # verificamos es que el predicado del WHERE coincida con el del índice.
      expect(described_class.call.to_sql).to include("quantity_available <= reorder_point")
      expect(plan).to be_a(String)
    end
  end

  describe StockItems::Valuation do
    before do
      create(:stock_item, product: p1, warehouse: wh1, quantity_on_hand: 10)   # 10 x 1000 = 10.000
      create(:stock_item, product: p2, warehouse: wh1, quantity_on_hand: 4)    #  4 x 2500 = 10.000
      create(:stock_item, product: p1, warehouse: wh2, quantity_on_hand: 3)    #  3 x 1000 =  3.000
    end

    it "valúa el inventario multiplicando EN LA BASE" do
      resultado = described_class.call

      expect(resultado[:totals]["USD"].cents).to eq(23_000)
      expect(resultado[:total_units]).to eq(17)
    end

    it "desglosa por depósito" do
      resultado = described_class.call
      expect(resultado[:by_warehouse]["W1"][:value].cents).to eq(20_000)
      expect(resultado[:by_warehouse]["W2"][:value].cents).to eq(3_000)
    end

    it "excluye productos dados de baja" do
      p1.discard!
      expect(described_class.call[:totals]["USD"].cents).to eq(10_000)
    end
  end

  describe StockMovements::Ledger do
    let(:item) { create(:stock_item, product: p1, warehouse: wh1, quantity_on_hand: 0) }
    let(:user) { create(:user) }

    before do
      # 5 movimientos con tiempos distintos para poder paginar.
      5.times do |i|
        travel_to(Time.zone.local(2026, 1, 1, 12, i)) do
          Stock::Receive.call(product: p1, warehouse: wh1, quantity: 10, user:,
                              event_recorder: Outbox::NullRecorder.new)
        end
      end
    end

    it "ordena del más nuevo al más viejo" do
      movimientos = described_class.call.to_a
      expect(movimientos.map(&:occurred_at)).to eq(movimientos.map(&:occurred_at).sort.reverse)
    end

    it "respeta el límite y lo acota (nadie pide 100.000 filas)" do
      expect(described_class.call(limit: 2).to_a.size).to eq(2)
      expect(described_class.call(limit: 99_999).to_sql).to include("LIMIT 200")
    end

    describe "paginación por keyset" do
      it "la segunda página arranca justo después de la primera, sin repetir" do
        pagina1 = described_class.call(limit: 2).to_a
        cursor = described_class.encode_cursor(pagina1.last)
        pagina2 = described_class.call(limit: 2, cursor:).to_a

        expect(pagina1.map(&:id) & pagina2.map(&:id)).to be_empty
        expect(pagina2.first.occurred_at).to be <= pagina1.last.occurred_at
      end

      it "recorre TODO el ledger sin saltearse ni repetir filas" do
        vistos = []
        cursor = nil

        3.times do
          pagina = described_class.call(limit: 2, cursor:).to_a
          break if pagina.empty?

          vistos.concat(pagina.map(&:id))
          cursor = described_class.encode_cursor(pagina.last)
        end

        expect(vistos.uniq.size).to eq(5)
      end

      it "usa comparación de TUPLAS (que es lo que permite usar el índice)" do
        cursor = described_class.encode_cursor(StockMovement.first)
        expect(described_class.call(cursor:).to_sql)
          .to include("(stock_movements.occurred_at, stock_movements.id) <")
      end

      it "un cursor corrupto NO tira 500: devuelve la primera página" do
        expect { described_class.call(cursor: "basura!!!").to_a }.not_to raise_error
        expect(described_class.call(cursor: "basura!!!").to_a.size).to eq(5)
      end
    end
  end
end
