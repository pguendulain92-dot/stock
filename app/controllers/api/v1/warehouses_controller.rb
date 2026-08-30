# frozen_string_literal: true

module Api
  module V1
    class WarehousesController < BaseController
      requires_scope "catalog:read"

      def index
        scope = policy_scope(Warehouse).order(:code)
        scope = scope.physical unless ActiveModel::Type::Boolean.new.cast(params[:include_virtual])
        render json: { data: scope.map { |w| serialize(w) } }
      end

      def show
        warehouse = Warehouse.find_by!(code: params[:id].to_s.upcase)
        authorize warehouse
        render json: { data: serialize(warehouse).merge(
          stats: {
            distinct_products: warehouse.stock_items.count,
            total_units: warehouse.stock_items.sum(:quantity_on_hand),
            low_stock_items: warehouse.stock_items.where("quantity_available <= reorder_point").count
          }
        ) }
      end

      private

      def serialize(warehouse)
        { id: warehouse.id, code: warehouse.code, name: warehouse.name,
          address: warehouse.address, timezone: warehouse.timezone,
          active: warehouse.active, virtual: warehouse.virtual }
      end
    end
  end
end
