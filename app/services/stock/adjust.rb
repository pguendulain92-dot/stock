# frozen_string_literal: true

module Stock
  # ============================================================================
  # Adjust — corrección por inventario físico ("conteo cíclico").
  #
  # El operario cuenta la estantería y dice "hay 47". El sistema decía 50.
  # Registramos un movimiento de -3 con kind 'count_correction'. NUNCA
  # sobreescribimos `quantity_on_hand` directamente: eso rompería la invariante
  # `on_hand == SUM(movements)` y perdería la traza de la diferencia, que es
  # justamente el dato que le interesa al negocio (mermas, robo, errores de
  # picking).
  #
  # Este service muestra la diferencia entre "setear un valor" y "registrar un
  # hecho". El ledger sólo entiende de hechos.
  # ============================================================================
  class Adjust < ApplicationService
    def initialize(product:, warehouse:, counted_quantity:, user: nil, reason: nil,
                   idempotency_key: nil, event_recorder: Outbox::Recorder.new, clock: Time)
      @product = product
      @warehouse = warehouse
      @counted_quantity = Integer(counted_quantity)
      @user = user
      @reason = reason
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder
      @clock = clock
    end

    def call
      return Result.failure(:invalid_quantity, "El conteo no puede ser negativo") if @counted_quantity.negative?
      return Result.failure(:reason_required, "Un ajuste de inventario requiere un motivo") if @reason.blank?

      transactional do
        item = ItemResolver.call(product: @product, warehouse: @warehouse).value!

        # Releemos con lock ANTES de calcular el delta. Si calculás el delta con
        # un valor leído fuera del lock, otra transacción puede haber movido el
        # stock en el medio y el ajuste corrige contra un saldo viejo.
        locked = StockItem.lock.find(item.id)
        delta = @counted_quantity - locked.quantity_on_hand

        if delta.zero?
          next success(nil)   # el conteo coincide: no hay nada que registrar
        end

        ApplyMovement.call(
          stock_item: locked,
          kind: "count_correction",
          quantity: delta,
          user: @user,
          reason: @reason,
          idempotency_key: @idempotency_key,
          metadata: { counted: @counted_quantity, previous: locked.quantity_on_hand },
          event_recorder: @event_recorder,
          clock: @clock
        ).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
      end.then do |result|
        # `last_counted_at` es metadata operativa, no contable: va aparte.
        if result.ok?
          StockItem.where(product: @product, warehouse: @warehouse)
                   .update_all(last_counted_at: Time.current, updated_at: Time.current)
        end
        result
      end
    end
  end
end
