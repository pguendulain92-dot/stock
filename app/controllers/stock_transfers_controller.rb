# frozen_string_literal: true

class StockTransfersController < ApplicationController
  before_action :set_transfer, only: %i[show dispatch_transfer receive_transfer]

  def index
    scope = policy_scope(StockTransfer).with_associations
    scope = scope.where(status: params[:status]) if params[:status].present?
    @pagy, @transfers = pagy(scope.order(created_at: :desc), limit: 25)
  end

  def show = authorize(@transfer)

  def new
    @transfer = StockTransfer.new
    authorize @transfer, :create?
    @warehouses = Warehouse.physical.active.order(:code)
    @products = Product.kept.active.order(:sku).limit(200)
  end

  def create
    authorize StockTransfer.new, :create?
    form = StockTransferForm.new(
      source_warehouse_code: params[:source_warehouse_code],
      destination_warehouse_code: params[:destination_warehouse_code],
      notes: params[:notes]
    )
    form.lines = Array(params[:lines]).map { |l| l.permit(:sku, :quantity).to_h }
    form.requested_by = current_user

    result = form.save
    if result.ok?
      redirect_to result.value, notice: "Transferencia #{result.value.reference} creada."
    else
      @transfer = StockTransfer.new
      @warehouses = Warehouse.physical.active.order(:code)
      @products = Product.kept.active.order(:sku).limit(200)
      flash.now[:alert] = result.error.message
      render :new, status: :unprocessable_content
    end
  end

  # Se llama `dispatch_transfer` y no `dispatch` porque `dispatch` es un método
  # interno de ActionController. Ver el comentario en config/routes.rb.
  def dispatch_transfer
    authorize @transfer, :dispatch?
    result = Stock::Transfers::Dispatch.call(transfer: @transfer, user: current_user)
    redirect_to @transfer, **flash_for(result, "Transferencia despachada.")
  end

  def receive_transfer
    authorize @transfer, :receive?
    result = Stock::Transfers::Receive.call(
      transfer: @transfer, user: current_user, received_quantities: received_quantities
    )
    redirect_to @transfer, **flash_for(result, "Transferencia recibida.")
  end

  private

  def set_transfer = @transfer = StockTransfer.with_associations.find(params[:id])

  def flash_for(result, message)
    result.ok? ? { notice: message } : { alert: result.error.message }
  end

  def received_quantities
    return nil if params[:received].blank?

    params[:received].to_unsafe_h.transform_keys(&:to_i).transform_values(&:to_i)
  end
end
