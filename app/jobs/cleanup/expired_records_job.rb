# frozen_string_literal: true

module Cleanup
  # ============================================================================
  # Limpieza de datos efímeros: claves de idempotencia, sesiones y eventos ya
  # publicados.
  #
  # POR QUÉ IMPORTA: estas tablas crecen sin techo. En Postgres, un DELETE no
  # libera el espacio inmediatamente — deja "tuplas muertas" que el autovacuum
  # tiene que limpiar después. Si dejás crecer una tabla a 200M de filas y
  # después borrás 190M de golpe, el autovacuum no da abasto, la tabla queda
  # hinchada (bloat) y las queries se degradan aunque queden pocas filas vivas.
  #
  # LA FORMA CORRECTA: borrar seguido y en LOTES CHICOS. `in_batches` con
  # `delete_all` hace `DELETE ... WHERE id IN (...)` de a N filas, con una
  # transacción corta por lote. Así el autovacuum va al día.
  #
  # A escala real (cientos de millones de filas), la respuesta buena es
  # PARTICIONAR por fecha y hacer `DROP PARTITION`, que es instantáneo y no
  # genera tuplas muertas. Postgres 12+ lo soporta nativo (declarative
  # partitioning). Mencionarlo suma muchos puntos en una entrevista.
  # ============================================================================
  class ExpiredRecordsJob < ApplicationJob
    queue_as :maintenance

    BATCH = 5_000

    def perform(published_events_older_than: 30.days)
      stats = {
        idempotency_keys: delete_in_batches(IdempotencyKey.where(expires_at: ...Time.current)),
        sessions: delete_in_batches(Session.where(expires_at: ...Time.current)),
        outbox_events: delete_in_batches(
          OutboxEvent.published.where(published_at: ...published_events_older_than.ago)
        )
      }

      Rails.logger.info(event: "cleanup.completed", **stats)
      stats
    end

    private

    def delete_in_batches(relation)
      total = 0
      # `in_batches` pagina por PK (`WHERE id > ?`), no con OFFSET: es O(1) por
      # lote sin importar cuántas filas haya. `delete_all` va directo al SQL,
      # sin instanciar modelos ni correr callbacks — que es lo que querés acá.
      relation.in_batches(of: BATCH) { |batch| total += batch.delete_all }
      total
    end
  end
end
