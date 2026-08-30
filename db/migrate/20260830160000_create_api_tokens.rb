# frozen_string_literal: true

# ==============================================================================
# Tokens de API (autenticación máquina-a-máquina).
#
# REGLA DE ORO: nunca guardes el token en claro. Guardás un DIGEST (SHA-256).
# Si te filtran la base, los tokens siguen siendo inútiles.
#
# ¿Por qué SHA-256 y no bcrypt como con los passwords?
#  - bcrypt es LENTO A PROPÓSITO (para frenar fuerza bruta sobre passwords
#    humanos, que tienen poca entropía).
#  - Un token que generamos nosotros tiene 256 bits de entropía real: no hay
#    fuerza bruta posible. Y como se valida en CADA request de la API, un
#    bcrypt de 100ms te destruiría el throughput.
#  => Passwords humanos: bcrypt/argon2. Tokens aleatorios largos: SHA-256.
# ==============================================================================
class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false   # primeros 8 chars, para mostrar en la UI

      # Array nativo de Postgres. Rails lo mapea a un Array de Ruby.
      # Alternativas: tabla join (normalizado, joins caros) o jsonb (más
      # flexible, menos tipado). Para una lista corta y fija, el array gana.
      t.string :scopes, array: true, null: false, default: []

      t.datetime :last_used_at
      t.datetime :expires_at
      t.datetime :revoked_at
      t.integer :requests_count, null: false, default: 0

      t.timestamps
    end

    add_index :api_tokens, :token_digest, unique: true

    # Índice GIN sobre el array: permite `WHERE scopes @> ARRAY['stock:write']`
    # con índice. Un B-tree no sirve para "contiene".
    add_index :api_tokens, :scopes, using: :gin

    # Sólo los tokens vivos nos importan para listados.
    add_index :api_tokens, [ :user_id, :created_at ], where: "revoked_at IS NULL"
  end
end
