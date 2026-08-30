# frozen_string_literal: true

class CreatePurchaseOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :purchase_orders do |t|
      t.string :reference, null: false                # "PO-2026-000045"
      t.references :supplier, null: false, foreign_key: { on_delete: :restrict }
      t.references :warehouse, null: false, foreign_key: { on_delete: :restrict }
      t.references :created_by, null: false,
                   foreign_key: { to_table: :users, on_delete: :restrict }

      t.string :status, null: false, default: "draft"
      t.string :currency, null: false, default: "USD"

      # CONTADOR DESNORMALIZADO (counter cache manual).
      # Guardar el total en vez de recalcularlo con un SUM sobre las líneas
      # evita un N+1 brutal en el listado de órdenes. Se recalcula en un
      # callback de la línea, dentro de la misma transacción.
      t.bigint :total_cents, null: false, default: 0
      t.integer :lines_count, null: false, default: 0

      t.date :expected_at
      t.datetime :submitted_at
      t.datetime :received_at
      t.datetime :cancelled_at
      t.text :notes

      t.timestamps
    end

    add_index :purchase_orders, :reference, unique: true
    add_index :purchase_orders, [ :supplier_id, :status ]
    add_index :purchase_orders, [ :status, :expected_at ],
              where: "status IN ('submitted', 'partially_received')",
              name: "index_open_purchase_orders"

    add_check_constraint :purchase_orders,
                         "status IN ('draft', 'submitted', 'partially_received', " \
                         "'received', 'cancelled')",
                         name: "purchase_orders_status_check"
    add_check_constraint :purchase_orders, "total_cents >= 0",
                         name: "purchase_orders_total_non_negative"

    create_table :purchase_order_lines do |t|
      t.references :purchase_order, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.references :product, null: false, foreign_key: { on_delete: :restrict }

      t.integer :quantity_ordered, null: false
      t.integer :quantity_received, null: false, default: 0
      t.bigint :unit_cost_cents, null: false, default: 0

      # Columna generada: el subtotal nunca puede desincronizarse del precio
      # y la cantidad porque lo calcula Postgres.
      t.virtual :subtotal_cents,
                type: :bigint,
                as: "quantity_ordered::bigint * unit_cost_cents",
                stored: true

      t.timestamps
    end

    add_index :purchase_order_lines, [ :purchase_order_id, :product_id ], unique: true

    add_check_constraint :purchase_order_lines, "quantity_ordered > 0",
                         name: "po_lines_ordered_positive"
    add_check_constraint :purchase_order_lines,
                         "quantity_received >= 0 AND quantity_received <= quantity_ordered",
                         name: "po_lines_received_within_ordered"
    add_check_constraint :purchase_order_lines, "unit_cost_cents >= 0",
                         name: "po_lines_cost_non_negative"
  end
end
