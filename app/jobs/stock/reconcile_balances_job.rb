# frozen_string_literal: true

module Stock
  # ============================================================================
  # Compara la PROYECCIÓN (stock_items.quantity_on_hand) con la VERDAD
  # (SUM de stock_movements) y alerta si difieren.
  #
  # Este job no "arregla" nada por defecto, y es a propósito: si hay una
  # discrepancia, hay un BUG, y auto-corregirlo lo escondería. Querés que salte
  # la alarma y que alguien mire. `autofix: true` existe sólo para una corrida
  # manual y deliberada, y deja su propio movimiento en el ledger.
  # ============================================================================
  class ReconcileBalancesJob < ApplicationJob
    queue_as :maintenance

    def perform(warehouse_id: nil, autofix: false)
      drifts = StockItems::Reconciliation.call(warehouse_id:)

      if drifts.empty?
        Rails.logger.info(event: "stock.reconciliation", status: "ok")
        return { healthy: true, drifts: 0 }
      end

      Rails.logger.error(event: "stock.reconciliation", status: "DRIFT_DETECTED",
                         count: drifts.size, sample: drifts.first(10))

      fixed = autofix ? apply_corrections(drifts) : 0
      { healthy: false, drifts: drifts.size, fixed: }
    end

    private

    # ┌──────────────────────────────────────────────────────────────────────┐
    # │ CÓMO SE CORRIGE UNA DISCREPANCIA (y por qué NO se usa ApplyMovement)  │
    # │                                                                      │
    # │ El instinto es "escribo un movimiento con la diferencia y listo".     │
    # │ Está MAL, y el test lo detectó: ApplyMovement mueve las DOS cosas     │
    # │ (la proyección y el ledger) por el mismo delta, así que la diferencia │
    # │ entre ambas queda EXACTAMENTE IGUAL. Nunca converge.                  │
    # │                                                                      │
    # │   proyección = 100, ledger = 0   (drift = 100)                        │
    # │   ApplyMovement(-100) -> proyección = 0, ledger = -100 (drift = 100)  │
    # │                                                                      │
    # │ Para cerrar la brecha hay que mover UNA sola de las dos.              │
    # │ ¿Cuál es la verdad? La PROYECCIÓN, porque `quantity_on_hand` es lo    │
    # │ que el depósito viene usando y lo que el operario ve. Escribimos      │
    # │ entonces un asiento de ajuste que lleva el LEDGER hasta ella, SIN     │
    # │ tocar la cantidad física. Así queda auditado qué pasó y cuánto fue,   │
    # │ en vez de que la diferencia desaparezca sin registro.                 │
    # │                                                                      │
    # │ Por eso el job NO autocorrige por defecto: una discrepancia siempre   │
    # │ significa que hay un bug (alguien escribió la cantidad sin pasar por  │
    # │ un service), y taparlo automáticamente lo esconde.                    │
    # └──────────────────────────────────────────────────────────────────────┘
    def apply_corrections(drifts)
      drifts.count do |drift|
        item = StockItem.find(drift[:stock_item_id])
        delta = drift[:projected] - drift[:ledger_total]
        next false if delta.zero?

        StockMovement.create!(
          stock_item: item,
          product_id: item.product_id,
          warehouse_id: item.warehouse_id,
          kind: "count_correction",
          quantity: delta,
          quantity_after: drift[:projected],
          currency: item.product.currency,
          reason: "Reconciliación automática: la proyección estaba en #{drift[:projected]} " \
                  "y el ledger sumaba #{drift[:ledger_total]}",
          metadata: { autofix: true, drift: drift[:drift] },
          occurred_at: Time.current
        )
        true
      end
    end
  end
end
