# frozen_string_literal: true

class SuppliersController < ApplicationController
  before_action :set_supplier, only: %i[show edit update]

  def index
    @pagy, @suppliers = pagy(policy_scope(Supplier).search(params[:q]).order(:name), limit: 25)
  end

  def show
    authorize @supplier
    @products = @supplier.products.kept.includes(:category).limit(50)
  end

  def new
    @supplier = Supplier.new
    authorize @supplier
  end

  def edit = authorize(@supplier)

  def create
    @supplier = Supplier.new(supplier_params)
    authorize @supplier
    if @supplier.save
      redirect_to @supplier, notice: "Proveedor creado."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    authorize @supplier
    if @supplier.update(supplier_params)
      redirect_to @supplier, notice: "Proveedor actualizado."
    else
      render :edit, status: :unprocessable_content
    end
  end

  private

  def set_supplier = @supplier = Supplier.find(params[:id])
  def supplier_params
    params.require(:supplier).permit(:name, :tax_id, :email, :phone, :address,
                                     :default_lead_time_days, :active)
  end
end
