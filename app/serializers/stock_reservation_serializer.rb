# frozen_string_literal: true

class StockReservationSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      status: object.status,
      quantity: object.quantity,
      stock_item_id: object.stock_item_id,
      product: { id: object.stock_item.product_id, sku: object.stock_item.product.sku },
      warehouse: { id: object.stock_item.warehouse_id, code: object.stock_item.warehouse.code },
      reference: object.reference_type && { type: object.reference_type, id: object.reference_id },
      expires_at: iso(object.expires_at),
      committed_at: iso(object.committed_at),
      released_at: iso(object.released_at),
      created_at: iso(object.created_at)
    }.compact
  end
end
