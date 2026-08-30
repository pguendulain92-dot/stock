# frozen_string_literal: true

# ==============================================================================
# Extensiones de PostgreSQL.
#
# En Java te acostumbraste a que la base sea "tonta" y toda la lógica viva en la
# JVM. En el mundo Rails/Postgres es al revés: la base es una herramienta rica y
# la usamos a fondo. Estas tres extensiones aparecen todo el tiempo:
#
#  * citext   -> tipo texto case-insensitive. Un índice UNIQUE sobre citext hace
#               que 'ABC-1' y 'abc-1' colisionen. Sin esto tenés que recordar
#               hacer .downcase en TODOS los caminos de escritura (y alguien se
#               va a olvidar). Es una invariante que conviene bajar a la base.
#
#  * pg_trgm  -> índices por trigramas. Permite que `name ILIKE '%tornillo%'`
#               use un índice GIN en vez de hacer Seq Scan. Sin esto, la
#               búsqueda por substring escanea la tabla entera. Ver docs/04.
#
#  * btree_gin-> deja combinar columnas escalares (ej. category_id) con
#               columnas GIN (ej. trigramas) en un mismo índice compuesto.
#
# NOTA: CREATE EXTENSION requiere permisos de superusuario en Postgres. En
# servicios gestionados (RDS, Cloud SQL) hay una allow-list de extensiones.
# ==============================================================================
class EnablePostgresExtensions < ActiveRecord::Migration[8.1]
  def change
    enable_extension "citext"
    enable_extension "pg_trgm"
    enable_extension "btree_gin"
  end
end
