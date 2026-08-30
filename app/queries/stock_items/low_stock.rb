# frozen_string_literal: true

module StockItems
  # ============================================================================
  # Items por debajo del punto de reorden.
  #
  # Usa el índice PARCIAL `index_stock_items_needing_reorder`, que sólo contiene
  # las filas que cumplen `quantity_available <= reorder_point`. Para que
  # Postgres pueda usarlo, el WHERE de la query tiene que IMPLICAR el predicado
  # del índice: por eso el `where("quantity_available <= reorder_point")` está
  # escrito EXACTAMENTE igual que en la migración.
  #
  # Verificalo con:  StockItems::LowStock.call.explain(analyze: true)
  # Deberías ver "Index Scan using index_stock_items_needing_reorder".
  # ============================================================================
  class LowStock < ApplicationQuery
    def initialize(warehouse_id: nil, only_active_products: true, include_zero_reorder: false)
      @warehouse_id = warehouse_id
      @only_active_products = only_active_products
      @include_zero_reorder = include_zero_reorder
    end

    def call
      relation = StockItem.where("quantity_available <= reorder_point")
      relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id
      relation = relation.where.not(reorder_point: 0) unless @include_zero_reorder

      if @only_active_products
        # Subquery en vez de join: no duplica filas y deja el plan más simple.
        relation = relation.where(product_id: Product.kept.active.select(:id))
      end

      relation
        .includes(:product, :warehouse)
        .order(Arel.sql("(quantity_available - reorder_point) ASC"), :id)
    end
  end
end
