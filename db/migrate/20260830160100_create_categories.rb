# frozen_string_literal: true

# ==============================================================================
# Categorías con jerarquía (auto-referencia).
#
# Tres formas clásicas de modelar árboles en SQL:
#  1) Adjacency list (parent_id)  -> lo que usamos. Simple, escritura barata,
#     lectura recursiva (Postgres: WITH RECURSIVE).
#  2) Materialized path ("1/4/9") -> lectura de subárbol con un LIKE 'prefijo%'
#     e índice; escritura cara al mover un nodo.
#  3) Nested sets (lft/rgt)       -> lecturas rapidísimas, escrituras horribles.
#
# Acá hacemos un híbrido: parent_id (fuente de verdad) + `path` materializado
# como caché denormalizado para poder traer subárboles con UN índice.
# En docs/03 está la query WITH RECURSIVE equivalente.
# ==============================================================================
class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :categories do |t|
      t.string :name, null: false
      t.citext :slug, null: false
      t.text :description

      # FK a sí misma. Nullable => las raíces tienen parent_id NULL.
      # on_delete: :restrict => no te deja borrar una categoría con hijos.
      t.references :parent, foreign_key: { to_table: :categories, on_delete: :restrict }

      t.string :path, null: false, default: ""  # ej: "herramientas/manuales"
      t.integer :depth, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :categories, :slug, unique: true
    add_index :categories, :path
    add_check_constraint :categories, "depth >= 0 AND depth <= 5", name: "categories_depth_check"
  end
end
