# frozen_string_literal: true

module Stock
  module Transfers
    # ==========================================================================
    # Dispatch — despacha una transferencia: origen -> depósito EN TRÁNSITO.
    #
    # PREVENCIÓN DE DEADLOCKS (tema estrella de entrevista):
    #
    # Una transferencia toca N productos. Si la transacción A bloquea los items
    # en el orden [7, 3] y la B en el orden [3, 7], pasa esto:
    #     A tiene 7, quiere 3
    #     B tiene 3, quiere 7
    # Se esperan mutuamente para siempre. Postgres detecta el ciclo (deadlock_timeout,
    # 1s por defecto), mata una transacción con "deadlock detected" y el usuario
    # ve un 500 intermitente e "imposible de reproducir".
    #
    # LA SOLUCIÓN es trivial y hay que saberla: adquirir SIEMPRE los locks en un
    # orden total y determinístico. Acá, `ORDER BY id`. Si todas las
    # transacciones piden en el mismo orden, no puede haber ciclo. Ese es el
    # `.order(:id).lock` de abajo, y es el motivo de que exista.
    # ==========================================================================
    class Dispatch < ApplicationService
      def initialize(transfer:, user:, event_recorder: Outbox::Recorder.new, clock: Time)
        @transfer_id = transfer.is_a?(StockTransfer) ? transfer.id : transfer
        @user = user
        @event_recorder = event_recorder
        @clock = clock
      end

      def call
        transactional do
          transfer = StockTransfer.lock.includes(lines: :product).find(@transfer_id)

          unless transfer.can_transition_to?("in_transit")
            fail!(:invalid_transition,
                  "Una transferencia en estado '#{transfer.status}' no se puede despachar")
          end

          fail!(:no_lines, "La transferencia no tiene líneas") if transfer.lines.empty?

          transit = transit_warehouse_for(transfer)

          # Un solo SELECT ... FOR UPDATE ORDER BY id para TODOS los items del
          # origen. Una query, orden determinístico, sin deadlocks.
          source_items = lock_items_in_order(transfer.lines.map(&:product_id), transfer.source_warehouse_id)

          transfer.lines.each do |line|
            item = source_items[line.product_id]
            if item.nil?
              fail!(:stock_item_not_found,
                    "No hay stock de #{line.product.sku} en #{transfer.source_warehouse.code}")
            end

            move_out = ApplyMovement.call(
              stock_item: item, kind: "transfer_out", quantity: -line.quantity_requested,
              user: @user, reference: transfer, reason: "Despacho #{transfer.reference}",
              event_recorder: @event_recorder, clock: @clock
            )
            fail!(move_out.error.code, move_out.error.message, **move_out.error.details) if move_out.failure?

            transit_item = StockItem.find_or_provision!(product: line.product, warehouse: transit)
            move_in = ApplyMovement.call(
              stock_item: transit_item, kind: "transfer_in", quantity: line.quantity_requested,
              user: @user, reference: transfer, reason: "En tránsito #{transfer.reference}",
              event_recorder: @event_recorder, clock: @clock
            )
            fail!(move_in.error.code, move_in.error.message, **move_in.error.details) if move_in.failure?

            line.update!(quantity_dispatched: line.quantity_requested)
          end

          transfer.update!(status: "in_transit", dispatched_at: @clock.current, transit_warehouse: transit)

          @event_recorder.record(
            aggregate: transfer, event_type: "transfer.dispatched", occurred_at: @clock.current,
            payload: {
              transfer_id: transfer.id, reference: transfer.reference,
              source_warehouse_id: transfer.source_warehouse_id,
              destination_warehouse_id: transfer.destination_warehouse_id,
              units: transfer.lines.sum(&:quantity_dispatched)
            }
          )

          success(transfer)
        end
      end

      private

      def transit_warehouse_for(transfer)
        transfer.transit_warehouse || Warehouse.find_by(code: Warehouse::TRANSIT_CODE) ||
          fail!(:transit_warehouse_missing,
                "Falta el depósito virtual '#{Warehouse::TRANSIT_CODE}'. Corré bin/rails db:seed.")
      end

      # `.order(:id).lock` -> SELECT ... FOR UPDATE ORDER BY id.
      # `index_by` arma un Hash product_id => StockItem para no hacer N búsquedas.
      def lock_items_in_order(product_ids, warehouse_id)
        StockItem.where(product_id: product_ids, warehouse_id:)
                 .order(:id).lock.includes(:product).index_by(&:product_id)
      end
    end
  end
end
