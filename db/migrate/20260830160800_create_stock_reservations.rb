# frozen_string_literal: true

# ==============================================================================
# Reservas de stock (soft allocation).
#
# El caso de uso: un cliente pone algo en el carrito / se confirma un pedido
# pero todavía no salió del depósito. No querés descontar el stock físico
# (todavía está ahí) pero sí querés que nadie más lo pueda vender.
#
# Por eso stock_items tiene DOS contadores y una columna generada:
#   on_hand   -> lo que hay físicamente en la estantería
#   reserved  -> lo comprometido
#   available -> on_hand - reserved  (lo que realmente podés vender)
#
# Ciclo de vida:
#   held ──commit──> committed   (salió del depósito: reserved-- y on_hand--)
#     │
#     ├──release──> released     (se canceló: reserved--)
#     └──expire───> expired      (venció el TTL: reserved--, lo hace un job)
#
# El TTL + el job de expiración son críticos: sin eso, las reservas huérfanas
# te "comen" el stock disponible para siempre. Es un bug clásico de producción.
# ==============================================================================
class CreateStockReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_reservations do |t|
      t.references :stock_item, null: false, index: false,
                   foreign_key: { on_delete: :restrict }
      t.references :user, foreign_key: { on_delete: :nullify }

      t.integer :quantity, null: false
      t.string :status, null: false, default: "held"

      t.string :reference_type
      t.bigint :reference_id
      t.string :idempotency_key

      t.datetime :expires_at, null: false
      t.datetime :released_at
      t.datetime :committed_at
      t.text :reason

      t.timestamps
    end

    # Índice parcial CLAVE: el job de expiración corre cada minuto y pregunta
    # "¿qué reservas vivas ya vencieron?". Este índice contiene SÓLO las
    # reservas en estado 'held' (que son pocas y de vida corta), aunque la
    # tabla acumule millones de filas históricas.
    add_index :stock_reservations, :expires_at,
              where: "status = 'held'",
              name: "index_active_reservations_by_expiry"

    add_index :stock_reservations, [ :stock_item_id, :status ]
    add_index :stock_reservations, [ :reference_type, :reference_id ],
              where: "reference_type IS NOT NULL"
    add_index :stock_reservations, :idempotency_key,
              unique: true, where: "idempotency_key IS NOT NULL"

    add_check_constraint :stock_reservations, "quantity > 0",
                         name: "stock_reservations_quantity_positive"
    add_check_constraint :stock_reservations,
                         "status IN ('held', 'committed', 'released', 'expired')",
                         name: "stock_reservations_status_check"

    # Coherencia de la máquina de estados a nivel base: si está committed,
    # committed_at no puede ser NULL. Modelar la máquina de estados en el
    # schema evita filas "imposibles" que después rompen los reportes.
    add_check_constraint :stock_reservations,
                         "(status <> 'committed') OR (committed_at IS NOT NULL)",
                         name: "stock_reservations_committed_at_present"
    add_check_constraint :stock_reservations,
                         "(status NOT IN ('released', 'expired')) OR (released_at IS NOT NULL)",
                         name: "stock_reservations_released_at_present"
  end
end
