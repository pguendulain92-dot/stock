# frozen_string_literal: true

module StockItems
  # ============================================================================
  # Disponibilidad agregada por producto (sumando todos los depósitos).
  #
  # ESTE ES EL EJEMPLO CANÓNICO DE "CÓMO ARREGLAR UN N+1 DE AGREGACIÓN".
  #
  # La versión ingenua, la que sale sola:
  #
  #     products.map { |p| [p.id, p.stock_items.sum(:quantity_available)] }
  #
  # Para 200 productos son 201 queries (1 + N). Con 30 ms de red cada una:
  # 6 segundos. Y `includes` NO lo arregla: `includes` evita el N+1 de CARGA
  # de asociaciones, pero `sum` sobre la asociación cargada... en realidad
  # dispara otra query igual salvo que uses `.to_a.sum(&:quantity_available)`,
  # que trae TODAS las filas a memoria.
  #
  # La versión correcta: UNA query con GROUP BY, y que sume la base.
  # `pluck` + `to_h` devuelve un Hash liviano en vez de instanciar modelos:
  # para 50.000 filas la diferencia es de cientos de MB de RAM.
  # ============================================================================
  class Availability < ApplicationQuery
    def initialize(product_ids: nil, warehouse_id: nil)
      @product_ids = product_ids
      @warehouse_id = warehouse_id
    end

    # => { product_id => { on_hand:, reserved:, available: } }
    def call
      relation = StockItem.all
      relation = relation.where(product_id: @product_ids) if @product_ids
      relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id

      relation
        .group(:product_id)
        .pluck(
          :product_id,
          Arel.sql("SUM(quantity_on_hand)"),
          Arel.sql("SUM(quantity_reserved)"),
          Arel.sql("SUM(quantity_available)")
        )
        .to_h { |id, on_hand, reserved, available|
          [ id, { on_hand: on_hand.to_i, reserved: reserved.to_i, available: available.to_i } ]
        }
    end
  end
end
