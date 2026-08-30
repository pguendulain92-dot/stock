# frozen_string_literal: true

class StockMovementsController < ApplicationController
  def index
    skip_policy_scope
    @movements = StockMovements::Ledger.call(
      product_id: params[:product_id], warehouse_id: params[:warehouse_id],
      kinds: params[:kind].presence&.then { |k| [ k ] },
      cursor: params[:cursor], limit: 50
    ).to_a
    @next_cursor = @movements.size < 50 ? nil : StockMovements::Ledger.encode_cursor(@movements.last)
    @warehouses = Warehouse.order(:code)
  end
end
