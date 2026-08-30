# frozen_string_literal: true

module Api
  module V1
    # El ledger. Se pagina por KEYSET (cursor), no por offset.
    # El porqué está en app/queries/stock_movements/ledger.rb.
    class StockMovementsController < BaseController
      requires_scope "stock:read"

      def index
        skip_policy_scope   # el filtrado lo hace el query object, no un scope de Pundit

        movements = StockMovements::Ledger.call(
          product_id: product_id_filter, warehouse_id: warehouse_id_filter,
          kinds: params[:kinds]&.split(","), user_id: params[:user_id],
          from: parse_time(params[:from]), to: parse_time(params[:to]),
          cursor: params[:cursor], limit: params[:limit] || 50
        ).to_a

        render json: {
          data: StockMovementSerializer.collection(movements),
          meta: {
            count: movements.size,
            # El cursor de la ÚLTIMA fila. Si viene nil, no hay más páginas.
            next_cursor: movements.size < requested_limit ? nil : StockMovements::Ledger.encode_cursor(movements.last)
          }
        }
      end

      private

      def requested_limit = (params[:limit] || 50).to_i.clamp(1, 200)
      def product_id_filter = params[:sku].present? ? Product.find_by!(sku: params[:sku].upcase).id : params[:product_id]
      def warehouse_id_filter = params[:warehouse_code].present? ? Warehouse.find_by!(code: params[:warehouse_code].upcase).id : params[:warehouse_id]

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        raise ActionController::BadRequest, "Fecha inválida: #{value}"
      end
    end
  end
end
