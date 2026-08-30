# frozen_string_literal: true

module StockItems
  # ============================================================================
  # Valuación de inventario: cuánta plata hay parada en el depósito.
  #
  # Hacemos el producto (cantidad x costo) EN LA BASE, no en Ruby. Traer 500.000
  # filas para multiplicar en Ruby es:
  #   * ~500 MB de objetos ActiveRecord,
  #   * segundos de GC,
  #   * y todo para devolver UN número.
  #
  # `SUM(stock_items.quantity_on_hand * products.cost_cents)` lo resuelve
  # Postgres en el mismo scan, sin materializar nada.
  #
  # OJO CON EL OVERFLOW: quantity (int4) * cost_cents (int8) puede pasarse de
  # int8 en un inventario grande. Casteamos a NUMERIC, que en Postgres es de
  # precisión arbitraria. En Java sería el mismo razonamiento: long vs BigDecimal.
  # ============================================================================
  class Valuation < ApplicationQuery
    def initialize(warehouse_id: nil, category_id: nil)
      @warehouse_id = warehouse_id
      @category_id = category_id
    end

    # => { total: Money, by_warehouse: { code => Money } }
    def call
      relation = StockItem.joins(:product).where(products: { discarded_at: nil })
      relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id
      relation = relation.where(products: { category_id: @category_id }) if @category_id

      rows = relation
             .joins(:warehouse)
             .group("warehouses.code", "products.currency")
             .pluck(
               Arel.sql("warehouses.code"),
               Arel.sql("products.currency"),
               Arel.sql("SUM(stock_items.quantity_on_hand::numeric * products.cost_cents)"),
               Arel.sql("SUM(stock_items.quantity_on_hand)")
             )

      by_warehouse = rows.to_h do |code, currency, cents, units|
        [ code, { value: ValueObjects::Money.new(cents: cents.to_i, currency:), units: units.to_i } ]
      end

      totals = rows.group_by { |(_code, currency, _cents, _units)| currency }
                   .transform_values { |group|
                     ValueObjects::Money.new(cents: group.sum { |r| r[2].to_i }, currency: group.first[1])
                   }

      { by_warehouse:, totals:, total_units: rows.sum { |r| r[3].to_i } }
    end
  end
end
