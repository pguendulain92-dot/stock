# frozen_string_literal: true

module Stock
  # ============================================================================
  # CommitReservation — la mercadería reservada efectivamente sale del depósito.
  #
  # Acá SÍ hay movimiento físico, y es el único caso donde bajan las DOS
  # cantidades a la vez:
  #   quantity_on_hand  -= q     (salió de la estantería)
  #   quantity_reserved -= q     (ya no está "comprometida", está entregada)
  #
  # Como bajan las dos por igual, `quantity_available` NO cambia: siempre
  # estuvo descontada desde que se hizo la reserva. Eso es exactamente lo que
  # querés — y es la razón por la que ApplyMovement acepta `reserved_delta`.
  #
  # Si en vez de esto hicieras "release + issue" en dos pasos, entre uno y otro
  # el stock quedaría DISPONIBLE por un instante y otro proceso podría
  # llevárselo. Tiene que ser atómico.
  # ============================================================================
  class CommitReservation < ApplicationService
    def initialize(reservation:, user: nil, reference: nil, idempotency_key: nil,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @reservation_id = reservation.is_a?(StockReservation) ? reservation.id : reservation
      @user = user
      @reference = reference
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      transactional do
        reservation = StockReservation.lock.find(@reservation_id)

        next success(reservation) if reservation.committed?

        if reservation.terminal?
          fail!(:reservation_not_active,
                "La reserva está en estado '#{reservation.status}' y no se puede confirmar")
        end

        if reservation.expires_at <= @clock.current
          fail!(:reservation_expired,
                "La reserva venció el #{reservation.expires_at.iso8601}")
        end

        item = StockItem.lock.find(reservation.stock_item_id)

        movement = ApplyMovement.call(
          stock_item: item,
          kind: "issue",
          quantity: -reservation.quantity,
          reserved_delta: -reservation.quantity,   # <- las dos, atómicamente
          user: @user,
          reference: @reference || reservation.reference,
          reason: "Confirmación de reserva ##{reservation.id}",
          idempotency_key: @idempotency_key,
          event_recorder: @event_recorder,
          clock: @clock
        )
        fail!(movement.error.code, movement.error.message, **movement.error.details) if movement.failure?

        reservation.update!(status: "committed", committed_at: @clock.current)

        success(reservation)
      end
    end
  end
end
