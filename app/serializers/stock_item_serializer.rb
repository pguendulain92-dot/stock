# frozen_string_literal: true

class StockItemSerializer < ApplicationSerializer
  def as_json
    {
      id: object.id,
      product: { id: object.product_id, sku: object.product.sku, name: object.product.name,
                 unit: object.product.unit },
      warehouse: { id: object.warehouse_id, code: object.warehouse.code, name: object.warehouse.name },
      quantity_on_hand: object.quantity_on_hand,
      quantity_reserved: object.quantity_reserved,
      quantity_available: object.quantity_available,
      reorder_point: object.reorder_point,
      reorder_quantity: object.reorder_quantity,
      below_reorder_point: object.below_reorder_point?,
      bin_location: object.bin_location,
      valuation: object.valuation.as_json,
      last_movement_at: iso(object.last_movement_at),
      last_counted_at: iso(object.last_counted_at),
      # `lock_version` SE DEVUELVE A PROPÓSITO: el cliente lo manda de vuelta en
      # el PATCH y así habilitamos optimistic locking end-to-end sobre HTTP.
      # Es el equivalente al ETag / If-Match de REST.
      lock_version: object.lock_version
    }
  end
end
