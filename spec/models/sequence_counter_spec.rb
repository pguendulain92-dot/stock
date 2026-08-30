# frozen_string_literal: true

require "rails_helper"

RSpec.describe SequenceCounter do
  describe ".next_value" do
    it "arranca en 1 y no repite" do
      expect(described_class.next_value("TEST")).to eq(1)
      expect(described_class.next_value("TEST")).to eq(2)
      expect(described_class.next_value("TEST")).to eq(3)
    end

    it "los contadores son independientes entre sí" do
      described_class.next_value("A")
      described_class.next_value("A")
      expect(described_class.next_value("B")).to eq(1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # ESTE ES EL TEST DE REGRESIÓN DE UN BUG REAL.
    #
    # El INSERT ... RETURNING se ejecutaba con `select_value`, así que para
    # ActiveRecord era "un SELECT" y el QUERY CACHE lo memorizaba: la segunda
    # llamada con el mismo SQL devolvía el mismo número SIN tocar la base.
    # Dos comprobantes con el mismo número.
    #
    # `cache do ... end` activa el query cache igual que en una request real.
    # Sin el `uncached` del modelo, este test falla.
    # ─────────────────────────────────────────────────────────────────────────
    it "NO se lo come el query cache de ActiveRecord" do
      ApplicationRecord.connection.cache do
        valores = 3.times.map { described_class.next_value("CACHE-TEST") }
        expect(valores).to eq([ 1, 2, 3 ])
      end
    end
  end

  describe ".next_reference" do
    it "arma la referencia con prefijo, año y padding" do
      travel_to Time.zone.local(2026, 5, 1) do
        expect(described_class.next_reference("PO")).to eq("PO-2026-000001")
        expect(described_class.next_reference("PO")).to eq("PO-2026-000002")
      end
    end

    it "el contador se reinicia por año" do
      travel_to(Time.zone.local(2026, 12, 31)) { described_class.next_reference("TR") }
      travel_to(Time.zone.local(2027, 1, 1)) do
        expect(described_class.next_reference("TR")).to eq("TR-2027-000001")
      end
    end
  end

  describe "sin huecos ante un rollback" do
    it "revierte el número si la transacción falla (a diferencia de nextval)" do
      described_class.next_value("ROLLBACK-TEST")   # -> 1

      begin
        ApplicationRecord.transaction do
          described_class.next_value("ROLLBACK-TEST")   # -> 2, pero se revierte
          raise ActiveRecord::Rollback
        end
      end

      # Una SEQUENCE de Postgres habría dejado el hueco y devuelto 3.
      expect(described_class.next_value("ROLLBACK-TEST")).to eq(2)
    end
  end
end
