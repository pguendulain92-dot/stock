# frozen_string_literal: true

# Tabla de unión CON ATRIBUTOS PROPIOS (precio, lead time, sku del proveedor).
# En Rails: si la join table tiene atributos, es un modelo de primera clase y
# se usa `has_many :through`. `has_and_belongs_to_many` (sin modelo) sólo sirve
# para joins puras sin atributos — y casi siempre terminás necesitando atributos.
class CreateProductSuppliers < ActiveRecord::Migration[8.1]
  def change
    create_table :product_suppliers do |t|
      # index: false: los dos índices de abajo tienen product_id como prefijo.
      t.references :product, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }
      t.string :supplier_sku
      t.bigint :cost_cents, null: false, default: 0
      t.string :currency, null: false, default: "USD"
      t.integer :lead_time_days, null: false, default: 7
      t.integer :minimum_order_quantity, null: false, default: 1
      t.boolean :preferred, null: false, default: false

      t.timestamps
    end

    # Clave natural compuesta: un proveedor no puede figurar dos veces para el
    # mismo producto. Esto SIEMPRE va en la base, no sólo en `validates_uniqueness_of`,
    # que tiene una race condition clásica (dos requests validan a la vez, las
    # dos ven "libre", las dos insertan). Ver docs/10 §uniqueness.
    add_index :product_suppliers, [ :product_id, :supplier_id ], unique: true

    # Índice único PARCIAL: como mucho UN proveedor preferido por producto.
    # Este truco (unique + where) es imposible de expresar con validaciones de
    # Rails y es una respuesta que impresiona en entrevistas.
    add_index :product_suppliers, :product_id,
              unique: true, where: "preferred",
              name: "index_one_preferred_supplier_per_product"
  end
end
