# frozen_string_literal: true

class StockItemsController < ApplicationController
  before_action :set_stock_item, only: %i[show receive issue adjust]

  def index
    scope = policy_scope(StockItem).with_associations
    scope = scope.where(warehouse_id: params[:warehouse_id]) if params[:warehouse_id].present?
    scope = scope.where("quantity_available <= reorder_point") if params[:low_stock].present?
    @pagy, @stock_items = pagy(scope.order(:warehouse_id, :product_id), limit: 30)
  end

  def low_stock
    # Esta acción es un `index` con otro nombre: el filtrado lo hace el query
    # object, no un scope de Pundit. Declaramos las DOS exenciones porque la red
    # de seguridad sólo exige `policy_scope` cuando la acción se llama "index";
    # para cualquier otro nombre exige `authorize`.
    skip_policy_scope
    skip_authorization
    @pagy, @stock_items = pagy(StockItems::LowStock.call(warehouse_id: params[:warehouse_id]), limit: 30)
    render :index
  end

  def show
    authorize @stock_item
    @movements = StockMovements::Ledger.call(stock_item_id: @stock_item.id, limit: 30).to_a
    @reservations = @stock_item.stock_reservations.active.order(:expires_at)
  end

  def receive
    authorize @stock_item, :receive?
    handle Stock::Receive.call(
      product: @stock_item.product, warehouse: @stock_item.warehouse,
      quantity: params[:quantity].to_i, user: current_user, reason: params[:reason]
    ), "Ingreso registrado."
  end

  def issue
    authorize @stock_item, :issue?
    handle Stock::Issue.call(
      product: @stock_item.product, warehouse: @stock_item.warehouse,
      quantity: params[:quantity].to_i, user: current_user, reason: params[:reason]
    ), "Egreso registrado."
  end

  def adjust
    authorize @stock_item, :adjust?
    handle Stock::Adjust.call(
      product: @stock_item.product, warehouse: @stock_item.warehouse,
      counted_quantity: params[:counted_quantity].to_i,
      user: current_user, reason: params[:reason]
    ), "Ajuste registrado."
  end

  private

  def set_stock_item = @stock_item = StockItem.with_associations.find(params[:id])

  # El controller traduce Result -> redirect + flash. Nada más.
  def handle(result, success_message)
    if result.ok?
      redirect_to stock_item_path(@stock_item), notice: success_message
    else
      redirect_to stock_item_path(@stock_item), alert: result.error.message
    end
  end
end
