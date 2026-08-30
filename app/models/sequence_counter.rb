# frozen_string_literal: true

# Ver el comentario largo en la migración correspondiente.
class SequenceCounter < ApplicationRecord
  self.primary_key = "key"

  validates :key, presence: true

  class << self
    # Devuelve el siguiente valor de forma atómica.
    #
    # `UPSERT` (INSERT ... ON CONFLICT DO UPDATE ... RETURNING) resuelve en UNA
    # sentencia los dos casos: crear el contador si no existe e incrementarlo si
    # ya existe. Sin el ON CONFLICT tendrías que hacer find_or_create + update,
    # que son dos round-trips y una race condition.
    def next_value(key)
      sql = sanitize_sql_array([ <<~SQL.squish, key ])
        INSERT INTO sequence_counters (key, value, created_at, updated_at)
        VALUES (?, 1, NOW(), NOW())
        ON CONFLICT (key) DO UPDATE
          SET value = sequence_counters.value + 1, updated_at = NOW()
        RETURNING value
      SQL

      # ┌──────────────────────────────────────────────────────────────────────┐
      # │ TRAMPA REAL, y de las que más cuesta encontrar.                      │
      # │                                                                      │
      # │ Rails tiene un QUERY CACHE por request/por bloque de ejecución: si   │
      # │ hacés dos veces el MISMO SELECT con los MISMOS binds, la segunda no  │
      # │ va a la base, devuelve el resultado memorizado.                      │
      # │                                                                      │
      # │ El cache se invalida solo cuando Rails SABE que escribiste, y lo     │
      # │ sabe porque pasaste por exec_insert / exec_update / exec_delete.     │
      # │ Nuestro INSERT ... RETURNING lo ejecutamos con `select_value`, o     │
      # │ sea que para Rails ES UN SELECT. Consecuencia:                       │
      # │                                                                      │
      # │   next_value("PO:2026")  # => 1   (va a la base)                     │
      # │   next_value("PO:2026")  # => 1   (¡CACHE! nunca tocó la base)       │
      # │                                                                      │
      # │ ...y te quedás con dos comprobantes con el mismo número. Este bug    │
      # │ NO aparece en un test unitario suelto (el cache está apagado fuera   │
      # │ del executor) y sí en producción. Ver docs/10 §query-cache.          │
      # │                                                                      │
      # │ Arreglo: `uncached` para esta sentencia y `clear_query_cache` para   │
      # │ que nadie lea un `sequence_counters` viejo después de escribir.      │
      # └──────────────────────────────────────────────────────────────────────┘
      value = connection.uncached { connection.select_value(sql) }
      connection.clear_query_cache
      value.to_i
    end

    # "PO-2026-000045"
    def next_reference(prefix, year: Date.current.year, width: 6)
      value = next_value("#{prefix}:#{year}")
      "#{prefix}-#{year}-#{value.to_s.rjust(width, '0')}"
    end
  end
end
