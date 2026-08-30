# frozen_string_literal: true

module Stock
  # ============================================================================
  # Receive — entra mercadería al depósito.
  #
  # Fijate lo FINITO que es este service: no tiene lógica de locking, ni de
  # ledger, ni de eventos. Todo eso lo hace ApplyMovement. Acá sólo vive lo que
  # es específico de "recibir": resolver el stock_item y traducir a un delta
  # positivo. Eso es SRP + composición.
  # ============================================================================
  class Receive < ApplicationService
    def initialize(product:, warehouse:, quantity:, user: nil, reference: nil,
                   unit_cost_cents: nil, reason: nil, idempotency_key: nil,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @product = product
      @warehouse = warehouse
      @quantity = Integer(quantity)
      @user = user
      @reference = reference
      @unit_cost_cents = unit_cost_cents
      @reason = reason
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      return Result.failure(:invalid_quantity, "La cantidad debe ser positiva") unless @quantity.positive?
      return Result.failure(:warehouse_inactive, "El depósito #{@warehouse.code} está inactivo") unless @warehouse.active?

      transactional do
        item = ItemResolver.call(product: @product, warehouse: @warehouse).value!

        ApplyMovement.call(
          stock_item: item,
          kind: "receipt",
          quantity: @quantity,
          user: @user,
          reference: @reference,
          unit_cost_cents: @unit_cost_cents || @product.cost_cents,
          reason: @reason,
          idempotency_key: @idempotency_key,
          event_recorder: @event_recorder,
          clock: @clock
        ).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
      end
    end
  end
end
