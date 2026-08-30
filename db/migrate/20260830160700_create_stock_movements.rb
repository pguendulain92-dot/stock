# frozen_string_literal: true

# ==============================================================================
# stock_movements = EL LIBRO MAYOR (ledger). Append-only, inmutable.
#
# Este es el patrón más importante del dominio y el que te va a diferenciar en
# una entrevista. La idea viene de la contabilidad de partida doble:
#
#   stock_items.quantity_on_hand  es una PROYECCIÓN (un cache).
#   stock_movements               es la VERDAD (el hecho histórico).
#
# Invariante global:
#   stock_items.quantity_on_hand == SUM(stock_movements.quantity) para ese item
#
# ¿Por qué no calcular la cantidad con un SUM() cada vez y borrar la columna?
#   Porque con millones de movimientos el SUM se vuelve carísimo. Guardamos la
#   proyección para leer O(1) y el ledger para auditar/reconstruir. Es
#   exactamente el trade-off de CQRS / event sourcing, en su versión pragmática.
#   El job `Stock::ReconcileBalancesJob` compara las dos y alerta si difieren.
#
# `quantity` es CON SIGNO: +50 entra, -3 sale. Así el SUM() funciona directo.
# `quantity_after` guarda el saldo resultante: te permite auditar el orden de
# aplicación y detectar huecos sin recalcular todo el ledger.
# ==============================================================================
class CreateStockMovements < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_movements do |t|
      # index: false -> el índice compuesto del ledger, más abajo, ya lo cubre.
      t.references :stock_item, null: false, index: false,
                   foreign_key: { on_delete: :restrict }

      # DESNORMALIZACIÓN DELIBERADA. product_id y warehouse_id son derivables de
      # stock_item, pero copiarlos evita un JOIN en TODOS los reportes
      # históricos, que son la lectura más frecuente y más pesada.
      # El costo: hay que mantenerlos consistentes (lo hace un callback del
      # modelo + un test). Es un trade-off consciente, no un descuido.
      t.references :product, null: false, index: false,
                   foreign_key: { on_delete: :restrict }
      t.references :warehouse, null: false, index: false,
                   foreign_key: { on_delete: :restrict }

      # Nullable: hay movimientos del sistema (jobs, integraciones) sin usuario.
      # on_delete: :nullify -> si borrás el usuario, el movimiento SOBREVIVE.
      # Jamás borres historia contable en cascada.
      t.references :user, foreign_key: { on_delete: :nullify }

      t.string :kind, null: false
      t.integer :quantity, null: false          # con signo
      t.integer :quantity_after, null: false    # saldo resultante

      t.bigint :unit_cost_cents
      t.string :currency, null: false, default: "USD"

      # Asociación polimórfica "manual": apunta a la orden de compra, el
      # transfer, la venta, etc. La dejamos SIN foreign key (es la limitación
      # inherente del polimorfismo en SQL: no podés tener una FK a N tablas).
      # Ver docs/03 §polimorfismo para las alternativas (tablas exclusivas de
      # arco, o una FK por tipo con CHECK de "exactamente una no nula").
      t.string :reference_type
      t.bigint :reference_id

      # IDEMPOTENCIA. Si el cliente reintenta un POST (timeout, retry del load
      # balancer, doble click), la segunda inserción viola este índice único y
      # devolvemos el resultado original en vez de duplicar el movimiento.
      # Es EL mecanismo para APIs de escritura seguras. Ver docs/11.
      t.string :idempotency_key

      t.text :reason
      t.jsonb :metadata, null: false, default: {}

      t.datetime :occurred_at, null: false

      # OJO: sólo created_at, sin updated_at. El modelo además es readonly.
      # Un ledger que se puede editar no es un ledger.
      t.datetime :created_at, null: false
    end

    # El índice que sirve "movimientos de este item, más recientes primero".
    # El orden DESC en el índice evita el paso de Sort en el plan de ejecución.
    add_index :stock_movements, [ :stock_item_id, :occurred_at, :id ], order: { occurred_at: :desc, id: :desc },
              name: "index_stock_movements_ledger"
    add_index :stock_movements, [ :product_id, :occurred_at ], order: { occurred_at: :desc }
    add_index :stock_movements, [ :warehouse_id, :occurred_at ], order: { occurred_at: :desc }
    add_index :stock_movements, [ :reference_type, :reference_id ],
              where: "reference_type IS NOT NULL"

    # Unique PARCIAL: sólo aplica cuando hay clave. Los movimientos internos
    # (sin idempotency_key) no compiten por el índice ni lo hacen crecer.
    add_index :stock_movements, :idempotency_key,
              unique: true, where: "idempotency_key IS NOT NULL"

    add_check_constraint :stock_movements,
                         "kind IN ('receipt', 'issue', 'adjustment', 'transfer_in', " \
                         "'transfer_out', 'return', 'scrap', 'count_correction')",
                         name: "stock_movements_kind_check"

    # Un movimiento de cantidad 0 no es un movimiento: es ruido en el ledger.
    add_check_constraint :stock_movements, "quantity <> 0",
                         name: "stock_movements_quantity_not_zero"
    add_check_constraint :stock_movements, "quantity_after >= 0",
                         name: "stock_movements_quantity_after_non_negative"

    # Coherencia signo <-> tipo. Una entrada NO puede tener cantidad negativa.
    add_check_constraint :stock_movements,
                         "(kind IN ('receipt', 'transfer_in', 'return') AND quantity > 0) OR " \
                         "(kind IN ('issue', 'transfer_out', 'scrap') AND quantity < 0) OR " \
                         "(kind IN ('adjustment', 'count_correction'))",
                         name: "stock_movements_sign_matches_kind"
  end
end
