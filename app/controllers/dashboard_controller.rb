# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    # El panel no es un recurso: agrega métricas de varios modelos y no hay un
    # objeto que autorizar. `skip_policy_scope` lo declara EXPLÍCITAMENTE, que
    # es lo importante: la red de seguridad de ApplicationController sigue
    # avisando en cualquier otra acción que se olvide de autorizar.
    # (El acceso ya está restringido: `require_authentication` corre antes.)
    skip_policy_scope

    # ── CACHE DE LECTURA ────────────────────────────────────────────────────
    # El dashboard hace 6 agregaciones. Cachearlas 60 s no cambia nada para el
    # usuario y le saca un montón de carga a la base cuando 20 operarios lo
    # tienen abierto en una pantalla.
    @stats = Rails.cache.fetch("dashboard/stats", expires_in: 60.seconds) { compute_stats }

    @low_stock = StockItems::LowStock.call.limit(10).to_a
    # `preload:` sin `:user`: el panel no muestra quién hizo el movimiento, así
    # que cargarlo sería una query de más en cada visita. Lo detectó Bullet con
    # BULLET_UNUSED=1.
    @recent_movements = StockMovements::Ledger.call(limit: 15, preload: %i[product warehouse]).to_a
    @warehouses = Warehouse.physical.active.order(:code)
  end

  private

  def compute_stats
    {
      products: Product.kept.active.count,
      warehouses: Warehouse.physical.active.count,
      total_units: StockItem.sum(:quantity_on_hand),
      reserved_units: StockItem.sum(:quantity_reserved),
      low_stock_count: StockItem.where("quantity_available <= reorder_point")
                                .where.not(reorder_point: 0).count,
      open_transfers: StockTransfer.open.count,
      pending_events: OutboxEvent.pending.count,
      movements_today: StockMovement.where(occurred_at: Time.current.all_day).count
    }
  end
end
