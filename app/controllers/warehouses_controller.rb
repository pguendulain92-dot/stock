# frozen_string_literal: true

class WarehousesController < ApplicationController
  before_action :set_warehouse, only: %i[show edit update]

  def index
    @warehouses = policy_scope(Warehouse).order(:code)
    # UNA query agregada para las estadísticas de TODOS los depósitos,
    # en vez de 3 queries por depósito dentro de la vista.
    @stats = StockItem.group(:warehouse_id).pluck(
      :warehouse_id,
      Arel.sql("COUNT(*)"),
      Arel.sql("SUM(quantity_on_hand)"),
      Arel.sql("COUNT(*) FILTER (WHERE quantity_available <= reorder_point AND reorder_point > 0)")
    ).to_h { |id, skus, units, low| [ id, { skus:, units: units.to_i, low: } ] }
  end

  def show
    authorize @warehouse
    @pagy, @stock_items = pagy(
      @warehouse.stock_items.includes(:product).order("products.sku"), limit: 30
    )
  end

  def new
    @warehouse = Warehouse.new
    authorize @warehouse
  end

  def edit = authorize(@warehouse)

  def create
    @warehouse = Warehouse.new(warehouse_params)
    authorize @warehouse
    if @warehouse.save
      redirect_to @warehouse, notice: "Depósito creado."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    authorize @warehouse
    if @warehouse.update(warehouse_params)
      redirect_to @warehouse, notice: "Depósito actualizado."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def set_warehouse = @warehouse = Warehouse.find_by!(code: params[:id].to_s.upcase)
  def warehouse_params = params.require(:warehouse).permit(:code, :name, :address, :timezone, :active)
end
