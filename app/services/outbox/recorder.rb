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
      OutboxEvent.create!(
        aggregate_type: aggregate.class.name,
        aggregate_id: aggregate.id,
        event_type:,
        payload: payload.deep_stringify_keys,
        metadata: default_metadata.merge(metadata).deep_stringify_keys,
        occurred_at:
      )
    end

    private

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

  # Doble de test / no-op. Lo inyectamos donde no queremos escribir eventos.
  class NullRecorder
    attr_reader :recorded

    def initialize = @recorded = []

    def record(aggregate:, event_type:, payload: {}, metadata: {}, occurred_at: Time.current)
      @recorded << { aggregate:, event_type:, payload:, metadata:, occurred_at: }
      nil
    end
  end
end
