# frozen_string_literal: true

module Api
  module V1
    class StockTransfersController < BaseController
      requires_scope "stock:read", only: %i[index show]
      requires_scope "transfers:write", only: %i[create dispatch_transfer receive_transfer]
      idempotent only: %i[create dispatch_transfer receive_transfer]

      def index
        scope = policy_scope(StockTransfer).with_associations
        scope = scope.where(status: params[:status]) if params[:status].present?
        pagy, records = paginate(scope.order(created_at: :desc, id: :desc))
        render_collection(pagy, records, StockTransferSerializer)
      end

      def show
        transfer = StockTransfer.with_associations.find(params[:id])
        authorize transfer
        render json: { data: StockTransferSerializer.new(transfer).as_json }
      end

      def create
        form = StockTransferForm.new(transfer_params.merge(requested_by: current_user))
        authorize StockTransfer.new(
          source_warehouse_id: form.source_warehouse_id,
          destination_warehouse_id: form.destination_warehouse_id
        ), :create?

        render_result(form.save, success_status: :created, serializer: StockTransferSerializer)
      end

      # `dispatch` es reservado en ActionController. Ver config/routes.rb.
      def dispatch_transfer
        transfer = StockTransfer.find(params[:id])
        authorize transfer, :dispatch?
        render_result(Stock::Transfers::Dispatch.call(transfer:, user: current_user),
                      serializer: StockTransferSerializer)
      end

      def receive_transfer
        transfer = StockTransfer.find(params[:id])
        authorize transfer, :receive?
        render_result(
          Stock::Transfers::Receive.call(transfer:, user: current_user,
                                         received_quantities: received_quantities_param),
          serializer: StockTransferSerializer
        )
      end

      private

      def transfer_params
        params.require(:stock_transfer)
              .permit(:source_warehouse_code, :destination_warehouse_code, :notes,
                      lines: %i[sku quantity])
      end

      # { "received": { "SKU-1": 18, "SKU-2": 5 } } -> { product_id => qty }
      def received_quantities_param
        raw = params[:received]
        return nil if raw.blank?

        skus = raw.keys.map { |s| s.to_s.upcase }
        by_sku = Product.where(sku: skus).pluck(:sku, :id).to_h
        raw.to_unsafe_h.each_with_object({}) do |(sku, qty), acc|
          id = by_sku[sku.to_s.upcase]
          raise ActiveRecord::RecordNotFound, "SKU desconocido: #{sku}" if id.nil?

          acc[id] = Integer(qty)
        end
      end
    end
  end
end
