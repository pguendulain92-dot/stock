# frozen_string_literal: true

class StockTransferSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      reference: object.reference,
      status: object.status,
      source_warehouse: { id: object.source_warehouse_id, code: object.source_warehouse.code },
      destination_warehouse: { id: object.destination_warehouse_id,
                               code: object.destination_warehouse.code },
      requested_by: { id: object.requested_by_id, name: object.requested_by.to_s },
      lines: object.lines.map { |line|
        {
          id: line.id,
          product: { id: line.product_id, sku: line.product.sku, name: line.product.name },
          quantity_requested: line.quantity_requested,
          quantity_dispatched: line.quantity_dispatched,
          quantity_received: line.quantity_received
        }
      },
      shrinkage: object.shrinkage,
      dispatched_at: iso(object.dispatched_at),
      received_at: iso(object.received_at),
      created_at: iso(object.created_at)
    }
  end
end
