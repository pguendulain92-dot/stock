# frozen_string_literal: true

module Stock
  module Transfers
    # ==========================================================================
    # Receive — recibe la transferencia: EN TRÁNSITO -> destino.
    #
    # Soporta recepción PARCIAL. Si despacharon 100 y llegaron 97, los 3 que
    # faltan se imputan como `scrap` contra el depósito de tránsito. Sin eso, el
    # tránsito quedaría con 3 unidades fantasma para siempre y el inventario
    # total dejaría de cerrar.
    # ==========================================================================
    class Receive < ApplicationService
      # `received_quantities` es un Hash { product_id => cantidad recibida }.
      # Si viene nil, se asume recepción completa.
      def initialize(transfer:, user:, received_quantities: nil,
                     event_recorder: Outbox::Recorder.new, clock: Time)
        @transfer_id = transfer.is_a?(StockTransfer) ? transfer.id : transfer
        @user = user
        @received_quantities = received_quantities
        @event_recorder = event_recorder
        @clock = clock
      end

      def call
        transactional do
          transfer = StockTransfer.lock.includes(lines: :product).find(@transfer_id)

          unless transfer.can_transition_to?("received")
            fail!(:invalid_transition,
                  "Una transferencia en estado '#{transfer.status}' no se puede recibir")
          end

          transit = transfer.transit_warehouse || Warehouse.find_by!(code: Warehouse::TRANSIT_CODE)
          shrinkage_total = 0

          transfer.lines.order(:id).each do |line|
            received = (@received_quantities || {}).fetch(line.product_id, line.quantity_dispatched).to_i

            if received.negative? || received > line.quantity_dispatched
              fail!(:invalid_quantity,
                    "Recibido inválido para #{line.product.sku}: #{received} " \
                    "(despachado: #{line.quantity_dispatched})")
            end

            transit_item = StockItem.lock.find_by!(product_id: line.product_id, warehouse_id: transit.id)

            if received.positive?
              out = ApplyMovement.call(
                stock_item: transit_item, kind: "transfer_out", quantity: -received,
                user: @user, reference: transfer, reason: "Recepción #{transfer.reference}",
                event_recorder: @event_recorder, clock: @clock
              )
              fail!(out.error.code, out.error.message, **out.error.details) if out.failure?

              dest_item = StockItem.find_or_provision!(product: line.product,
                                                       warehouse: transfer.destination_warehouse)
              into = ApplyMovement.call(
                stock_item: dest_item, kind: "transfer_in", quantity: received,
                user: @user, reference: transfer, reason: "Recepción #{transfer.reference}",
                event_recorder: @event_recorder, clock: @clock
              )
              fail!(into.error.code, into.error.message, **into.error.details) if into.failure?
            end

            missing = line.quantity_dispatched - received
            if missing.positive?
              shrinkage_total += missing
              scrap = ApplyMovement.call(
                stock_item: transit_item, kind: "scrap", quantity: -missing,
                user: @user, reference: transfer,
                reason: "Faltante en tránsito #{transfer.reference}",
                event_recorder: @event_recorder, clock: @clock
              )
              fail!(scrap.error.code, scrap.error.message, **scrap.error.details) if scrap.failure?
            end

            line.update!(quantity_received: received)
          end

          transfer.update!(status: "received", received_at: @clock.current)

          @event_recorder.record(
            aggregate: transfer, event_type: "transfer.received", occurred_at: @clock.current,
            payload: {
              transfer_id: transfer.id, reference: transfer.reference,
              destination_warehouse_id: transfer.destination_warehouse_id,
              units_received: transfer.lines.sum(&:quantity_received),
              shrinkage: shrinkage_total
            }
          )

          success(transfer)
        end
      end
    end
  end
end
