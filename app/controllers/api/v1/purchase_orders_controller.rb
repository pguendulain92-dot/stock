# frozen_string_literal: true

module Api
  module V1
    class PurchaseOrdersController < BaseController
      requires_scope "stock:read", only: %i[index show]
      requires_scope "purchases:write", only: %i[create submit receive_order cancel]
      idempotent only: %i[create receive_order]

      def index
        scope = policy_scope(PurchaseOrder).with_associations
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.open if truthy?(params[:open])
        pagy, records = paginate(scope.order(created_at: :desc, id: :desc))
        render_collection(pagy, records, PurchaseOrderSerializer)
      end

      def show
        order = PurchaseOrder.with_associations.find_by!(reference: params[:id])
        authorize order
        render json: { data: PurchaseOrderSerializer.new(order).as_json }
      end

      def create
        authorize PurchaseOrder.new, :create?

        form = PurchaseOrderForm.new(order_params.except(:lines))
        form.lines = order_params[:lines]
        form.created_by = current_user

        render_result(form.save, success_status: :created, serializer: PurchaseOrderSerializer)
      end

      # POST /api/v1/purchase_orders/:id/submit — la orden sale al proveedor
      def submit
        order = PurchaseOrder.find_by!(reference: params[:id])
        authorize order, :submit?

        unless order.can_transition_to?("submitted")
          return render_error(:invalid_transition,
                              "Una orden en estado '#{order.status}' no se puede enviar.",
                              status: :unprocessable_content)
        end

        order.update!(status: "submitted", submitted_at: Time.current)
        Outbox::Recorder.new.record(
          aggregate: order, event_type: "purchase_order.submitted",
          payload: { purchase_order_id: order.id, reference: order.reference,
                     supplier_id: order.supplier_id, total_cents: order.total_cents }
        )

        render json: { data: PurchaseOrderSerializer.new(order).as_json }
      end

      # POST /api/v1/purchase_orders/:id/receive — recepción total o parcial
      # (se llama `receive_order` porque `receive` no colisiona pero mantenemos
      # el mismo criterio que en transferencias: ver config/routes.rb).
      def receive_order
        order = PurchaseOrder.find_by!(reference: params[:id])
        authorize order, :receive?

        render_result(
          Purchasing::ReceiveOrder.call(
            purchase_order: order, user: current_user,
            received_quantities: received_quantities_param,
            idempotency_key:
          ),
          serializer: PurchaseOrderSerializer
        )
      end

      def cancel
        order = PurchaseOrder.find_by!(reference: params[:id])
        authorize order, :cancel?

        unless order.can_transition_to?("cancelled")
          return render_error(:invalid_transition,
                              "Una orden en estado '#{order.status}' no se puede cancelar.",
                              status: :unprocessable_content)
        end

        order.update!(status: "cancelled", cancelled_at: Time.current)
        render json: { data: PurchaseOrderSerializer.new(order).as_json }
      end

      private

      def order_params
        params.require(:purchase_order)
              .permit(:supplier_tax_id, :warehouse_code, :expected_at, :currency, :notes,
                      lines: %i[sku quantity unit_cost_cents])
      end

      def received_quantities_param
        raw = params[:received]
        return nil if raw.blank?

        by_sku = Product.where(sku: raw.keys.map { |s| s.to_s.upcase }).pluck(:sku, :id).to_h
        raw.to_unsafe_h.each_with_object({}) do |(sku, qty), acc|
          id = by_sku[sku.to_s.upcase] or raise ActiveRecord::RecordNotFound, "SKU desconocido: #{sku}"
          acc[id] = Integer(qty)
        end
      end

      def truthy?(value) = ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
