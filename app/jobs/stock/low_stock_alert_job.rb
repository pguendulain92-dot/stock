# frozen_string_literal: true

module Stock
  # Detecta items bajo el punto de reorden y emite un evento por cada uno.
  #
  # DEDUPLICACIÓN: sin ella, este job alerta del MISMO producto cada hora hasta
  # que alguien reponga. Los operadores aprenden a ignorar las alertas y el
  # sistema deja de servir ("alert fatigue"). Usamos el cache con TTL como
  # ventana de silencio por producto.
  class LowStockAlertJob < ApplicationJob
    queue_as :maintenance

    SILENCE_WINDOW = 12.hours

    def perform(warehouse_id: nil)
      alerted = 0

      StockItems::LowStock.call(warehouse_id:).find_each do |item|
        key = "low_stock_alert/#{item.id}"
        # `write(..., unless_exist: true)` es un SETNX: devuelve false si la
        # clave ya existía. Es un lock/deduplicador atómico de una línea.
        next unless Rails.cache.write(key, Time.current.to_i,
                                      expires_in: SILENCE_WINDOW, unless_exist: true)

        Outbox::Recorder.new.record(
          aggregate: item, event_type: "stock.low_stock_detected",
          payload: {
            stock_item_id: item.id, product_id: item.product_id,
            product_sku: item.product.sku, warehouse_code: item.warehouse.code,
            quantity_available: item.quantity_available,
            reorder_point: item.reorder_point,
            suggested_order_quantity: suggested_quantity(item)
          }
        )
        alerted += 1
      end

      Rails.logger.info(event: "stock.low_stock_scan", alerted:)
      { alerted: }
    end

    private

    # Cantidad sugerida de reposición. Si hay `maximum_level`, reponemos hasta
    # ahí; si no, usamos el `reorder_quantity` configurado.
    def suggested_quantity(item)
      return item.reorder_quantity if item.maximum_level.blank?

      [ item.maximum_level - item.quantity_available, item.reorder_quantity ].max
    end
  end
end
