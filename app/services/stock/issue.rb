# frozen_string_literal: true

module Stock
  # Issue — sale mercadería del depósito (venta, consumo, despacho).
  # La cantidad entra POSITIVA en la API y se convierte en delta negativo acá:
  # el que llama no debería tener que pensar en signos.
  class Issue < ApplicationService
    def initialize(product:, warehouse:, quantity:, user: nil, reference: nil,
                   reason: nil, idempotency_key: nil,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @product = product
      @warehouse = warehouse
      @quantity = Integer(quantity)
      @user = user
      @reference = reference
      @reason = reason
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      return Result.failure(:invalid_quantity, "La cantidad debe ser positiva") unless @quantity.positive?

      transactional do
        resolved = ItemResolver.call(product: @product, warehouse: @warehouse, create_if_missing: false)
        fail!(resolved.error.code, resolved.error.message, **resolved.error.details) if resolved.failure?

        ApplyMovement.call(
          stock_item: resolved.value,
          kind: "issue",
          quantity: -@quantity,     # <- el signo lo pone el dominio, no el cliente
          user: @user,
          reference: @reference,
          reason: @reason,
          idempotency_key: @idempotency_key,
          event_recorder: @event_recorder,
          clock: @clock
        ).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
      end
    end
  end
end
