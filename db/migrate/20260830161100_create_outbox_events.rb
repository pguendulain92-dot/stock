# frozen_string_literal: true

# ==============================================================================
# TRANSACTIONAL OUTBOX — probablemente el patrón que más te va a servir en la
# entrevista, porque venís de Java y seguro lo conocés de Kafka/Debezium.
#
# EL PROBLEMA (dual write):
#   Querés hacer dos cosas: (a) guardar en la base, (b) publicar un evento.
#   No hay transacción distribuida entre Postgres y el broker. Entonces:
#
#     ActiveRecord::Base.transaction do
#       stock_item.update!(quantity_on_hand: 40)
#       Kafka.publish("stock.changed", ...)   # <-- MAL
#     end
#
#   - Si el publish falla, hiciste rollback de la base pero quizá el broker
#     YA recibió el mensaje (no podés "des-publicar").
#   - Si el commit falla después de publicar, publicaste un hecho que no pasó.
#   - Si el proceso muere entre el commit y el publish, perdiste el evento.
#
# LA SOLUCIÓN (outbox):
#   Escribís el evento en ESTA tabla, en la MISMA transacción que el cambio de
#   negocio. Commit atómico: o pasan las dos cosas o ninguna. Después, un
#   proceso aparte (`Outbox::PublishPendingJob`) lee las filas sin publicar y
#   las manda al broker, marcando published_at.
#
# GARANTÍA: at-least-once. El publisher puede morir después de publicar y antes
# de marcar => el mismo evento sale dos veces. Por eso cada evento lleva un
# `event_id` (UUID) y los consumidores DEBEN ser idempotentes. Exactly-once no
# existe en sistemas distribuidos; lo que existe es at-least-once + idempotencia.
#
# En Rails hay una trampa extra: `after_commit` NO es equivalente al outbox.
# Si el proceso muere entre el COMMIT de Postgres y la ejecución del callback
# en Ruby, el callback nunca corre y perdés el evento sin dejar rastro.
# Ver docs/07 §outbox.
# ==============================================================================
class CreateOutboxEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_events do |t|
      # UUID generado por la base: el identificador que el consumidor usa para
      # deduplicar. gen_random_uuid() viene en Postgres 13+ sin extensiones.
      t.uuid :event_id, null: false, default: -> { "gen_random_uuid()" }

      t.string :aggregate_type, null: false      # "StockItem"
      t.bigint :aggregate_id, null: false
      t.string :event_type, null: false          # "stock.received"
      t.integer :event_version, null: false, default: 1

      t.jsonb :payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}   # trace_id, user_id, etc.

      t.datetime :occurred_at, null: false
      t.datetime :published_at
      t.integer :attempts, null: false, default: 0
      t.text :last_error

      t.datetime :created_at, null: false
    end

    add_index :outbox_events, :event_id, unique: true

    # EL índice del patrón. Parcial sobre "no publicados": la cola de trabajo
    # pendiente es chiquita (decenas de filas) aunque la tabla tenga 500M de
    # eventos históricos. El publisher hace:
    #   SELECT ... WHERE published_at IS NULL ORDER BY id LIMIT 500 FOR UPDATE SKIP LOCKED
    # y ese índice lo resuelve en microsegundos.
    add_index :outbox_events, :id,
              where: "published_at IS NULL",
              name: "index_outbox_events_unpublished"

    # Para reconstruir el stream de un agregado (event sourcing / debugging).
    add_index :outbox_events, [ :aggregate_type, :aggregate_id, :id ]
    add_index :outbox_events, [ :event_type, :occurred_at ]
  end
end
