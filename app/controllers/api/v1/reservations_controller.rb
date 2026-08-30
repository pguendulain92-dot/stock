# frozen_string_literal: true

module Api
  module V1
    class ReservationsController < BaseController
      requires_scope "stock:read", only: %i[index show]
      requires_scope "stock:write", only: %i[create commit destroy]
      idempotent only: %i[create commit]

      def index
        scope = policy_scope(StockReservation).includes(stock_item: %i[product warehouse])
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.active if truthy?(params[:active])
        pagy, records = paginate(scope.order(created_at: :desc, id: :desc))
        render_collection(pagy, records, StockReservationSerializer)
      end

      def show
        reservation = StockReservation.includes(stock_item: %i[product warehouse]).find(params[:id])
        authorize reservation.stock_item, :reserve?
        render json: { data: StockReservationSerializer.new(reservation).as_json }
      end

      def create
        product = find_product!
        warehouse = find_warehouse!
        item = StockItem.find_by!(product:, warehouse:)
        authorize item, :reserve?

        render_result(
          Stock::Reserve.call(
            product:, warehouse:, quantity: Integer(params.require(:quantity)),
            user: current_user, ttl: ttl_param, reason: params[:reason],
            idempotency_key:
          ),
          success_status: :created, serializer: StockReservationSerializer
        )
      end

      # POST /api/v1/reservations/:id/commit — la mercadería sale del depósito
      def commit
        # SIN includes a propósito: acá hay UNA sola reserva, así que no puede
        # haber N+1 (hace falta que N > 1). Precargar de más es peor: en los
        # caminos de error (reserva vencida -> 410) el eager loading no se usa
        # nunca, y Bullet lo reporta como "AVOID eager loading". Precargá
        # cuando iterás una colección, no por reflejo.
        reservation = StockReservation.find(params[:id])
        authorize reservation.stock_item, :issue?

        render_result(
          Stock::CommitReservation.call(reservation:, user: current_user, idempotency_key:),
          serializer: StockReservationSerializer
        )
      end

      # DELETE /api/v1/reservations/:id — libera la reserva
      def destroy
        reservation = StockReservation.find(params[:id])
        authorize reservation.stock_item, :reserve?

        render_result(
          Stock::ReleaseReservation.call(reservation:, reason: params[:reason]),
          serializer: StockReservationSerializer
        )
      end

      private

      # El TTL viene del cliente pero SE ACOTA. Sin el clamp, un cliente pide
      # ttl_seconds=999999999 y te inmoviliza stock por 30 años.
      # Regla general: TODO valor numérico que venga del usuario y controle un
      # recurso (tiempo, tamaño, cantidad) necesita un techo.
      def ttl_param
        return StockReservation::DEFAULT_TTL if params[:ttl_seconds].blank?

        Integer(params[:ttl_seconds]).clamp(60, 7.days.to_i).seconds
      rescue ArgumentError, TypeError
        StockReservation::DEFAULT_TTL
      end

      def truthy?(v) = ActiveModel::Type::Boolean.new.cast(v)
    end
  end
end
