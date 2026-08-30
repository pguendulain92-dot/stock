# frozen_string_literal: true

module Stock
  # Libera una reserva: el stock vuelve a estar disponible.
  # Es IDEMPOTENTE por diseño: liberar dos veces devuelve éxito la segunda vez
  # en vez de error. Un cliente que reintenta por timeout no debería recibir un
  # 4xx por algo que ya logró.
  class ReleaseReservation < ApplicationService
    def initialize(reservation:, reason: nil, expired: false,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @reservation_id = reservation.is_a?(StockReservation) ? reservation.id : reservation
      @reason = reason
      @expired = expired
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      transactional do
        reservation = StockReservation.lock.find(@reservation_id)

        # Ya está en un estado terminal: nada que hacer, pero NO es un error.
        next success(reservation) if reservation.terminal?

        # Orden de locks: primero la reserva, después el item. SIEMPRE el mismo
        # orden en todo el código. Si un service bloqueara item->reserva y otro
        # reserva->item, dos transacciones concurrentes podrían quedar
        # esperándose mutuamente: DEADLOCK. Postgres lo detecta y mata a una,
        # pero el usuario ve un 500. La prevención es la disciplina del orden.
        item = StockItem.lock.find(reservation.stock_item_id)

        reservation.update!(
          status: @expired ? "expired" : "released",
          released_at: @clock.current,
          reason: @reason || reservation.reason
        )
        item.update!(quantity_reserved: [ item.quantity_reserved - reservation.quantity, 0 ].max)

        @event_recorder.record(
          aggregate: item,
          event_type: @expired ? "stock.reservation_expired" : "stock.reservation_released",
          occurred_at: @clock.current,
          payload: {
            reservation_id: reservation.id, stock_item_id: item.id,
            product_id: item.product_id, quantity: reservation.quantity,
            quantity_available: item.reload.quantity_available
          }
        )

        success(reservation)
      end
    end
  end
end
