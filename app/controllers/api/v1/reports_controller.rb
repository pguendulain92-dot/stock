# frozen_string_literal: true

module Api
  module V1
    class ReportsController < BaseController
      requires_scope "stock:read"

      # Los reportes son CAROS (agregaciones sobre toda la tabla). Límite propio,
      # mucho más bajo, y cacheado.
      # `name:` OBLIGATORIO: ver BaseController.
      rate_limit to: 20, within: 1.minute,
                 name: "reports",
                 by: -> { current_api_token&.id || request.remote_ip },
                 store: RATE_LIMIT_STORE,
                 with: -> { rate_limited!(60) }

      def low_stock
        skip_authorization
        items = StockItems::LowStock.call(warehouse_id: warehouse_id_filter)
        pagy, records = paginate(items)
        render_collection(pagy, records, StockItemSerializer)
      end

      def valuation
        skip_authorization

        # CACHE DE LECTURA. `Rails.cache.fetch` con TTL corto: una valuación de
        # inventario no cambia significativamente en 5 minutos y cuesta un scan
        # agregado. La clave incluye TODOS los parámetros que afectan el
        # resultado — si te olvidás uno, servís el reporte de otro depósito.
        # Ese es el bug #1 del caching y es silencioso.
        payload = Rails.cache.fetch(valuation_cache_key, expires_in: 5.minutes) do
          result = StockItems::Valuation.call(warehouse_id: warehouse_id_filter,
                                              category_id: params[:category_id])
          {
            total_units: result[:total_units],
            totals: result[:totals].transform_values(&:as_json),
            by_warehouse: result[:by_warehouse].transform_values { |v|
              { value: v[:value].as_json, units: v[:units] }
            },
            generated_at: Time.current.iso8601
          }
        end

        render json: { data: payload }
      end

      def reconciliation
        skip_authorization
        drifts = StockItems::Reconciliation.call(warehouse_id: warehouse_id_filter)
        render json: { data: drifts, meta: { count: drifts.size, healthy: drifts.empty? } }
      end

      private

      def warehouse_id_filter
        return nil if params[:warehouse_code].blank?

        Warehouse.find_by!(code: params[:warehouse_code].to_s.upcase).id
      end

      def valuation_cache_key
        [ "reports/valuation", params[:warehouse_code].to_s.upcase, params[:category_id] ].join("/")
      end
    end
  end
end
