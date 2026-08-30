# frozen_string_literal: true

module Outbox
  # ============================================================================
  # Recorder — escribe eventos de dominio en la tabla outbox.
  #
  # SIEMPRE se llama DENTRO de la transacción de negocio. Ese es todo el punto
  # del patrón: el evento y el cambio de estado se commitean juntos o no se
  # commitea ninguno de los dos. Ver docs/07 §outbox.
  #
  # Esta clase es también el ejemplo de DIP del proyecto: los services no
  # dependen de "la tabla outbox_events", dependen de un objeto que responde
  # `record(...)`. En los tests le inyectamos un doble que sólo acumula en un
  # array; en producción, este. Sin cambiar una línea del service.
  # ============================================================================
  class Recorder
    def record(aggregate:, event_type:, payload: {}, metadata: {}, occurred_at: Time.current)
      event = OutboxEvent.create!(
        aggregate_type: aggregate.class.name,
        aggregate_id: aggregate.id,
        event_type:,
        payload: payload.deep_stringify_keys,
        metadata: default_metadata.merge(metadata).deep_stringify_keys,
        occurred_at:
      )
      schedule_publish
      event
    end

    private

    # ------------------------------------------------------------------------
    # "Empujoncito" para bajar la latencia. El job recurrente ya publica cada
    # minuto; esto hace que, si acabás de escribir un evento, salga en segundos.
    #
    # `ActiveRecord.after_all_transactions_commit` (Rails 7.2+) ejecuta el
    # bloque cuando commitea la transacción MÁS EXTERNA. Es clave: si usáramos
    # un `after_commit` del modelo dentro de una transacción anidada, se
    # dispararía antes de que la de afuera termine, y encolaríamos un job para
    # datos que todavía pueden hacer rollback.
    #
    # El SETNX del cache DEBOUNCEA: 500 eventos en un lote encolan UN job de
    # publicación, no 500. Sin esto, una importación masiva genera un job por
    # fila y la cola se ahoga sola.
    # ------------------------------------------------------------------------
    def schedule_publish
      ActiveRecord.after_all_transactions_commit do
        next unless Rails.cache.write("outbox/publish_scheduled", 1,
                                      expires_in: 2.seconds, unless_exist: true)

        Outbox::PublishPendingJob.perform_later
      rescue StandardError => e
        # Si el encolado falla, NO nos importa: el job recurrente lo va a
        # levantar igual en el próximo minuto. Justamente por eso el outbox es
        # robusto: el estado durable ya está commiteado en la base.
        Rails.logger.warn(event: "outbox.nudge_failed", error: e.message)
      end
    end

    # Metadata de trazabilidad. `Current` es un CurrentAttributes de Rails:
    # un contenedor por thread/fiber que se limpia solo al terminar el request.
    # Es el equivalente al ThreadLocal / RequestContextHolder de Spring, pero
    # Rails garantiza el reset (el gran problema de ThreadLocal en pools de
    # threads es justamente que alguien se olvide de limpiarlo).
    def default_metadata
      {
        request_id: Current.request_id,
        user_id: Current.user&.id,
        source: "stock-api"
      }.compact
    end
  end
end
