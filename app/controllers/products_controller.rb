# frozen_string_literal: true

class ProductsController < ApplicationController
  before_action :set_product, only: %i[show edit update destroy discard]

  def index
    products = Products::Search.call(
      term: params[:q], category_id: params[:category_id],
      sort: params[:sort].presence || "name", scope: policy_scope(Product)
    )
    @pagy, @products = pagy(products, limit: 25)
    # Una sola query agregada para toda la página. Ver docs/04.
    @availability = StockItems::Availability.call(product_ids: @products.map(&:id))
  end

  def show
    authorize @product
    @stock_items = @product.stock_items.includes(:warehouse).order("warehouses.code")
    @movements = StockMovements::Ledger.call(product_id: @product.id, limit: 25).to_a
  end

  def new
    @product = Product.new(unit: "unit", currency: "USD")
    authorize @product
  end

  def edit = authorize(@product)

  def create
    @product = Product.new(product_params)
    authorize @product

    if @product.save
      redirect_to @product, notice: "Producto creado."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    authorize @product
    if @product.update(product_params)
      redirect_to @product, notice: "Producto actualizado."
    else
      render :edit, status: :unprocessable_content
    end
  rescue ActiveRecord::StaleObjectError
    redirect_to edit_product_path(@product),
                alert: "Otro usuario modificó este producto mientras lo editabas. Revisá los cambios."
  end

  def discard
    authorize @product, :discard?
    @product.discard!
    redirect_to products_path, notice: "Producto dado de baja."
  end

  def destroy
    authorize @product
    @product.discard!
    redirect_to products_path, notice: "Producto dado de baja.", status: :see_other
  end

  private

  # `find_by!` por SKU (clave natural) y no por id: las URLs quedan legibles
  # (/products/TOR-001) y no exponen ids secuenciales, que permiten inferir
  # cuántos productos tenés y enumerarlos.
  def set_product
    @product = Product.find_by!(sku: params[:id].to_s.upcase)
  end

  def product_params
    params.require(:product).permit(:sku, :name, :description, :barcode, :category_id,
                                    :unit, :cost_cents, :price_cents, :currency,
                                    :active, :lock_version)
  end
end
