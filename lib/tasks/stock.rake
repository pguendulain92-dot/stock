# frozen_string_literal: true

# ==============================================================================
# Tareas de operación y diagnóstico.
#
# UNA RAKE TASK ES UN COMANDO, NO UN LUGAR DONDE PONER LÓGICA. Fijate que todas
# las de acá delegan en services y query objects. ¿Por qué importa?
#   * Una rake task NO se puede testear cómodamente (hay que invocar rake).
#   * No se puede reusar desde un controller ni desde un job.
#   * Los `namespace` no son constantes: no hay autoloading ni Zeitwerk acá.
# Regla: la tarea parsea argumentos, llama a UN objeto y formatea la salida.
#
# `=> :environment` es OBLIGATORIO si la tarea toca modelos: sin eso, Rails no
# carga la app y te encontrás con NameError: uninitialized constant Product.
# Y al revés: si tu tarea NO necesita Rails, no lo pongas — el boot cuesta
# segundos y en un cron que corre cada minuto se nota.
# ==============================================================================

namespace :stock do
  desc "Verifica que el ledger y la proyección coincidan (salida distinta de 0 si hay drift)"
  task reconcile: :environment do
    drifts = StockItems::Reconciliation.call

    if drifts.empty?
      puts "✅ Ledger y proyección coinciden en #{StockItem.count} existencias."
      next
    end

    puts "❌ #{drifts.size} discrepancia(s) detectada(s):"
    drifts.first(50).each do |drift|
      item = StockItem.includes(:product, :warehouse).find(drift[:stock_item_id])
      puts format("  %-16s @ %-10s proyección=%-8d ledger=%-8d drift=%+d",
                  item.product.sku, item.warehouse.code,
                  drift[:projected], drift[:ledger_total], drift[:drift])
    end
    puts "\nCorregir con: bin/rails runner 'Stock::ReconcileBalancesJob.perform_now(autofix: true)'"

    # Salir con código distinto de 0 permite usarlo en un cron con alerta.
    exit 1
  end

  desc "Muestra los items bajo el punto de reorden. Uso: rake stock:low[BA-01]"
  task :low, [ :warehouse_code ] => :environment do |_t, args|
    warehouse_id = args[:warehouse_code] && Warehouse.find_by!(code: args[:warehouse_code].upcase).id
    items = StockItems::LowStock.call(warehouse_id:)

    puts format("%-16s %-10s %8s %8s %8s", "SKU", "DEPÓSITO", "DISP.", "REORDEN", "SUGERIDO")
    puts "-" * 56
    items.find_each do |item|
      puts format("%-16s %-10s %8d %8d %8d",
                  item.product.sku, item.warehouse.code,
                  item.quantity_available, item.reorder_point, item.reorder_quantity)
    end
    puts "\n#{items.count} item(s) necesitan reposición."
  end

  desc "Valuación del inventario. Uso: rake stock:valuation[BA-01]"
  task :valuation, [ :warehouse_code ] => :environment do |_t, args|
    warehouse_id = args[:warehouse_code] && Warehouse.find_by!(code: args[:warehouse_code].upcase).id
    result = StockItems::Valuation.call(warehouse_id:)

    puts "Por depósito:"
    result[:by_warehouse].sort.each do |code, data|
      puts format("  %-12s %14s  (%d unidades)", code, data[:value].to_s, data[:units])
    end
    puts "\nTotales:"
    result[:totals].each { |currency, money| puts format("  %-4s %16s", currency, money.to_s) }
    puts format("\n%d unidades en total.", result[:total_units])
  end

  desc "Estado de la cola del outbox"
  task outbox: :environment do
    pending = OutboxEvent.pending.count
    stuck = OutboxEvent.stuck.count
    oldest = OutboxEvent.pending.minimum(:occurred_at)

    puts "Pendientes:  #{pending}"
    puts "Trabados:    #{stuck} (agotaron #{OutboxEvent::MAX_ATTEMPTS} intentos)"
    puts "Publicados:  #{OutboxEvent.published.count}"
    if oldest
      lag = (Time.current - oldest).round
      puts "Más viejo:   hace #{lag}s#{' ⚠️  LA COLA ESTÁ ATRASADA' if lag > 300}"
    end

    if stuck.positive?
      puts "\nEventos trabados (revisar last_error):"
      OutboxEvent.stuck.limit(10).each do |e|
        puts format("  #%-8d %-32s %s", e.id, e.event_type, e.last_error.to_s.truncate(60))
      end
    end
  end

  desc "Genera un token de API. Uso: rake stock:token[admin@stock.test,mi-integración]"
  task :token, [ :email, :name ] => :environment do |_t, args|
    user = User.find_by!(email_address: args.fetch(:email))
    token = ApiToken.issue!(user:, name: args[:name] || "cli", scopes: ApiToken::SCOPES)

    puts "Token para #{user.email_address} (guardalo, NO se vuelve a mostrar):"
    puts "\n  #{token.plaintext}\n\n"
    puts "Probalo con:"
    puts %(  curl -H "Authorization: Bearer #{token.plaintext}" http://localhost:3000/api/v1/products)
  end
end

namespace :db do
  desc "Muestra los índices que Postgres NUNCA usó (candidatos a borrar)"
  task unused_indexes: :environment do
    # pg_stat_user_indexes acumula desde el último `pg_stat_reset()`. Un idx_scan
    # en 0 significa "nunca se usó DESDE ENTONCES": si reiniciaste las
    # estadísticas ayer, no borres nada todavía. Un índice sin usar no es
    # gratis: ocupa disco, se actualiza en cada INSERT/UPDATE/DELETE y hace más
    # lento el autovacuum.
    rows = ApplicationRecord.connection.select_all(<<~SQL.squish)
      SELECT s.relname AS tabla, s.indexrelname AS indice, s.idx_scan AS usos,
             pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamano
      FROM pg_stat_user_indexes s
      JOIN pg_index i ON i.indexrelid = s.indexrelid
      WHERE NOT i.indisunique AND NOT i.indisprimary
      ORDER BY s.idx_scan ASC, pg_relation_size(s.indexrelid) DESC
    SQL

    puts format("%-24s %-52s %8s %10s", "TABLA", "ÍNDICE", "USOS", "TAMAÑO")
    puts "-" * 98
    rows.each { |r| puts format("%-24s %-52s %8s %10s", r["tabla"], r["indice"], r["usos"], r["tamano"]) }
    puts "\nOjo: las estadísticas son desde el último pg_stat_reset()."
  end

  desc "Tamaño de las tablas y su bloat aproximado"
  task table_sizes: :environment do
    rows = ApplicationRecord.connection.select_all(<<~SQL.squish)
      SELECT relname AS tabla,
             n_live_tup AS filas_vivas,
             n_dead_tup AS filas_muertas,
             pg_size_pretty(pg_total_relation_size(relid)) AS total,
             last_autovacuum
      FROM pg_stat_user_tables
      ORDER BY pg_total_relation_size(relid) DESC
    SQL

    puts format("%-26s %12s %12s %10s  %s", "TABLA", "VIVAS", "MUERTAS", "TOTAL", "ÚLT. AUTOVACUUM")
    puts "-" * 100
    rows.each do |r|
      # Muchas tuplas muertas respecto de las vivas = bloat: el autovacuum no
      # está dando abasto y las queries escanean páginas con basura.
      alerta = r["n_dead_tup"].to_i > [ r["n_live_tup"].to_i * 0.2, 1_000 ].max ? " ⚠️" : ""
      puts format("%-26s %12s %12s %10s  %s%s",
                  r["tabla"], r["filas_vivas"], r["filas_muertas"], r["total"],
                  r["last_autovacuum"] || "nunca", alerta)
    end
  end
end
