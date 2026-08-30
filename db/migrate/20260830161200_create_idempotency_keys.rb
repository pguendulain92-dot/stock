# frozen_string_literal: true

# ==============================================================================
# Claves de idempotencia a nivel HTTP (estilo Stripe).
#
# Distinto de la columna `idempotency_key` de stock_movements: ESTO cachea la
# RESPUESTA COMPLETA de un POST, así un reintento devuelve exactamente el mismo
# status + body sin volver a ejecutar nada.
#
# Flujo:
#   1. Llega POST con header `Idempotency-Key: abc`.
#   2. INSERT de la fila en estado 'processing'. Si el UNIQUE explota:
#        - si la fila existente está 'completed' -> devolvemos la respuesta guardada
#        - si está 'processing'                  -> 409 Conflict (request en vuelo)
#   3. Ejecutamos, guardamos status/body, marcamos 'completed'.
#
# El `request_fingerprint` (hash del body) evita el abuso más peligroso:
# reusar la misma clave con un body DISTINTO. Si el fingerprint no coincide,
# devolvemos 422: la clave ya se usó para otra cosa.
# ==============================================================================
class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys do |t|
      t.string :key, null: false
      t.references :user, foreign_key: { on_delete: :cascade }
      t.string :request_path, null: false
      t.string :request_method, null: false
      t.string :request_fingerprint, null: false   # SHA-256 del body

      t.string :status, null: false, default: "processing"
      t.integer :response_status
      t.jsonb :response_body

      t.datetime :expires_at, null: false
      t.timestamps
    end

    # Scoping por usuario: la clave "abc" del usuario 1 no colisiona con la
    # "abc" del usuario 2. Sin esto, un cliente puede envenenar la cache de otro.
    add_index :idempotency_keys, [ :user_id, :key ], unique: true
    add_index :idempotency_keys, :expires_at

    add_check_constraint :idempotency_keys,
                         "status IN ('processing', 'completed', 'failed')",
                         name: "idempotency_keys_status_check"
  end
end
