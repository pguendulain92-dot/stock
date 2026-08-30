# frozen_string_literal: true

module Purchasing
  # Recepción (total o parcial) de una orden de compra.
  # El costo unitario de la orden se propaga al movimiento del ledger: es lo
  # que después permite valuar el inventario por costo real de compra (FIFO/PMP).
  class ReceiveOrder < ApplicationService
    def initialize(purchase_order:, user:, received_quantities: nil,
                   idempotency_key: nil, event_recorder: Outbox::Recorder.new, clock: Time)
      @order_id = purchase_order.is_a?(PurchaseOrder) ? purchase_order.id : purchase_order
      @user = user
      @received_quantities = received_quantities
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      transactional do
        order = PurchaseOrder.lock.includes(lines: :product).find(@order_id)

        unless order.can_transition_to?("received") || order.can_transition_to?("partially_received")
          fail!(:invalid_transition,
                "Una orden en estado '#{order.status}' no admite recepción")
        end

        total_received = 0

        order.lines.order(:id).each do |line|
          # SEMÁNTICA DE LA RECEPCIÓN PARCIAL:
          #   received_quantities == nil  -> se recibe TODO lo pendiente.
          #   received_quantities == hash -> se recibe SÓLO lo que está listado;
          #                                  lo que no figura queda PENDIENTE.
          #
          # La alternativa (completar lo no listado con lo pendiente) es
          # peligrosa: el operador informa lo que llegó de un producto y el
          # sistema le da por recibido lo de los demás, creando stock que no
          # existe. Ante la duda, NUNCA inventes mercadería.
          qty = @received_quantities.nil? ? line.pending : @received_quantities.fetch(line.product_id, 0).to_i
          next if qty.zero?

          if qty.negative? || qty > line.pending
            fail!(:invalid_quantity,
                  "Recepción inválida para #{line.product.sku}: #{qty} (pendiente: #{line.pending})")
          end

          item = StockItem.find_or_provision!(product: line.product, warehouse: order.warehouse)

          moved = Stock::ApplyMovement.call(
            stock_item: item, kind: "receipt", quantity: qty,
            user: @user, reference: order,
            unit_cost_cents: line.unit_cost_cents,
            reason: "Recepción OC #{order.reference}",
            idempotency_key: @idempotency_key && "#{@idempotency_key}:#{line.id}",
            event_recorder: @event_recorder, clock: @clock
          )
          fail!(moved.error.code, moved.error.message, **moved.error.details) if moved.failure?

          line.update!(quantity_received: line.quantity_received + qty)
          total_received += qty
        end

        fail!(:nothing_to_receive, "No había nada pendiente de recibir") if total_received.zero?

        order.reload
        order.update!(
          status: order.fully_received? ? "received" : "partially_received",
          received_at: order.fully_received? ? @clock.current : nil
        )

        @event_recorder.record(
          aggregate: order, event_type: "purchase_order.received", occurred_at: @clock.current,
          payload: {
            purchase_order_id: order.id, reference: order.reference,
            supplier_id: order.supplier_id, warehouse_id: order.warehouse_id,
            units_received: total_received, status: order.status
          }
        )

        success(order)
      end
    end
  end
end
