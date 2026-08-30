# frozen_string_literal: true

# ==============================================================================
# stock_items = LA TABLA CENTRAL. Un renglón por (producto, depósito).
#
# Es un "agregado" en términos de DDD: la unidad de consistencia transaccional.
# Todas las operaciones de stock bloquean esta fila y sólo esta fila.
#
# TRES INVARIANTES que NO pueden romperse nunca:
#   1. quantity_on_hand   >= 0        (no existe stock físico negativo)
#   2. quantity_reserved  >= 0
#   3. quantity_reserved  <= quantity_on_hand   (no reservás lo que no tenés)
#
# Las escribimos como CHECK constraints. La diferencia con una validación de
# Rails es enorme: la validación corre en UN proceso Ruby y NO es atómica —
# entre el SELECT que valida y el UPDATE que escribe, otro proceso puede haber
# cambiado la fila. El CHECK lo evalúa Postgres DENTRO de la transacción, sobre
# la fila final. Es la única garantía real bajo concurrencia. Ver docs/06.
# ==============================================================================
class CreateStockItems < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_items do |t|
      # index: false porque más abajo creamos índices COMPUESTOS que ya cubren
      # estas columnas como prefijo izquierdo. Un B-tree sobre (a, b) sirve
      # perfectamente para consultas sobre `a` solo — el índice extra sobre `a`
      # es disco desperdiciado y una escritura más en cada INSERT/UPDATE.
      # Este es EL desperdicio más común en schemas de Rails: `t.references`
      # crea un índice automático y después uno agrega el compuesto sin pensar.
      t.references :product, null: false, index: false,
                   foreign_key: { on_delete: :restrict }
      t.references :warehouse, null: false, index: false,
                   foreign_key: { on_delete: :restrict }

      t.integer :quantity_on_hand, null: false, default: 0
      t.integer :quantity_reserved, null: false, default: 0

      # COLUMNA GENERADA (PostgreSQL 12+, Rails `t.virtual ... stored: true`).
      # Postgres la calcula y la PERSISTE en cada INSERT/UPDATE. No se puede
      # escribir a mano. Ventajas frente a calcularla en Ruby:
      #   - Imposible que se desincronice.
      #   - Se puede INDEXAR y usar en WHERE/ORDER BY sin recalcular.
      #   - La ven todos los clientes de la base, no sólo Rails.
      # Es el equivalente a una @Formula de Hibernate, pero materializada.
      t.virtual :quantity_available,
                type: :integer,
                as: "quantity_on_hand - quantity_reserved",
                stored: true

      t.integer :reorder_point, null: false, default: 0
      t.integer :reorder_quantity, null: false, default: 0
      t.integer :maximum_level

      t.string :bin_location                 # "P3-A-04": pasillo/estante
      t.datetime :last_counted_at            # último inventario físico
      t.datetime :last_movement_at

      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    # LA clave natural. Único índice que garantiza "un renglón por par".
    # Sin él, un doble POST concurrente crea dos stock_items para el mismo par
    # y a partir de ahí el stock queda partido en dos y nunca cierra.
    add_index :stock_items, [ :product_id, :warehouse_id ], unique: true

    # Para "¿qué hay en el depósito X?" ordenado.
    add_index :stock_items, [ :warehouse_id, :product_id ]

    # Índice parcial para el reporte de reposición: sólo indexa las filas que
    # están efectivamente bajo el punto de reorden. En una tabla de 5M filas
    # donde 200 están bajas, este índice tiene 200 entradas en vez de 5M.
    add_index :stock_items, [ :warehouse_id, :quantity_available ],
              where: "quantity_available <= reorder_point",
              name: "index_stock_items_needing_reorder"

    add_check_constraint :stock_items, "quantity_on_hand >= 0",
                         name: "stock_items_on_hand_non_negative"
    add_check_constraint :stock_items, "quantity_reserved >= 0",
                         name: "stock_items_reserved_non_negative"
    add_check_constraint :stock_items, "quantity_reserved <= quantity_on_hand",
                         name: "stock_items_reserved_lte_on_hand"
    add_check_constraint :stock_items, "reorder_point >= 0",
                         name: "stock_items_reorder_point_non_negative"
    add_check_constraint :stock_items, "maximum_level IS NULL OR maximum_level >= reorder_point",
                         name: "stock_items_max_gte_reorder"
  end
end
