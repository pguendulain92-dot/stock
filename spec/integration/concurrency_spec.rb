# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# TESTS DE CONCURRENCIA REAL.
#
# Estos son los tests que separan un sistema de stock que funciona de uno que
# vende de más un viernes a la noche. Usan THREADS DE VERDAD con CONEXIONES
# DISTINTAS a Postgres: es la única manera de ejercitar los locks.
#
# El tag `:concurrency` desactiva las transactional fixtures (ver
# spec/support/concurrency.rb): si el test corriera dentro de una transacción
# sin commitear, los otros threads no verían los datos y el test sería un
# falso verde.
#
# Son LENTOS comparados con el resto (cientos de ms). Es un precio que vale la
# pena por lo que cubren.
# ==============================================================================
RSpec.describe "Concurrencia sobre el stock", :concurrency do
  let(:user) { create(:user, :operator) }
  let(:product) { create(:product) }
  let(:warehouse) { create(:warehouse) }
  let(:recorder) { Outbox::NullRecorder.new }

  describe "LOST UPDATE: 8 egresos simultáneos sobre 10 unidades" do
    it "NUNCA deja el stock en negativo y sólo prosperan los que caben" do
      item = StockItem.create!(product:, warehouse:, quantity_on_hand: 10)

      # 8 threads intentan sacar 3 unidades cada uno = 24 pedidas sobre 10.
      # Sin lock, varios leerían 10 y todos escribirían: quedaría negativo.
      # Con SELECT ... FOR UPDATE, se serializan y sólo entran 3 (3x3 = 9).
      resultado = run_concurrently(8) do
        Stock::Issue.call(product:, warehouse:, quantity: 3, user:,
                          event_recorder: Outbox::NullRecorder.new)
      end

      exitosos = resultado[:results].compact.count(&:ok?)
      fallidos = resultado[:results].compact.count(&:failure?)

      expect(resultado[:errors]).to be_empty
      expect(exitosos).to eq(3)
      expect(fallidos).to eq(5)

      item.reload
      expect(item.quantity_on_hand).to eq(1)          # 10 - 9
      expect(item.quantity_on_hand).to be >= 0        # LA invariante
    end

    it "el ledger sigue cerrando exactamente después de la tormenta" do
      item = StockItem.create!(product:, warehouse:, quantity_on_hand: 0)
      Stock::Receive.call(product:, warehouse:, quantity: 100, user:, event_recorder: recorder)

      run_concurrently(8) do
        Stock::Issue.call(product:, warehouse:, quantity: 7, user:,
                          event_recorder: Outbox::NullRecorder.new)
      end

      expect(StockItems::Reconciliation.call).to be_empty
      expect(item.reload.quantity_on_hand).to eq(100 - (8 * 7))
    end
  end

  describe "reservas concurrentes" do
    it "no se puede reservar dos veces la misma unidad" do
      StockItem.create!(product:, warehouse:, quantity_on_hand: 10)

      resultado = run_concurrently(6) do
        Stock::Reserve.call(product:, warehouse:, quantity: 4, user:,
                            event_recorder: Outbox::NullRecorder.new)
      end

      exitosos = resultado[:results].compact.count(&:ok?)
      item = StockItem.find_by(product:, warehouse:)

      expect(exitosos).to eq(2)                       # 2 x 4 = 8 <= 10
      expect(item.quantity_reserved).to eq(8)
      expect(item.quantity_available).to eq(2)
      expect(item.quantity_reserved).to be <= item.quantity_on_hand
    end
  end

  describe "creación concurrente del stock_item" do
    it "no crea filas duplicadas para el mismo par producto/depósito" do
      # `find_or_provision!` puede perder la carrera; el índice único la corta y
      # el rescue relee la fila ganadora.
      resultado = run_concurrently(6) do
        StockItem.find_or_provision!(product:, warehouse:)
      end

      expect(resultado[:errors]).to be_empty
      expect(StockItem.where(product:, warehouse:).count).to eq(1)
    end
  end

  describe "idempotencia bajo concurrencia" do
    it "la misma clave desde 5 threads aplica UNA sola vez" do
      StockItem.create!(product:, warehouse:, quantity_on_hand: 0)
      key = SecureRandom.uuid

      resultado = run_concurrently(5) do
        Stock::Receive.call(product:, warehouse:, quantity: 10, user:,
                            idempotency_key: key, event_recorder: Outbox::NullRecorder.new)
      end

      # Alguno puede perder la carrera contra el índice único y recibir un
      # failure de tipo :duplicate; lo importante es que la cantidad final sea
      # la de UNA sola aplicación.
      expect(StockItem.find_by(product:, warehouse:).quantity_on_hand).to eq(10)
      expect(StockMovement.where(idempotency_key: key).count).to eq(1)
      expect(resultado[:errors]).to be_empty
    end
  end

  describe "optimistic locking" do
    it "el segundo escritor recibe StaleObjectError" do
      producto = create(:product, name: "Original")

      resultado = run_concurrently(2) do |i|
        copia = Product.find(producto.id)
        sleep 0.05   # ensanchamos la ventana a propósito para forzar el choque
        begin
          copia.update!(name: "Escritor #{i}")
          :ok
        rescue ActiveRecord::StaleObjectError
          :stale
        end
      end

      expect(resultado[:results]).to include(:ok)
      expect(resultado[:results]).to include(:stale)
    end
  end

  describe "contador correlativo sin huecos" do
    it "10 threads generan 10 referencias distintas y consecutivas" do
      resultado = run_concurrently(10) { SequenceCounter.next_value("CONCURRENT") }

      valores = resultado[:results].compact.sort
      expect(valores).to eq((1..10).to_a)
      expect(valores.uniq.size).to eq(10)
    end
  end

  describe "prevención de deadlocks en transferencias" do
    it "dos transferencias cruzadas con los mismos productos NO se traban" do
      origen = create(:warehouse, code: "A1")
      destino = create(:warehouse, code: "B1")
      create(:warehouse, :transit)
      p1 = create(:product, sku: "X-1")
      p2 = create(:product, sku: "X-2")

      [ p1, p2 ].each do |p|
        Stock::Receive.call(product: p, warehouse: origen, quantity: 100, user:,
                            event_recorder: Outbox::NullRecorder.new)
      end

      # Dos transferencias que tocan los MISMOS dos productos. Si el código
      # bloqueara en el orden en que vienen las líneas (una [p1,p2] y la otra
      # [p2,p1]), habría deadlock. El ORDER BY id lo evita.
      transferencias = [ [ p1, p2 ], [ p2, p1 ] ].map do |productos|
        t = StockTransfer.create!(source_warehouse: origen, destination_warehouse: destino,
                                  requested_by: user)
        productos.each { |p| t.lines.create!(product: p, quantity_requested: 10) }
        t
      end

      resultado = run_concurrently(2) do |i|
        Stock::Transfers::Dispatch.call(transfer: transferencias[i], user:,
                                        event_recorder: Outbox::NullRecorder.new)
      end

      expect(resultado[:errors]).to be_empty
      expect(resultado[:results].compact.count(&:ok?)).to eq(2)
      expect(StockItem.find_by(product: p1, warehouse: origen).quantity_on_hand).to eq(80)
    end
  end
end
