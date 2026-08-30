# frozen_string_literal: true

module Api
  module V1
    # ==========================================================================
    # Las operaciones de stock. El controller más importante de la API.
    #
    # FIJATE LO FLACO QUE ES CADA ACCIÓN. Un controller sólo debería hacer 4
    # cosas, en este orden:
    #   1. Parsear/validar la entrada HTTP (strong params).
    #   2. Autorizar.
    #   3. Delegar a un service object.
    #   4. Traducir el Result a una respuesta HTTP.
    #
    # CERO lógica de negocio acá. ¿La prueba? Toda esta lógica se puede ejecutar
    # desde un job, desde la consola o desde un import CSV sin tocar una línea.
    # Si tuvieras las reglas en el controller, tendrías que duplicarlas.
    # ==========================================================================
    class StockOperationsController < BaseController
      requires_scope "stock:write"
      idempotent

      # ------------------------------------------------------------------------
      # Rate limit MÁS ESTRICTO para las escrituras de stock: cada una toma un
      # lock de fila, escribe en el ledger y encola un evento. Cuesta ~50x más
      # que un GET. Cobrarlas igual sería regalar la capacidad del sistema.
      # ------------------------------------------------------------------------
      # `name:` OBLIGATORIO: sin él comparte contador con el límite global de
      # BaseController. Ver el comentario largo allá.
      rate_limit to: 120, within: 1.minute,
                 name: "stock-writes",
                 by: -> { current_api_token&.id || request.remote_ip },
                 store: RATE_LIMIT_STORE,
                 with: -> { rate_limited!(30) }

      # POST /api/v1/stock/receive
      def receive
        item = resolve_stock_item(create_if_missing: true)
        authorize item, :receive?

        render_result(
          Stock::Receive.call(
            product: @product, warehouse: @warehouse, quantity: quantity_param,
            user: current_user, reason: params[:reason],
            unit_cost_cents: params[:unit_cost_cents], idempotency_key:
          ),
          success_status: :created, serializer: StockMovementSerializer
        )
      end

      # POST /api/v1/stock/issue
      def issue
        item = resolve_stock_item(create_if_missing: false)
        authorize item, :issue?

        render_result(
          Stock::Issue.call(
            product: @product, warehouse: @warehouse, quantity: quantity_param,
            user: current_user, reason: params[:reason], idempotency_key:
          ),
          success_status: :created, serializer: StockMovementSerializer
        )
      end

      # POST /api/v1/stock/adjust — corrección por conteo físico
      def adjust
        item = resolve_stock_item(create_if_missing: true)
        authorize item, :adjust?

        render_result(
          Stock::Adjust.call(
            product: @product, warehouse: @warehouse,
            counted_quantity: params.require(:counted_quantity).to_i,
            user: current_user, reason: params[:reason], idempotency_key:
          ),
          success_status: :created, serializer: StockMovementSerializer
        )
      end

      private

      def resolve_stock_item(create_if_missing:)
        @product = find_product!
        @warehouse = find_warehouse!
        StockItem.find_by(product: @product, warehouse: @warehouse) ||
          (create_if_missing ? StockItem.new(product: @product, warehouse: @warehouse) : nil) ||
          raise(ActiveRecord::RecordNotFound)
      end

      # `Integer(...)` en vez de `.to_i`: `"abc".to_i` devuelve 0 silenciosamente
      # (y "10 unidades".to_i devuelve 10, que es peor todavía porque parece que
      # funcionó). `Integer("abc")` levanta ArgumentError, que es lo que querés:
      # una entrada inválida tiene que fallar RUIDOSAMENTE.
      def quantity_param
        Integer(params.require(:quantity))
      rescue ArgumentError, TypeError
        raise ActionController::BadRequest, "El parámetro 'quantity' debe ser un entero"
      end
    end
  end
end
