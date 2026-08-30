# frozen_string_literal: true

# ==============================================================================
# Soporte para los tests de CONCURRENCIA REAL.
#
# EL PROBLEMA: `use_transactional_fixtures = true` envuelve cada ejemplo en una
# transacción sin commitear. Un THREAD nuevo toma OTRA conexión del pool, y esa
# conexión NO VE los datos de una transacción ajena sin commitear. Resultado: el
# thread no encuentra nada y el test es un falso verde.
#
# LA SOLUCIÓN: en estos specs desactivamos las transactional fixtures y limpiamos
# a mano con TRUNCATE. Es más lento, pero es la ÚNICA forma de testear locking de
# verdad. Un test de concurrencia que no usa threads reales y conexiones reales
# no está testeando concurrencia: está testeando que tu código secuencial corre.
#
# Además hay que devolver la conexión al pool en cada thread
# (`ActiveRecord::Base.connection_handler.clear_active_connections!`), o el pool
# se agota y el siguiente test falla por timeout de checkout.
# ==============================================================================
require "concurrent"

module ConcurrencyHelpers
  # Corre `count` bloques en paralelo de verdad y devuelve sus resultados.
  # Cada thread abre su propia conexión.
  def run_concurrently(count)
    barrier = Concurrent::CyclicBarrier.new(count)
    results = Array.new(count)
    errors = Array.new(count)

    threads = Array.new(count) do |i|
      Thread.new do
        # Cada thread necesita su propia conexión del pool.
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait   # arrancan todos lo más cerca posible en el tiempo
          results[i] = yield(i)
        rescue StandardError => e
          errors[i] = e
        end
      end
    end

    threads.each(&:join)
    ActiveRecord::Base.connection_handler.clear_active_connections!
    { results:, errors: errors.compact }
  end
end

RSpec.configure do |config|
  config.include ConcurrencyHelpers, :concurrency

  # Sin transacción envolvente: los threads tienen que ver los datos.
  config.use_transactional_fixtures = false if ENV["FORCE_NO_TRANSACTIONS"]

  config.around(:each, :concurrency) do |example|
    self.use_transactional_tests = false
    example.run
    # Limpieza manual. El orden importa por las FKs; TRUNCATE ... CASCADE lo
    # resuelve de una.
    tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{tables.map { |t| ActiveRecord::Base.connection.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE"
    )
  end
end
