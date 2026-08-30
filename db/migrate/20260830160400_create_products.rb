# frozen_string_literal: true

# ==============================================================================
# Productos (el catálogo). OJO: acá NO vive la cantidad.
#
# Decisión de diseño clave, y de las que más se preguntan en entrevistas:
# la cantidad NO es un atributo del producto. Un producto existe en N depósitos
# con N cantidades distintas. La cantidad vive en `stock_items` (producto x
# depósito). Meter `quantity` en `products` es el error de modelado #1 en este
# dominio y te bloquea multi-depósito para siempre.
# ==============================================================================
class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.citext :sku, null: false
      t.string :name, null: false
      t.text :description
      t.string :barcode

      t.references :category, foreign_key: { on_delete: :restrict }

      t.string :unit, null: false, default: "unit"

      # DINERO EN ENTEROS. Nunca float/double para plata: 0.1 + 0.2 != 0.3 en
      # binario IEEE-754. Dos opciones válidas:
      #   a) NUMERIC/decimal en la base + BigDecimal en Ruby (exacto, más lento)
      #   b) bigint de centavos (exacto, rapidísimo, obliga a un Value Object)
      # Elegimos (b) y encapsulamos en app/models/value_objects/money.rb, que es
      # lo que hace Stripe. bigint aguanta ~92 billones de centavos.
      t.bigint :cost_cents, null: false, default: 0
      t.bigint :price_cents, null: false, default: 0
      t.string :currency, null: false, default: "USD"

      t.decimal :weight_grams, precision: 12, scale: 3

      t.boolean :active, null: false, default: true

      # SOFT DELETE. En un sistema de stock no podés borrar de verdad un
      # producto: sus movimientos históricos lo referencian. Marcamos y filtramos.
      t.datetime :discarded_at

      # OPTIMISTIC LOCKING. Rails reconoce la columna `lock_version` por
      # convención: cada UPDATE agrega `AND lock_version = N` al WHERE e
      # incrementa. Si otro proceso ya la tocó, 0 filas afectadas =>
      # ActiveRecord::StaleObjectError. Es EXACTAMENTE @Version de JPA/Hibernate.
      t.integer :lock_version, null: false, default: 0

      t.jsonb :attributes_data, null: false, default: {}

      t.timestamps
    end

    add_index :products, :sku, unique: true
    add_index :products, :barcode, where: "barcode IS NOT NULL"

    # Índice trigram para `WHERE name ILIKE '%tornillo%'`.
    add_index :products, :name, using: :gin, opclass: :gin_trgm_ops,
              name: "index_products_on_name_trgm"

    # Índice compuesto parcial: el 99% de las listas piden productos vivos de
    # una categoría, ordenados por nombre. Este índice sirve el WHERE y el
    # ORDER BY al mismo tiempo (evita el Sort en el plan).
    add_index :products, [ :category_id, :name ],
              where: "discarded_at IS NULL AND active",
              name: "index_products_active_by_category"

    add_check_constraint :products,
                         "unit IN ('unit', 'kg', 'g', 'l', 'ml', 'm', 'cm', 'box', 'pallet')",
                         name: "products_unit_check"
    add_check_constraint :products, "cost_cents >= 0", name: "products_cost_check"
    add_check_constraint :products, "price_cents >= 0", name: "products_price_check"
    add_check_constraint :products, "char_length(currency) = 3", name: "products_currency_check"
  end
end
