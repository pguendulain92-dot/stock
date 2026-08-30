# frozen_string_literal: true

# ==============================================================================
# strong_migrations — te impide escribir una migración que tumbe producción.
#
# EL PROBLEMA QUE RESUELVE: en Postgres, muchas operaciones de DDL toman un
# ACCESS EXCLUSIVE lock sobre la tabla. Ese lock bloquea hasta los SELECT.
# En una tabla chica dura milisegundos y no te enterás; en una tabla de 50
# millones de filas puede durar minutos, y durante esos minutos TU APP ESTÁ
# CAÍDA. Peor todavía: el lock se ENCOLA, así que una migración que espera un
# lock deja atrás suyo una fila de queries esperando, y el sitio se cae ANTES
# de que la migración empiece siquiera.
#
# Esta gema conoce el catálogo de operaciones peligrosas y te frena en
# desarrollo, con el reemplazo seguro escrito en el mensaje de error.
#
# LAS OPERACIONES QUE MÁS SE CANTAN EN UNA ENTREVISTA:
#
#   ❌ add_index :products, :sku
#   ✅ add_index :products, :sku, algorithm: :concurrently   (+ disable_ddl_transaction!)
#      Un CREATE INDEX normal bloquea las ESCRITURAS toda la construcción.
#      CONCURRENTLY no bloquea, pero tarda el doble, no puede correr dentro de
#      una transacción y puede dejar un índice INVÁLIDO si falla (hay que
#      borrarlo y rehacerlo).
#
#   ❌ change_column_null :products, :sku, false
#   ✅ agregar un CHECK NOT VALID, validarlo aparte, y recién ahí el NOT NULL.
#      El NOT NULL directo escanea la tabla entera con un lock exclusivo.
#
#   ❌ remove_column                    (el código viejo sigue seleccionándola)
#   ✅ ignored_columns primero, deploy, y recién después el remove_column.
#
#   ❌ rename_column / rename_table     (rompe el código que está corriendo)
#   ✅ EXPAND-CONTRACT: columna nueva -> escribir en las dos -> backfill ->
#      leer de la nueva -> borrar la vieja. Cuatro deploys, cero downtime.
#
#   ❌ backfill con Modelo.update_all en la misma migración que el DDL
#   ✅ una migración aparte, en lotes, sin transacción envolvente.
#
#   ❌ change_column :products, :price_cents, :bigint
#      Reescribe la tabla entera con lock exclusivo.
#
# `start_after` es CLAVE al instalar la gema en un proyecto que ya existe: sin
# esto, la gema analiza también las migraciones VIEJAS (que ya corrieron) y no
# te deja bootear. Se pone el timestamp de la última migración existente.
# ==============================================================================

# Analizar sólo las migraciones creadas de acá en adelante.
StrongMigrations.start_after = 20260830161300

# La versión de Postgres de PRODUCCIÓN, no la de tu máquina. La gema usa este
# dato para decidir qué es seguro: por ejemplo, `add_column` con default es
# instantáneo desde Postgres 11, pero reescribe la tabla en versiones anteriores.
StrongMigrations.target_version = ENV.fetch("PG_TARGET_VERSION", 16)

# Cuánto puede esperar una migración por un lock antes de rendirse.
# ESTO ES LO QUE EVITA LA CAÍDA EN CASCADA: si la migración no consigue el lock
# en 10 segundos, aborta en vez de quedarse encolada bloqueando a todos los que
# vienen atrás. Reintentás más tarde y listo.
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour

# Avisar también cuando el lock_timeout de la sesión sea demasiado alto.
StrongMigrations.lock_timeout_limit = 10.seconds
