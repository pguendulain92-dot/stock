# frozen_string_literal: true

module Stock
  # ============================================================================
  # ExpireReservations — barre las reservas vencidas. Lo corre un recurring job.
  #
  # PATRÓN IMPORTANTE: procesamos en LOTES y con una transacción POR RESERVA,
  # no una transacción gigante para las 50.000.
  #
  # ¿Por qué? Una transacción larga en Postgres:
  #   * mantiene locks tomados todo ese tiempo (bloquea a los usuarios reales);
  #   * frena el VACUUM: mientras esté abierta, Postgres no puede limpiar
  #     tuplas muertas más nuevas que ella => la tabla se hincha (bloat);
  #   * si falla al final, perdés TODO el trabajo hecho.
  #
  # Con una transacción por ítem, un fallo aislado no arrastra al resto y los
  # locks duran milisegundos. El `find_each` de abajo además pagina con
  # `WHERE id > ?` en vez de traer todo a memoria.
  # ============================================================================
  class ExpireReservations < ApplicationService
    def initialize(batch_size: 500, limit: nil, clock: Time,
                   event_recorder: Outbox::Recorder.new)
      @batch_size = batch_size
      @limit = limit
      @clock = clock
      @event_recorder = event_recorder
    end

    def call
      expired = 0
      failed = []

      scope = StockReservation.expired_now.order(:id)
      scope = scope.limit(@limit) if @limit

      # `in_batches` + `each_record` para no cargar 50k objetos de una.
      scope.in_batches(of: @batch_size) do |batch|
        batch.each do |reservation|
          result = ReleaseReservation.call(
            reservation:, expired: true, reason: "Vencimiento automático",
            event_recorder: @event_recorder, clock: @clock
          )
          result.ok? ? expired += 1 : failed << { id: reservation.id, error: result.error.to_h }
        end
      end

      Result.success(expired:, failed:)
    end
  end
end
