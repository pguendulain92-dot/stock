# frozen_string_literal: true

class CreateSuppliers < ActiveRecord::Migration[8.1]
  def change
    create_table :suppliers do |t|
      t.string :name, null: false
      t.citext :tax_id, null: false          # CUIT / RUT / VAT number
      t.citext :email
      t.string :phone
      t.text :address
      t.integer :default_lead_time_days, null: false, default: 7
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :suppliers, :tax_id, unique: true

    # GIN sobre jsonb: habilita `metadata @> '{"tier": "gold"}'` con índice.
    # jsonb_path_ops es más chico y rápido si SÓLO usás el operador @>.
    add_index :suppliers, :metadata, using: :gin, opclass: :jsonb_path_ops

    # Índice trigram para búsqueda por nombre con ILIKE '%algo%'.
    add_index :suppliers, :name, using: :gin, opclass: :gin_trgm_ops,
              name: "index_suppliers_on_name_trgm"

    add_check_constraint :suppliers,
                         "default_lead_time_days >= 0",
                         name: "suppliers_lead_time_check"
  end
end
