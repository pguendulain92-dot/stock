# frozen_string_literal: true

# ==============================================================================
# Contadores correlativos SIN HUECOS.
#
# Necesitamos referencias legibles tipo "PO-2026-000045". Hay tres formas:
#
# 1) `count + 1` en Ruby.  ❌ ROTO. Dos requests concurrentes leen el mismo
#    count y generan la misma referencia. Race condition de manual.
#
# 2) SEQUENCE de Postgres (`nextval`). ✅ Rapidísima, no bloquea, escala.
#    PERO: nextval NO se revierte en un rollback, así que DEJA HUECOS
#    (1, 2, 5, 6...). Para un ID interno da igual. Para un comprobante fiscal
#    en varios países es ilegal. Además, `db/schema.rb` NO SABE representar una
#    sequence suelta: si la creás con `execute`, desaparece al hacer
#    `db:schema:load` y tu base de test queda sin ella. (Esa limitación es
#    justo la razón por la que muchos equipos pasan a `structure.sql`.
#    Ver docs/03 §schema.rb vs structure.sql.)
#
# 3) Tabla de contadores con `UPDATE ... RETURNING`. ✅ Es lo que usamos.
#    `UPDATE counters SET value = value + 1 WHERE key = ? RETURNING value`
#    es UNA sola sentencia: Postgres bloquea la fila, incrementa y devuelve,
#    todo atómico. Como vive dentro de tu transacción, un rollback también
#    revierte el número => SIN HUECOS.
#    El costo: serializa a los que piden el MISMO contador (se hacen cola en la
#    fila). Como usamos un contador por (tipo, año), la contención es aceptable
#    y es el precio inevitable de la numeración sin huecos.
# ==============================================================================
class CreateSequenceCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :sequence_counters, primary_key: :key, id: :string do |t|
      t.bigint :value, null: false, default: 0
      t.timestamps
    end

    add_check_constraint :sequence_counters, "value >= 0", name: "sequence_counters_value_non_negative"
  end
end
