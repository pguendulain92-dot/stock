# frozen_string_literal: true

require "rails_helper"

RSpec.describe StockItem do
  subject { build(:stock_item) }

  describe "validaciones y asociaciones" do
    it { is_expected.to belong_to(:product) }
    it { is_expected.to belong_to(:warehouse) }
    it { is_expected.to validate_numericality_of(:quantity_on_hand).is_greater_than_or_equal_to(0).only_integer }
  end

  describe "la columna generada quantity_available" do
    let(:item) { create(:stock_item, quantity_on_hand: 100, quantity_reserved: 30) }

    it "la calcula Postgres, no Ruby" do
      expect(item.reload.quantity_available).to eq(70)
    end

    it "se actualiza sola al cambiar cualquiera de las dos" do
      item.update!(quantity_reserved: 45)
      expect(item.reload.quantity_available).to eq(55)
    end

    it "es de sólo lectura: ActiveRecord ni siquiera la manda en el UPDATE" do
      # Rails detecta las columnas generadas y las excluye de los INSERT/UPDATE.
      expect(described_class.columns_hash["quantity_available"].virtual?).to be(true)
    end
  end

  describe "invariantes en la base" do
    let(:item) { create(:stock_item, quantity_on_hand: 10, quantity_reserved: 0) }

    it "no permite stock físico negativo" do
      expect { item.update_column(:quantity_on_hand, -1) }
        .to raise_error(ActiveRecord::StatementInvalid, /on_hand_non_negative/)
    end

    it "no permite reservar más de lo que hay" do
      expect { item.update_column(:quantity_reserved, 50) }
        .to raise_error(ActiveRecord::StatementInvalid, /reserved_lte_on_hand/)
    end

    it "no permite dos filas para el mismo par producto/depósito" do
      expect { create(:stock_item, product: item.product, warehouse: item.warehouse) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "scopes" do
    let!(:bajo) { create(:stock_item, quantity_on_hand: 5, reorder_point: 20) }
    let!(:sano) { create(:stock_item, quantity_on_hand: 100, reorder_point: 10) }
    let!(:vacio) { create(:stock_item, quantity_on_hand: 0, reorder_point: 0) }

    it "needing_reorder trae los que están en o bajo el punto de reorden" do
      expect(described_class.needing_reorder).to include(bajo, vacio)
      expect(described_class.needing_reorder).not_to include(sano)
    end

    it "in_stock / out_of_stock filtran por disponible" do
      expect(described_class.in_stock).to include(bajo, sano)
      expect(described_class.out_of_stock).to include(vacio)
    end
  end

  describe ".find_or_provision!" do
    let(:product) { create(:product) }
    let(:warehouse) { create(:warehouse) }

    it "crea el item si no existe" do
      expect { described_class.find_or_provision!(product:, warehouse:) }
        .to change(described_class, :count).by(1)
    end

    it "devuelve el existente si ya está" do
      existente = create(:stock_item, product:, warehouse:)
      expect(described_class.find_or_provision!(product:, warehouse:)).to eq(existente)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # TEST DE REGRESIÓN DE UN BUG REAL.
    #
    # Los tres llamadores de find_or_provision! lo invocan DENTRO de una
    # transacción. En Postgres, una sentencia que falla ABORTA la transacción
    # entera: el `find_by!` del rescate moría con PG::InFailedSqlTransaction.
    # El arreglo es el SAVEPOINT (`transaction(requires_new: true)`).
    #
    # Simulamos la carrera creando la fila desde OTRA conexión (no se puede
    # simular con un stub: hace falta que el UNIQUE reviente de verdad).
    # ─────────────────────────────────────────────────────────────────────────
    it "sobrevive a la carrera DENTRO de una transacción (savepoint)" do
      # Creamos el "ganador" en una conexión aparte y commiteada, para que el
      # find_by inicial no lo vea pero el INSERT sí choque.
      ganador = nil
      hilo = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ganador = described_class.create!(product:, warehouse:)
        end
      end
      hilo.join

      resultado = nil
      expect {
        ApplicationRecord.transaction do
          # Forzamos el camino del rescue: el find_by inicial devuelve nil.
          allow(described_class).to receive(:find_by).and_call_original
          allow(described_class).to receive(:find_by)
            .with(product:, warehouse:).and_return(nil, ganador)

          resultado = described_class.find_or_provision!(product:, warehouse:)

          # La prueba de fuego: después del rescue, la transacción SIGUE VIVA.
          # Con el bug, esta línea moría con PG::InFailedSqlTransaction.
          described_class.count
        end
      }.not_to raise_error

      expect(resultado).to eq(ganador)
    end

    it "sobrevive a una carrera perdida contra el índice único" do
      # Simulamos que otro proceso insertó entre nuestro `find_by` y el `create!`.
      # Es EXACTAMENTE la race condition de find_or_create_by.
      otro = create(:stock_item, product:, warehouse:)
      allow(described_class).to receive(:find_by).and_return(nil, otro)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
      allow(described_class).to receive(:find_by!).and_return(otro)

      expect(described_class.find_or_provision!(product:, warehouse:)).to eq(otro)
    end
  end

  describe ".atomically_decrement" do
    let!(:item) { create(:stock_item, quantity_on_hand: 10, quantity_reserved: 0) }

    it "descuenta si hay disponible" do
      expect(described_class.atomically_decrement(item.id, 4)).to be(true)
      expect(item.reload.quantity_on_hand).to eq(6)
    end

    it "NO descuenta ni rompe si no alcanza: devuelve false" do
      expect(described_class.atomically_decrement(item.id, 999)).to be(false)
      expect(item.reload.quantity_on_hand).to eq(10)
    end

    it "respeta lo reservado" do
      item.update!(quantity_reserved: 8)   # disponible = 2
      expect(described_class.atomically_decrement(item.id, 5)).to be(false)
    end
  end
end
