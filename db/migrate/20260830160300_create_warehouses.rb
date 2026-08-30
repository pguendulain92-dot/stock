# frozen_string_literal: true

class CreateWarehouses < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouses do |t|
      t.citext :code, null: false            # "BA-01"
      t.string :name, null: false
      t.text :address
      t.string :timezone, null: false, default: "UTC"
      t.boolean :active, null: false, default: true

      # Un depósito "virtual" (ej: mercadería en tránsito, mercadería dañada).
      # Modelar el tránsito como un depósito hace que la ecuación contable
      # cierre siempre: la suma de todo el stock es constante en un transfer.
      t.boolean :virtual, null: false, default: false

      t.timestamps
    end

    add_index :warehouses, :code, unique: true
    add_index :warehouses, :active, where: "active"
  end
end
