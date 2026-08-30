# frozen_string_literal: true

module Stock
  # Encuentra (o crea) el stock_item de un par producto/depósito.
  # Aislado en su propia clase porque la creación bajo concurrencia tiene una
  # trampa (ver StockItem.find_or_provision!) y porque así los services no
  # repiten esta lógica.
  class ItemResolver < ApplicationService
    def initialize(product:, warehouse:, create_if_missing: true)
      @product = product
      @warehouse = warehouse
      @create_if_missing = create_if_missing
    end

    def call
      item =
        if @create_if_missing
          StockItem.find_or_provision!(product: @product, warehouse: @warehouse)
        else
          StockItem.find_by(product: @product, warehouse: @warehouse)
        end

      return Result.failure(:stock_item_not_found,
                            "No hay stock de #{@product.sku} en #{@warehouse.code}") if item.nil?

      Result.success(item)
    end
  end
end
