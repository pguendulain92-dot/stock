# frozen_string_literal: true

module StockItems
  # ============================================================================
  # Reconciliación: la PROYECCIÓN (stock_items.quantity_on_hand) contra la
  # VERDAD (SUM de stock_movements.quantity).
  #
  # Si esto devuelve una sola fila, hay un bug: alguien escribió una cantidad
  # sin pasar por Stock::ApplyMovement. Lo corre un job nocturno que alerta.
  #
  # Detalle técnico: usamos LEFT JOIN desde stock_items (no RIGHT JOIN desde
  # movements). ActiveRecord tiene `left_joins` pero NO tiene `right_joins`:
  # la forma idiomática es dar vuelta la relación y arrancar del lado que querés
  # conservar. Con LEFT JOIN, un stock_item SIN movimientos aparece con
  # SUM = NULL, y el COALESCE lo convierte en 0 — que es justo el caso que más
  # querés detectar (una fila con cantidad y cero movimientos que la respalden).
  # ============================================================================
  class Reconciliation < ApplicationQuery
    def initialize(warehouse_id: nil)
      @warehouse_id = warehouse_id
    end

    # => [{ stock_item_id:, projected:, ledger_total:, drift: }, ...]
    def call
      relation = StockItem.left_joins(:stock_movements)
      relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id

      relation
        .group("stock_items.id", "stock_items.quantity_on_hand")
        .having("stock_items.quantity_on_hand <> COALESCE(SUM(stock_movements.quantity), 0)")
        .pluck(
          Arel.sql("stock_items.id"),
          Arel.sql("stock_items.quantity_on_hand"),
          Arel.sql("COALESCE(SUM(stock_movements.quantity), 0)")
        )
        .map { |id, projected, ledger|
          { stock_item_id: id, projected: projected.to_i, ledger_total: ledger.to_i,
            drift: projected.to_i - ledger.to_i }
        }
    end
  end
end
