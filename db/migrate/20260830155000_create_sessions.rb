# frozen_string_literal: true

class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      # `t.references` crea user_id + índice + FK.
      # on_delete: :cascade -> si se borra el usuario, se van sus sesiones.
      # Sin la FK, la integridad referencial quedaría solamente en Rails
      # (`dependent: :destroy`), que NO aplica a deletes hechos por SQL directo.
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :ip_address
      t.string :user_agent
      t.datetime :expires_at

      t.timestamps
    end

    # Índice parcial: sólo indexa las filas que nos interesan (sesiones vivas).
    # Es más chico, entra mejor en memoria y se actualiza menos. Postgres lo usa
    # sólo si el WHERE de tu query implica el predicado del índice.
    add_index :sessions, :expires_at, where: "expires_at IS NOT NULL"
  end
end
