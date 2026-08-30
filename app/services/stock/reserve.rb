# frozen_string_literal: true

module Stock
  # ============================================================================
  # Reserve — "aparta" stock sin moverlo físicamente.
  #
  # No genera un movimiento en el ledger: la mercadería no se movió, sólo quedó
  # comprometida. Lo que cambia es `quantity_reserved`, y por lo tanto
  # `quantity_available` (que es la columna generada on_hand - reserved).
  #
  # Toda reserva NACE CON VENCIMIENTO. Sin TTL, un carrito abandonado te
  # inmoviliza stock para siempre y en 3 meses el sistema dice que no tenés
  # nada mientras el depósito está lleno. Es un bug clásico de e-commerce y la
  # razón por la que existe Stock::ExpireReservations.
  # ============================================================================
  class Reserve < ApplicationService
    def initialize(product:, warehouse:, quantity:, user: nil, reference: nil,
                   ttl: StockReservation::DEFAULT_TTL, reason: nil, idempotency_key: nil,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @product = product
      @warehouse = warehouse
      @quantity = Integer(quantity)
      @user = user
      @reference = reference
      @ttl = ttl
      @reason = reason
      @idempotency_key = idempotency_key.presence
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      return Result.failure(:invalid_quantity, "La cantidad debe ser positiva") unless @quantity.positive?

      transactional do
        if @idempotency_key && (existing = StockReservation.find_by(idempotency_key: @idempotency_key))
          next success(existing)
        end

        resolved = ItemResolver.call(product: @product, warehouse: @warehouse, create_if_missing: false)
        fail!(resolved.error.code, resolved.error.message, **resolved.error.details) if resolved.failure?

        item = StockItem.lock.find(resolved.value.id)

        if item.quantity_available < @quantity
          fail!(:insufficient_available_stock,
                "Disponible insuficiente: hay #{item.quantity_available}, se pidieron #{@quantity}",
                available: item.quantity_available, requested: @quantity)
        end

        reservation = StockReservation.create!(
          stock_item: item,
          user: @user,
          quantity: @quantity,
          status: "held",
          reference: @reference,
          idempotency_key: @idempotency_key,
          reason: @reason,
          expires_at: @clock.current + @ttl
        )

        item.update!(quantity_reserved: item.quantity_reserved + @quantity)

        @event_recorder.record(
          aggregate: item, event_type: "stock.reserved", occurred_at: @clock.current,
          payload: {
            reservation_id: reservation.id, stock_item_id: item.id,
            product_id: item.product_id, product_sku: item.product.sku,
            warehouse_id: item.warehouse_id, quantity: @quantity,
            expires_at: reservation.expires_at.iso8601,
            quantity_available: item.reload.quantity_available
          }
        )

        success(reservation)
      end
    end
  end
end
