# frozen_string_literal: true

class StockMovementSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      kind: object.kind,
      quantity: object.quantity,
      quantity_after: object.quantity_after,
      product: { id: object.product_id, sku: object.product.sku, name: object.product.name },
      warehouse: { id: object.warehouse_id, code: object.warehouse.code },
      user: object.user && { id: object.user.id, name: object.user.to_s },
      reference: object.reference_type && { type: object.reference_type, id: object.reference_id },
      unit_cost: object.total_cost&.as_json,
      reason: object.reason,
      metadata: object.metadata.presence,
      occurred_at: iso(object.occurred_at)
    }.compact
  end
end
