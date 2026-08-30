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

    def apply_corrections(drifts)
      drifts.count do |drift|
        item = StockItem.find(drift[:stock_item_id])
        ApplyMovement.call(
          stock_item: item, kind: "count_correction",
          quantity: drift[:ledger_total] - drift[:projected],
          reason: "Reconciliación automática: la proyección estaba en #{drift[:projected]}, " \
                  "el ledger en #{drift[:ledger_total]}",
          metadata: { autofix: true, drift: drift[:drift] }
        ).ok?
      end
    end
  end
end
