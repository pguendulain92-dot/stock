# frozen_string_literal: true

class PurchaseOrderSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      reference: object.reference,
      status: object.status,
      supplier: { id: object.supplier_id, name: object.supplier.name },
      warehouse: { id: object.warehouse_id, code: object.warehouse.code },
      total: object.total.as_json,
      lines_count: object.lines_count,
      lines: object.lines.map { |line|
        {
          id: line.id,
          product: { id: line.product_id, sku: line.product.sku },
          quantity_ordered: line.quantity_ordered,
          quantity_received: line.quantity_received,
          unit_cost: line.unit_cost.as_json,
          subtotal: line.subtotal.as_json
        }
      },
      expected_at: object.expected_at&.iso8601,
      submitted_at: iso(object.submitted_at),
      received_at: iso(object.received_at),
      created_at: iso(object.created_at)
    }
  end
end
