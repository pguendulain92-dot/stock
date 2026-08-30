# frozen_string_literal: true

# ==============================================================================
# TIMESTAMPTZ POR DEFECTO
#
# Por razones históricas, Rails crea columnas `timestamp` (SIN zona horaria) en
# PostgreSQL. Eso significa que la base guarda "2026-08-30 15:00:00" y NO sabe
# de qué zona es. Rails "arregla" el problema convirtiendo todo a UTC antes de
# escribir... siempre y cuando la escritura pase por Rails.
#
# ¿Por qué es un problema real?
#   * Un `psql` a mano, un dashboard de BI, un job de Python o una réplica
#     lógica NO saben la convención. Comparan naive con naive y se equivocan.
#   * `now()` de Postgres devuelve timestamptz; compararlo con una columna
#     timestamp fuerza una conversión implícita usando el TimeZone de la sesión,
#     lo cual (a) puede dar mal, y (b) puede INVALIDAR EL USO DEL ÍNDICE.
#   * El horario de verano (DST) es imposible de resolver sin la zona.
#
# `timestamptz` guarda un instante absoluto (microsegundos desde la época, en
# UTC) y lo renderiza en la zona que pidas. Es lo que querés el 99% de las
# veces — el equivalente a Instant/OffsetDateTime de Java, en vez de
# LocalDateTime.
#
# Contra-caso: si querés guardar "las 9 de la mañana HORA LOCAL DE CADA SUCURSAL",
# ahí sí querés un timestamp naive + la zona en otra columna. Es raro.
#
# Ojo: esto sólo afecta a las columnas NUEVAS. Cambiar columnas existentes
# requiere una migración con USING (ver docs/03 §migraciones seguras).
# ==============================================================================
ActiveSupport.on_load(:active_record_postgresqladapter) do
  self.datetime_type = :timestamptz
end
