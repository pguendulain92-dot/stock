# frozen_string_literal: true

module Outbox
  # ============================================================================
  # PublishPendingJob — el "relay" del patrón outbox.
  #
  # Lee los eventos no publicados y los manda al broker/webhook. Corre cada
  # minuto (ver config/recurring.yml) y también se dispara después de escribir.
  #
  # PROPIEDADES QUE HAY QUE PODER EXPLICAR:
  #
  # 1) AT-LEAST-ONCE. Si el proceso muere DESPUÉS de publicar y ANTES de marcar
  #    published_at, el evento sale dos veces. Es inevitable sin transacciones
  #    distribuidas. Por eso cada evento lleva `event_id` (UUID) y el consumidor
  #    DEBE deduplicar. "Exactly-once delivery" no existe; lo que existe es
  #    "at-least-once delivery + idempotent processing", que es lo que la gente
  #    quiere decir cuando dice exactly-once.
  #
  # 2) ORDEN. Procesamos `ORDER BY id` para respetar el orden de escritura.
  #    PERO con varios workers y SKIP LOCKED, el orden GLOBAL no está garantizado:
  #    el worker A puede terminar el evento 5 después que el worker B el 6.
  #    Si necesitás orden por agregado (y en stock lo necesitás), tenés que
  #    particionar por aggregate_id — mismo agregado, mismo worker. Es
  #    exactamente el rol de la partition key en Kafka.
  #
  # 3) BACKPRESSURE. El LIMIT del lote evita que un pico de 2M de eventos
  #    intente procesarse en una sola pasada y reviente la memoria.
  # ============================================================================
  class PublishPendingJob < ApplicationJob
    queue_as :outbox

    BATCH_SIZE = 200

    def perform(batch_size: BATCH_SIZE)
      published = 0
      failed = 0

      # Una transacción POR LOTE: los locks de SKIP LOCKED viven mientras dure
      # la transacción, así que el lote tiene que ser chico y rápido.
      OutboxEvent.transaction do
        events = OutboxEvent.claim_batch(limit: batch_size).to_a
        next if events.empty?

        events.each do |event|
          publisher.publish(event.to_message)
          event.mark_published!
          published += 1
        rescue StandardError => e
          # Un evento roto NO puede frenar a los demás: lo marcamos y seguimos.
          # Sin este rescue, un payload malformado tapa la cola para siempre —
          # el clásico "poison message".
          event.mark_failed!(e)
          failed += 1
          Rails.logger.error(event: "outbox.publish_failed", outbox_id: event.id,
                             event_type: event.event_type, error: e.message)
        end
      end

      Rails.logger.info(event: "outbox.batch", published:, failed:)

      # Si llenamos el lote es porque probablemente hay más: nos re-encolamos
      # en vez de esperar al próximo tick del scheduler. Así la cola se drena
      # rápido después de un pico.
      self.class.perform_later(batch_size:) if published + failed >= batch_size

      { published:, failed: }
    end

    private

    # DIP otra vez: el job no sabe si publica a Kafka, a RabbitMQ, a un webhook
    # o al log. Depende de una interfaz (`publish(message)`), y el adapter
    # concreto se elige por configuración.
    def publisher = Outbox::Publisher.build
  end
end
