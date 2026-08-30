# frozen_string_literal: true

# ==============================================================================
# Índice para el ledger SIN FILTROS.
#
# El hallazgo: el comentario de app/queries/stock_movements/ledger.rb hablaba
# de "el índice compuesto (occurred_at DESC, id DESC)" como si existiera, pero
# los tres índices de stock_movements empiezan por otra columna
# (stock_item_id, product_id, warehouse_id). Un B-tree sólo sirve si la query
# usa un PREFIJO IZQUIERDO de sus columnas, así que ninguno servía para el
# ledger global — el que usa el panel y `GET /api/v1/stock_movements` sin
# filtros. Resultado: Seq Scan + Sort sobre toda la tabla de movimientos, que
# es la que más crece del sistema.
#
# El orden DESC del índice importa: hace que Postgres pueda leerlo de una
# pasada y saltarse el paso de Sort. Y el `id` desempata, que es lo que
# permite la comparación de tuplas de la paginación por keyset:
#     WHERE (occurred_at, id) < (?, ?)
#
# ⚠️ EN PRODUCCIÓN ESTE add_index VA CON `algorithm: :concurrently`.
# Un CREATE INDEX normal toma un lock que bloquea las ESCRITURAS de la tabla
# durante toda la construcción; sobre millones de filas son minutos de app
# caída. CONCURRENTLY no bloquea, pero NO puede correr dentro de una
# transacción — de ahí el `disable_ddl_transaction!`.
#
# ⚠️ Y OJO AL VERIFICARLO EN DESARROLLO: con pocas filas (acá 109) el planner
# elige igual Seq Scan + Sort, porque leer la tabla entera es más barato que
# saltar por el índice. NO es que el índice esté mal: el planner tiene razón.
# Para comprobar que el índice SIRVE, forzalo:
#     SET enable_seqscan = off;
#     EXPLAIN SELECT * FROM stock_movements ORDER BY occurred_at DESC, id DESC LIMIT 50;
# y deberías ver "Index Scan using index_stock_movements_global_ledger".
# Medir performance sobre una base de juguete es la forma más común de sacar
# conclusiones equivocadas.
#
# El precio de CONCURRENTLY: tarda el doble y, si falla a mitad de camino, deja
# un índice INVÁLIDO que hay que borrar a mano
# (`DROP INDEX CONCURRENTLY ...`) antes de reintentar. Verificalo con:
#     SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
# ==============================================================================
class AddLedgerGlobalIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :stock_movements,
              [ :occurred_at, :id ],
              order: { occurred_at: :desc, id: :desc },
              algorithm: :concurrently,
              if_not_exists: true,
              name: "index_stock_movements_global_ledger"
  end
end
