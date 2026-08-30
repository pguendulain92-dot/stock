# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      # citext: el índice unique de abajo ya es case-insensitive.
      t.citext :email_address, null: false
      t.string :password_digest, null: false
      t.string :name, null: false, default: ""

      # ¿Por qué string y no integer para el rol?
      # Rails permite `enum role: { admin: 0, ... }` con backing entero: ocupa
      # menos y es más rápido, PERO si alguien reordena las claves en el modelo,
      # TODOS los datos históricos cambian de significado en silencio. Es el bug
      # más caro y más silencioso de Rails. Con string, la base es
      # auto-documentada (`SELECT role FROM users` se lee solo) y el CHECK de
      # abajo impide valores inventados. Ver docs/10 §enums.
      t.string :role, null: false, default: "operator"

      t.boolean :active, null: false, default: true
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :users, :email_address, unique: true

    # Defensa en profundidad: aunque el modelo tenga una validación de Rails,
    # un `update_column`, un seed, una migración de datos o un psql a mano se
    # las saltan todas. El CHECK vive en la base y no se lo saltea NADIE.
    add_check_constraint :users,
                         "role IN ('admin', 'manager', 'operator', 'viewer')",
                         name: "users_role_check"
  end
end
