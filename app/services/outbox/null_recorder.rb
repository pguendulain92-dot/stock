# frozen_string_literal: true

module Outbox
  # ============================================================================
  # NullRecorder — implementación NULL OBJECT del contrato `record(...)`.
  #
  # No escribe en la base: acumula los eventos en un array para que los tests
  # puedan inspeccionarlos. Es lo que le inyectamos a los services en los specs.
  #
  # ¿Por qué un Null Object y no un mock (`double`)?
  #   * Es CÓDIGO REAL: si el contrato cambia (agregamos un parámetro a
  #     `record`), este archivo deja de compilar/falla, mientras que un doble
  #     "flexible" seguiría respondiendo cualquier cosa y el test daría verde en
  #     falso. (Con `instance_double` te salvás de eso, pero un Null Object
  #     además es reutilizable y expresa la intención mejor.)
  #   * Sirve también en producción: un modo "sin eventos" para un import masivo.
  #
  # ─── POR QUÉ ESTÁ EN SU PROPIO ARCHIVO ───────────────────────────────────
  # Zeitwerk mapea UN archivo a UNA constante por convención de nombres:
  #   app/services/outbox/null_recorder.rb  ->  Outbox::NullRecorder
  # Si dejás esta clase adentro de recorder.rb, la constante existe SÓLO
  # después de que alguien haya cargado Outbox::Recorder. En desarrollo (donde
  # se autocarga a demanda) referenciar Outbox::NullRecorder primero tira
  # NameError; en producción con eager_load anda. Es el clásico "funciona en
  # producción pero rompe en el test" al revés, y `zeitwerk:check` NO lo
  # detecta porque sólo verifica que cada archivo defina SU constante esperada.
  # ============================================================================
  class NullRecorder
    attr_reader :recorded

    def initialize = @recorded = []

    def record(aggregate:, event_type:, payload: {}, metadata: {}, occurred_at: Time.current)
      @recorded << { aggregate:, event_type:, payload:, metadata:, occurred_at: }
      nil
    end
  end
end
