# frozen_string_literal: true

# ==============================================================================
# Transferencias entre depósitos.
#
# El punto fino: una transferencia NO es "restar acá y sumar allá" en un solo
# paso. La mercadería viaja: durante horas o días no está ni en el origen ni en
# el destino. Si la modelás como un movimiento atómico, el inventario físico
# nunca va a coincidir con el sistema.
#
# Modelo correcto (el que usa cualquier WMS serio):
#   dispatch : origen        --transfer_out--> depósito virtual EN-TRANSITO
#   receive  : EN-TRANSITO   --transfer_in-->  destino
#
# Así SUM(quantity) sobre TODO el ledger sigue siendo constante en cada paso.
# Por eso `warehouses` tiene la bandera `virtual`.
#
# Además: la recepción puede ser PARCIAL o con faltante (shrinkage), y eso se
# registra como un `scrap` contra el depósito en tránsito. Sin el depósito
# intermedio no tenés dónde imputar el faltante.
# ==============================================================================
class CreateStockTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_transfers do |t|
      t.string :reference, null: false               # "TR-2026-000123"
      t.references :source_warehouse, null: false,
                   foreign_key: { to_table: :warehouses, on_delete: :restrict }
      t.references :destination_warehouse, null: false,
                   foreign_key: { to_table: :warehouses, on_delete: :restrict }
      t.references :transit_warehouse,
                   foreign_key: { to_table: :warehouses, on_delete: :restrict }
      t.references :requested_by, null: false,
                   foreign_key: { to_table: :users, on_delete: :restrict }

      t.string :status, null: false, default: "draft"
      t.datetime :dispatched_at
      t.datetime :received_at
      t.datetime :cancelled_at
      t.text :notes

      t.timestamps
    end

    add_index :stock_transfers, :reference, unique: true
    add_index :stock_transfers, [ :status, :created_at ]
    # OJO: NO agregamos add_index sobre source_warehouse_id / destination_warehouse_id:
    # `t.references` YA crea un índice por cada FK. Duplicarlo tira
    # PG::DuplicateTable y, si le ponés otro nombre, te deja dos índices
    # idénticos ocupando disco y frenando cada INSERT. Error clásico.

    add_check_constraint :stock_transfers,
                         "status IN ('draft', 'in_transit', 'received', 'cancelled')",
                         name: "stock_transfers_status_check"

    # No podés transferir un depósito a sí mismo.
    add_check_constraint :stock_transfers,
                         "source_warehouse_id <> destination_warehouse_id",
                         name: "stock_transfers_different_warehouses"

    create_table :stock_transfer_lines do |t|
      t.references :stock_transfer, null: false, foreign_key: { on_delete: :cascade }
      t.references :product, null: false, foreign_key: { on_delete: :restrict }

      t.integer :quantity_requested, null: false
      t.integer :quantity_dispatched, null: false, default: 0
      t.integer :quantity_received, null: false, default: 0

      t.timestamps
    end

    add_index :stock_transfer_lines, [ :stock_transfer_id, :product_id ], unique: true

    add_check_constraint :stock_transfer_lines, "quantity_requested > 0",
                         name: "transfer_lines_requested_positive"
    add_check_constraint :stock_transfer_lines, "quantity_dispatched >= 0",
                         name: "transfer_lines_dispatched_non_negative"
    # No podés recibir más de lo que despachaste (sí menos: eso es faltante).
    add_check_constraint :stock_transfer_lines, "quantity_received <= quantity_dispatched",
                         name: "transfer_lines_received_lte_dispatched"
  end
end
