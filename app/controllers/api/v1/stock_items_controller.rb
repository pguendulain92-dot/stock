# frozen_string_literal: true

module Api
  module V1
    class StockItemsController < BaseController
      requires_scope "stock:read"

      def index
        scope = policy_scope(StockItem).with_associations
        scope = scope.where(warehouse_id: warehouse_filter) if params[:warehouse_code].present?
        scope = scope.where(product_id: product_filter) if params[:sku].present?
        scope = scope.where("quantity_available <= reorder_point") if truthy?(params[:low_stock])
        scope = scope.where(quantity_available: 1..) if truthy?(params[:in_stock])

        pagy, records = paginate(scope.order(:warehouse_id, :product_id))
        render_collection(pagy, records, StockItemSerializer)
      end

      def show
        item = StockItem.with_associations.find(params[:id])
        authorize item
        render json: { data: StockItemSerializer.new(item).as_json }
      end

      private

      def warehouse_filter = Warehouse.where(code: params[:warehouse_code].to_s.upcase).select(:id)
      def product_filter   = Product.where(sku: params[:sku].to_s.upcase).select(:id)
      def truthy?(v) = ActiveModel::Type::Boolean.new.cast(v)
    end
  end
end
