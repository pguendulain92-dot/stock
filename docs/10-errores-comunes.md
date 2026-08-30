# Errores comunes que rompen en producción

Este es el catálogo. No es una lista de "buenas prácticas": es la lista de cosas
que **ya rompieron**, acá o en cualquier app Rails de tamaño mediano, con el
síntoma exacto que vas a ver en el log, la razón técnica, el código malo, el
código bueno y cómo detectarlo *antes* de que llegue a producción.

Está escrito para alguien que viene de Java/Spring. En cada entrada marco dónde
la analogía con JPA/Hibernate/Spring **sirve** y —más importante— dónde **se
rompe**, porque justamente ahí es donde se cometen los errores: cuando aplicás
un modelo mental que funcionaba y acá no aplica.

Los bugs marcados **[BUG REAL]** son bugs que efectivamente tuvimos en este
repositorio, con su test de regresión. Los reproduje corriendo el código antes
de escribir esta página; donde hay salida de consola, es salida real.

**Formato de cada entrada**: síntoma → por qué pasa → mal → bien → cómo detectarlo.

---

## Índice

| # | Tema | Gravedad típica |
|---|------|-----------------|
| 1 | [N+1 queries: las cuatro variantes](#1-n1-queries-las-cuatro-variantes) | Latencia, timeouts |
| 2 | [`default_scope`](#2-default_scope-casi-nunca) | Datos "desaparecidos" |
| 3 | [Índices que no se usan](#3-índices-que-no-se-usan) | Seq Scan silencioso |
| 4 | [`validates_uniqueness_of` sin índice único](#4-uniqueness-validates_uniqueness_of-sin-índice-único) | Duplicados |
| 5 | [`find_or_create_by` bajo concurrencia](#5-find_or_create_by-find_or_create_by-bajo-concurrencia) | 500 intermitente |
| 6 | [El query cache y el `INSERT ... RETURNING`](#6-query-cache-el-query-cache-cacheando-un-insert--returning-bug-real) | **Corrupción de datos** |
| 7 | [Transacciones: `return`, `Rollback` anidado](#7-transacciones-return-dentro-de-transaction-y-rollback-anidado) | Commits parciales |
| 8 | [Callbacks: `after_save` vs `after_commit`](#8-callbacks-after_save-vs-after_commit) | Efectos fantasma |
| 9 | [Anclas de regex `^` `$`](#9-las-anclas-de-regex-en-ruby--y--son-de-línea) | **Vulnerabilidad** |
| 10 | [`"false"` es truthy](#10-false-es-truthy-y-los-params-llegan-como-string) | Filtros invertidos |
| 11 | [`to_i` vs `Integer()`](#11-to_i-devuelve-0-en-silencio-integer-explota) | Datos basura |
| 12 | [`nil` y `false`, los únicos falsy](#12-nil-y-false-son-los-únicos-valores-falsy-de-ruby) | Lógica invertida |
| 13 | [Float para dinero](#13-float-para-dinero) | Balances que no cierran |
| 14 | [Mass assignment](#14-mass-assignment-y-strong-parameters) | **Escalada de privilegios** |
| 15 | [Enums con backing entero](#15-enums-enums-con-backing-entero-y-el-reordenamiento-silencioso) | **Corrupción histórica** |
| 16 | [`update_attribute` / `update_column`](#16-update_attribute-y-update_column-saltean-cosas-distintas) | Datos inválidos |
| 17 | [Los valores de `dependent:`](#17-los-valores-de-dependent-y-los-que-borran-lo-que-no-querías) | **Pérdida de datos** |
| 18 | [Métodos reservados de ActionController](#18-métodos-reservados-de-actioncontroller-bug-real) | 500 en todo el controller |
| 19 | [`after_action only:` a acción inexistente](#19-after_action-only-apuntando-a-una-acción-inexistente-bug-real) | 500 en todo el controller |
| 20 | [Timezones](#20-timezones-timenow-timecurrent-datetoday-timestamptz) | Reportes con un día de corrimiento |
| 21 | [Memoria: Puma y cargar todo](#21-memoria-puma-y-cargar-todos-los-registros) | OOM kill |
| 22 | [Migraciones que toman locks](#22-migraciones-que-toman-locks-y-tumban-producción) | **Downtime total** |
| 23 | [Secretos](#23-secretos-en-el-repo-en-los-logs-y-en-los-mensajes-de-error) | **Fuga** |
| 24 | [Cache keys incompletas](#24-cache-keys-incompletas) | Datos de otro usuario |
| 25 | [Jobs con un objeto viejo](#25-un-job-con-un-objeto-serializado-viejo) | Sobreescrituras |
| 26 | [Zeitwerk](#26-zeitwerk-nombre-de-archivo-vs-constante) | NameError al bootear |
| 27 | [Autoload en dev vs eager load en prod](#27-autoload-en-dev-vs-eager-load-en-prod-anda-en-dev-falla-en-prod) | Falla sólo en prod |
| 28 | [Rate limiting mal discriminado](#28-rate-limiting-mal-discriminado-dos-bugs-reales-de-configuración) | Límite que corta a la mitad, o que no corta |

---

## 1. N+1 queries: las cuatro variantes

Todo el mundo conoce la primera. Las otras tres son las que efectivamente
llegan a producción, porque `includes` **no** las arregla.

Los números de abajo salieron de correr esto contra la base de desarrollo real
(15 productos, 4 depósitos, 48 `stock_items`, 105 movimientos), contando las
queries con `ActiveSupport::Notifications.subscribe("sql.active_record")`.

### Variante A — N+1 de asociación (el clásico)

**Síntoma**: el endpoint tarda 3 segundos; el log muestra 200 líneas
`Category Load (0.2ms) SELECT ... WHERE id = $1` idénticas salvo el id.

```ruby
# ❌ 6 queries para 5 productos (1 + N)
Product.limit(5).each { |p| p.category&.name }

# ✅ 2 queries, siempre, para cualquier N
Product.includes(:category).limit(5).each { |p| p.category&.name }
```

**De dónde viene**: ActiveRecord es lazy por asociación, como Hibernate con
`FetchType.LAZY`. La diferencia que te muerde: en JPA, fuera de la sesión te
saltaba `LazyInitializationException` — un error **ruidoso**. En ActiveRecord no
hay sesión: la asociación se carga cuando la tocás, siempre, desde donde sea. El
N+1 no falla, sólo es lento. Es un problema de *performance*, nunca de
*corrección*, y por eso nadie lo nota hasta que hay volumen.

### Variante B — N+1 de agregación (`includes` NO lo arregla)

**Síntoma**: hiciste `includes` y el N+1 sigue ahí.

```ruby
# ❌ 6 queries: `sum` sobre la asociación es una query agregada por producto
Product.limit(5).each { |p| p.stock_items.sum(:quantity_on_hand) }

# ❌ 7 queries: includes carga la asociación, PERO `.sum(:columna)` la ignora
#    y vuelve a ir a la base. Es peor que no hacer includes.
Product.includes(:stock_items).limit(5).each { |p| p.stock_items.sum(:quantity_on_hand) }

# ~ 2 queries pero trae TODAS las filas a memoria (`sum` con BLOQUE suma en Ruby)
Product.includes(:stock_items).limit(5).each { |p| p.stock_items.sum(&:quantity_on_hand) }

# ✅ 2 queries y cero filas materializadas: un GROUP BY
StockItems::Availability.call(product_ids: ids)
```

La regla exacta: `relation.sum(:columna)` **siempre** emite SQL. `array.sum(&:x)`
suma en Ruby sobre lo ya cargado. Con `includes`, la segunda forma no agrega
queries pero sí memoria; para 500 items por producto, la diferencia es real.

La solución del repo es `app/queries/stock_items/availability.rb:23`, un query
object que resuelve la disponibilidad de toda la página con **un** `GROUP BY` y
devuelve un `Hash` liviano vía `pluck`, sin instanciar modelos:

```ruby
relation.group(:product_id).pluck(
  :product_id,
  Arel.sql("SUM(quantity_on_hand)"),
  Arel.sql("SUM(quantity_reserved)"),
  Arel.sql("SUM(quantity_available)")
)
```

El resultado se le pasa **por parámetro** al serializer
(`app/serializers/product_serializer.rb:23`), justamente para que el serializer
no tenga forma de disparar una query.

### Variante C — N+1 en profundidad y con polimorfismo

**Síntoma**: hiciste `includes(:stock_items)` y ahora el N+1 está un nivel más
abajo, en `stock_item.warehouse`.

```ruby
# ❌ resuelve un nivel, deja el siguiente colgado
Product.includes(:stock_items).each { |p| p.stock_items.each { |i| i.warehouse.code } }

# ✅ el hash anidado precarga los dos niveles
Product.includes(:category, stock_items: :warehouse)
```

Eso es exactamente lo que hace el scope `with_associations` de
`app/models/product.rb:60`. Todos los modelos del repo tienen uno, para que el
controller no tenga que acordarse del grafo.

El caso polimórfico tiene una limitación dura: `StockMovement#reference` es
`belongs_to :reference, polymorphic: true`
(`app/models/stock_movement.rb:19`). Podés hacer `includes(:reference)` —
ActiveRecord agrupa por `reference_type` y hace una query por tipo—, pero **no**
podés precargar algo *adentro* de un polimórfico (`includes(reference: :lines)`)
porque no todos los tipos tienen esa asociación. Ahí la respuesta es cargar por
tipo a mano, o denormalizar lo que necesitás mostrar.

### Variante D — el N+1 invisible: `count` / `exists?` / `size` dentro del render

**Síntoma**: la lista está bien, pero cada fila hace un `SELECT COUNT(*)`.

```ruby
# ❌ una query por fila, incluso con includes
products.each { |p| p.stock_items.count }

# ❌ una query por fila
products.each { |p| p.stock_items.exists?(warehouse_id: id) }

# ✅ `size` NO va a la base si la asociación ya está cargada
Product.includes(:stock_items).each { |p| p.stock_items.size }
```

La tabla que conviene memorizar:

| Método | Asociación NO cargada | Asociación YA cargada |
|--------|----------------------|----------------------|
| `.count` | `SELECT COUNT(*)` | `SELECT COUNT(*)` (igual va a la base) |
| `.length` | carga TODO y cuenta | cuenta en memoria |
| `.size` | `SELECT COUNT(*)` | cuenta en memoria ✅ |

Por eso en una vista se usa `size`. Es el equivalente al `collection.size()` de
Hibernate sobre una colección ya inicializada, con la misma trampa: si no está
inicializada, sale a la base.

### El problema inverso: eager loading no usado

`includes(:category)` y después no tocás `category`: pagaste una query y la
memoria de N categorías para nada. Bullet lo detecta con
`Bullet.unused_eager_loading_enable = true` (`spec/support/bullet.rb:24`).

### Cómo detectarlo antes

- **Bullet en test con `raise = true`** (`spec/support/bullet.rb:20`): un N+1
  detectado **rompe el test**. Se activa sólo en los ejemplos marcados
  `:n_plus_one`, para no generar falsos positivos en specs unitarios donde el
  N+1 es intencional. Es el equivalente a un assert de arquitectura.
- `config.active_record.verbose_query_logs = true` en desarrollo
  (`config/environments/development.rb:55`) te dice **qué línea de tu código**
  originó cada query.
- `rack-mini-profiler` te muestra el desglose SQL por request en el browser.
- La regla de revisión de código: cualquier `.each` sobre registros que adentro
  toque una asociación necesita `includes` o un query object.

---

## 2. `default_scope`: casi nunca

**Síntoma**: `Product.count` devuelve 12 pero en `psql` hay 15. Un `JOIN` desde
otra tabla trae menos filas de las que deberían. Un `find(id)` tira
`RecordNotFound` sobre un id que existe.

**Por qué**: `default_scope` se aplica a **todo**: `find`, `count`, las
asociaciones (`user.products`), los joins, las subconsultas y —la peor— la
**creación**: un `default_scope { where(active: true) }` hace que
`Product.new.active` sea `true` sin que vos lo pidas.

```ruby
# ❌ La tentación en un modelo con soft delete
class Product < ApplicationRecord
  default_scope { where(discarded_at: nil) }
end

# ✅ Lo que hace este repo: scopes explícitos (app/models/concerns/discardable.rb:29)
module Discardable
  included do
    scope :kept,      -> { where(discarded_at: nil) }
    scope :discarded, -> { where.not(discarded_at: nil) }
  end
end
```

Un poco más de tipeo (`Product.kept`), cero sorpresas. Hay un test que fija la
decisión: `spec/models/product_spec.rb:93`, *"los scopes kept/discarded son
EXPLÍCITOS (no hay default_scope)"*.

**Comparación con Java**: el análogo es `@Where(clause = "discarded_at is null")`
de Hibernate, y tiene exactamente la misma mala fama por las mismas razones. La
diferencia es que `@Where` al menos no afecta a la construcción de entidades
nuevas; `default_scope` sí afecta a `new`/`create`.

### Cómo salir cuando ya lo pusiste

Esta es la parte que importa, porque sacarlo de un golpe rompe todo.

| Escape | Qué hace | Por qué duele |
|--------|----------|---------------|
| `unscoped` | saca **todos** los scopes | también te vuela el `order`, el `where` de la asociación y el scope del join. Casi nunca es lo que querés |
| `unscope(:where)` | saca sólo los `where` | saca **todos** los where, incluidos los tuyos |
| `unscope(where: :discarded_at)` | saca ese where puntual | ✅ es el bisturí, pero te obliga a conocer el nombre exacto de la columna |
| `Product.default_scoped` | vuelve a aplicarlo | útil dentro de un `unscoped do ... end` |
| `rewhere(...)` | reemplaza la condición | sirve para invertirla |

**Receta de migración segura**, en cuatro pasos y sin big bang:

1. Agregá el scope explícito (`kept`) **al lado** del `default_scope`.
2. Migrá los call sites de a poco a `kept`, con el `default_scope` todavía
   puesto (los dos where son idempotentes, no cambia nada).
3. Cuando ya no queden call sites que dependan implícitamente, sacá el
   `default_scope`.
4. Agregá el test que garantice que no vuelve.

**Cómo detectarlo antes**: `grep -rn "default_scope" app/` en el CI. En este
repo la única aparición es el comentario que explica por qué no lo usamos.

---

## 3. Índices que no se usan

**Síntoma**: creaste el índice, la query sigue lenta, `EXPLAIN` dice `Seq Scan`.

Hay tres causas distintas y se confunden todo el tiempo.

### a) La tabla es chica y Postgres tiene razón

```bash
$ psql -d stock_development -c "EXPLAIN (COSTS OFF) SELECT * FROM products WHERE sku = 'TOR-M5-20';"
 Seq Scan on products
   Filter: (sku = 'TOR-M5-20'::citext)
```

Con 15 filas, leer la tabla entera (1 página de disco) es más barato que bajar
por el índice. **No es un bug.** Si forzás la mano, el índice aparece:

```bash
$ psql -d stock_development -c "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT * FROM products WHERE sku = 'TOR-M5-20';"
 Index Scan using index_products_on_sku on products
   Index Cond: (sku = 'TOR-M5-20'::citext)
```

Moraleja: **nunca saques conclusiones de un `EXPLAIN` sobre datos de desarrollo.**
El plan depende de las estadísticas, y con 15 filas las estadísticas dicen otra
cosa que con 15 millones.

### b) Aplicaste una función a la columna indexada

Esto sí es un bug tuyo, y no se arregla con `enable_seqscan = off`:

```bash
$ psql -d stock_development -c "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT * FROM products WHERE lower(sku) = 'tor-m5-20';"
 Seq Scan on products
   Filter: (lower((sku)::text) = 'tor-m5-20'::text)
```

Sigue siendo Seq Scan **aunque le prohibí el seq scan**, porque el índice está
sobre `sku`, no sobre `lower(sku)`. Un índice B-tree indexa el valor exacto de
la expresión: cualquier función encima lo invalida.

Las tres soluciones:
- Índice funcional: `add_index :products, "lower(sku)"`.
- Tipo `citext` (lo que hace este repo, `db/migrate/20260830160400_create_products.rb:15`):
  la comparación ya es case-insensitive y el índice común sirve.
- Normalizar en la escritura: `normalizes :sku, with: ->(s) { s.to_s.strip.upcase }`
  (`app/models/product.rb:29`), y buscar siempre por el valor normalizado.

Variantes del mismo error: `WHERE created_at::date = '2026-08-30'` (castear la
columna), `WHERE id::text = ?` (comparar tipos distintos), `WHERE name ILIKE
'%tornillo%'` (el comodín inicial invalida el B-tree — para eso está el índice
GIN trigram de `db/migrate/20260830160400_create_products.rb:57`).

### c) El índice está pero nadie lo consulta (índice muerto)

El costo de un índice no usado no es cero: ocupa disco, hay que actualizarlo en
cada `INSERT`/`UPDATE`/`DELETE` y hace más lento el `VACUUM`. Se detectan así:

```sql
SELECT relname, indexrelname, idx_scan
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;
```

En esta base, con datos de seed y sin tráfico, casi todo está en `idx_scan = 0`
(es lo esperable). En producción, después de un mes de tráfico, todo lo que siga
en 0 y no sea un índice único de integridad es candidato a borrar.

Errores de creación de índices que ya están documentados en las migraciones de
este repo:

- **Índice duplicado por `t.references`**: `t.references` ya crea el índice de
  la FK. Agregar `add_index` sobre la misma columna tira `PG::DuplicateTable`, y
  si le cambiás el nombre te quedan dos índices idénticos frenando cada INSERT
  (`db/migrate/20260830160900_create_stock_transfers.rb:46`).
- **Índice redundante por prefijo izquierdo**: si tenés `(product_id,
  warehouse_id)`, el índice suelto sobre `product_id` sobra. Por eso las
  `references` de `stock_items` van con `index: false`
  (`db/migrate/20260830160600_create_stock_items.rb:29`).

**Cómo detectarlo antes**: `EXPLAIN (ANALYZE, BUFFERS)` contra una copia de
producción, no contra desarrollo. Y revisar `pg_stat_user_indexes` cada tanto.

---

## 4. `#uniqueness`: `validates_uniqueness_of` sin índice único

**Síntoma**: dos filas con el mismo SKU en una tabla que "no puede tener
duplicados". Suele aparecer después de un doble click, un retry del load
balancer o una importación paralela.

**Por qué**: `validates :sku, uniqueness: true` hace un `SELECT` y decide en
Ruby. Entre ese `SELECT` y el `INSERT` hay una ventana en la que otra
transacción puede haber insertado. La validación **no es atómica y no puede
serlo**: son dos sentencias distintas.

### El timeline exacto

```text
tiempo   Request A (conexión 1)              Request B (conexión 2)
------   ---------------------------------   ---------------------------------
  t0     BEGIN
  t1     SELECT 1 FROM products
           WHERE sku='ACME-1' LIMIT 1
           -> 0 filas   "libre"
  t2                                         BEGIN
  t3                                         SELECT 1 FROM products
                                               WHERE sku='ACME-1' LIMIT 1
                                               -> 0 filas   "libre"
  t4     INSERT ... 'ACME-1'
  t5     COMMIT
  t6                                         INSERT ... 'ACME-1'
  t7                                         COMMIT   <- duplicado
```

Ojo con el detalle: incluso en `SERIALIZABLE` de Postgres esto no se arregla
solo con la validación — se arregla porque Postgres aborta una de las dos con un
error de serialización, que igual tenés que rescatar. En `READ COMMITTED` (el
default de Rails y de Postgres) directamente pasan las dos.

**Lo comprobé** con dos hilos y dos conexiones reales contra esta base:

```text
resultados de dos INSERT concurrentes con el mismo SKU: ["OK", "ActiveRecord::RecordNotUnique"]
filas creadas: 1  <- el índice unico salvo la unicidad
```

Sin el índice único, `filas creadas` habría dado 2.

### El arreglo

```ruby
# ❌ SOLA, la validación es decorativa
validates :sku, uniqueness: true
```

```ruby
# ✅ Los dos, y cada uno cumple un rol distinto
# app/models/product.rb:48 — mensaje lindo para el formulario
validates :sku, presence: true, uniqueness: true, format: { ... }

# db/migrate/20260830160400_create_products.rb:53 — la garantía REAL
add_index :products, :sku, unique: true
```

Y en el borde, traducir el choque a una respuesta HTTP sensata. Eso ya está
centralizado en `app/services/application_service.rb:80`:

```ruby
rescue ActiveRecord::RecordNotUnique => e
  Result.failure(:duplicate, "Ya existe un registro con esos datos.", detail: e.message)
```

La división de trabajo, que conviene poder recitar:

| Capa | Rol | Garantía |
|------|-----|----------|
| `validates ... uniqueness` | UX: mensaje de error en el formulario | ninguna bajo concurrencia |
| Índice `UNIQUE` en Postgres | integridad | absoluta, incluso desde `psql` |
| `rescue RecordNotUnique` | traducir el choque a un 409/422 | evita el 500 |

**Comparación con Java**: es el mismo razonamiento que `@Column(unique=true)` de
JPA — que sólo genera DDL— versus una validación en el servicio. La diferencia
cultural es que en Rails la validación *se ve* funcionar en desarrollo (donde no
hay concurrencia) y da una falsa sensación de seguridad.

**Casos donde la unicidad no es una columna sola**: índice único parcial. Este
repo tiene dos ejemplos que no se pueden expresar con validaciones:

```ruby
# como mucho UN proveedor preferido por producto
add_index :product_suppliers, :product_id, unique: true, where: "preferred",
          name: "index_one_preferred_supplier_per_product"

# la clave de idempotencia sólo es única cuando existe
add_index :stock_movements, :idempotency_key, unique: true,
          where: "idempotency_key IS NOT NULL"
```

**Cómo detectarlo antes**: por cada `uniqueness:` en un modelo, buscá el
`add_index ... unique: true` correspondiente. Es una revisión mecánica y vale la
pena automatizarla.

---

## 5. `#find_or_create_by`: `find_or_create_by` bajo concurrencia

**Síntoma**: `ActiveRecord::RecordNotUnique` intermitente en un endpoint que
"crea si no existe". Aparece sólo con tráfico, nunca en test.

`find_or_create_by` es literalmente `find_by(...) || create!(...)`: dos
sentencias, la misma ventana del punto anterior.

Lo reproduje con dos hilos:

```text
find_or_create_by ingenuo bajo concurrencia: ["creado id=49", "ActiveRecord::RecordNotUnique"]
```

El arreglo es **no intentar evitar la carrera, sino perderla con elegancia**:
confiar en el índice único y rescatar. Está en `app/models/stock_item.rb:121`:

```ruby
def self.find_or_provision!(product:, warehouse:)
  find_by(product:, warehouse:) || create!(product:, warehouse:)
rescue ActiveRecord::RecordNotUnique
  # El otro proceso ganó la carrera: su fila ya está commiteada, la leemos.
  find_by!(product:, warehouse:)
end
```

Mismos dos hilos, con este método:

```text
find_or_provision! (con rescue RecordNotUnique): ["ok id=51", "ok id=51"]
filas: 1
```

Los dos hilos devuelven **el mismo registro** y hay **una sola fila**.

### Las tres trampas de este patrón

1. **Sin índice único, el `rescue` nunca dispara** y te quedan dos filas. El
   rescue no *crea* la garantía, la *aprovecha*.
2. **Adentro de una transacción, el `rescue` no alcanza.** Cuando Postgres
   aborta una sentencia, la transacción entera queda en estado `failed`: toda
   query siguiente devuelve `current transaction is aborted, commands ignored
   until end of transaction block`. Si necesitás seguir operando, envolvé el
   intento en un savepoint: `transaction(requires_new: true) { create! }`.
3. **`find_or_create_by` con un bloque no valida.** `find_or_create_by(sku: x) { |p| p.name = y }`
   usa `create`, no `create!`: si falla la validación devuelve un objeto no
   persistido en silencio. Usá `find_or_create_by!`.

**La alternativa nativa de Postgres**, cuando de verdad querés una sola
sentencia, es `upsert` (`INSERT ... ON CONFLICT`). Este repo la usa para los
contadores (`app/models/sequence_counter.rb:17`). Es más rápida y sin ventana,
pero no corre validaciones ni callbacks.

**Comparación con Java**: el patrón "intentá insertar, rescatá la violación de
constraint" es exactamente el mismo que en JDBC/JPA con
`DataIntegrityViolationException`. Lo que cambia es que en Rails la tentación de
`find_or_create_by` es enorme porque el método existe y parece atómico.

---

## 6. `#query-cache`: el query cache cacheando un `INSERT ... RETURNING` **[BUG REAL]**

Este es el mejor bug del repositorio. Es sutil, silencioso, corrompe datos y
**no aparece en tests unitarios sueltos**.

### El contexto

`SequenceCounter.next_value` genera números correlativos sin huecos para las
referencias de comprobantes (`PO-2026-000045`). Usa un upsert atómico:

```sql
INSERT INTO sequence_counters (key, value, created_at, updated_at)
VALUES ($1, 1, NOW(), NOW())
ON CONFLICT (key) DO UPDATE
  SET value = sequence_counters.value + 1, updated_at = NOW()
RETURNING value
```

Como la sentencia **devuelve filas**, se ejecutaba con `connection.select_value(sql)`.
Ahí está el bug.

### El síntoma

Dos órdenes de compra con la **misma referencia**. `PurchaseOrder` valida
`reference` como única (`app/models/purchase_order.rb:19`) y hay un índice único
en la base, así que lo que ves en producción es un `RecordNotUnique` inexplicable
al crear una orden — o, peor, dos referencias iguales generadas en un mismo
request para dos objetos distintos.

### Por qué pasa

ActiveRecord mantiene un **query cache por request** (más precisamente: por
bloque de ejecución del executor de Rails; también lo tienen los jobs). Si
ejecutás dos veces el **mismo SQL con los mismos binds**, la segunda vez no va a
la base: devuelve el resultado memorizado.

El cache se invalida cuando ActiveRecord **sabe** que escribiste, y lo sabe
porque pasaste por `exec_insert` / `exec_update` / `exec_delete`. Nuestro
`INSERT ... RETURNING` se ejecutaba con `select_value`, o sea que **para
ActiveRecord es un SELECT**. No invalida nada y sí se cachea.

Esta es la parte donde la analogía con Java se rompe fuerte. El instinto de un
javero es: "esto es el first-level cache de Hibernate, el `PersistenceContext`".
No lo es:

| | Hibernate L1 cache | ActiveRecord query cache |
|---|---|---|
| Qué cachea | **entidades por id** dentro de la sesión | **el resultado crudo de un SQL**, por (sql + binds) |
| Alcance | la `Session` / `EntityManager` | el request (o el bloque del executor) |
| Identidad | garantiza que `em.find(X, 1) == em.find(X, 1)` | no garantiza nada: devuelve otra instancia cada vez |
| Dirty checking | sí, hace flush automático antes de una query | **no existe**: `save` escribe ya |
| Invalidación | el `flush` sincroniza antes de consultar | sólo si pasaste por exec_insert/update/delete |

O sea: ActiveRecord **no tiene sesión de persistencia ni dirty checking
diferido**. Cada `save` es un `UPDATE` inmediato. Lo único que se parece
lejanamente a un cache es este query cache, y es mucho más tonto y más literal
que el de Hibernate: cachea *texto de SQL*, no objetos.

### La reproducción, corriendo de verdad

```ruby
conn.cache do
  3.times { print conn.select_value(sql_del_upsert) }
end
```

```text
== Query cache: version MALA (select_value crudo) ==
1 1 1
== Query cache: version BUENA (SequenceCounter.next_value) ==
1 2 3
```

Tres llamadas, **el mismo número tres veces**. La base se tocó una sola vez.

### El arreglo

`app/models/sequence_counter.rb:47`:

```ruby
value = connection.uncached { connection.select_value(sql) }
connection.clear_query_cache
value.to_i
```

Dos líneas, dos motivos distintos:

- `uncached { ... }` — **esta** sentencia no se cachea ni se sirve del cache.
- `clear_query_cache` — invalida lo que ya haya cacheado sobre
  `sequence_counters`, para que nadie lea un valor viejo *después* de que
  escribimos. Sin esto, un `SequenceCounter.find("PO:2026")` posterior en el
  mismo request devolvería el estado previo.

### Por qué no lo agarraba el test

El query cache **está apagado** fuera del executor de Rails. Un spec unitario
suelto llama al método y anda perfecto. El test de regresión tuvo que **prender
el cache a mano** (`spec/models/sequence_counter_spec.rb:30`):

```ruby
it "NO se lo come el query cache de ActiveRecord" do
  ApplicationRecord.connection.cache do
    valores = 3.times.map { described_class.next_value("CACHE-TEST") }
    expect(valores).to eq([ 1, 2, 3 ])
  end
end
```

### La regla general que te llevás

> Si ejecutás SQL crudo que **escribe** pero devuelve filas
> (`INSERT ... RETURNING`, `UPDATE ... RETURNING`, `DELETE ... RETURNING`, o un
> `SELECT` de una función que muta), **no** lo corras con `select_value` /
> `select_all` / `select_one` a secas. Usá `uncached` y limpiá el cache, o usá
> `exec_insert` / `exec_update`, que ya avisan.

Otros lugares donde esto muerde: `SELECT nextval('...')`, `SELECT pg_advisory_lock(...)`,
`SELECT ... FOR UPDATE` ejecutado con `select_all` (el lock se toma la primera
vez y la segunda ni siquiera va a la base, con lo cual creés que tenés el lock y
no lo tenés).

**Cómo detectarlo antes**: grep de `select_value|select_all|select_one` y
revisar que ninguno tenga `INSERT|UPDATE|DELETE|RETURNING|nextval|advisory` en el
SQL.

---

## 7. `#transacciones`: `return` dentro de `transaction` y `Rollback` anidado

Dos trampas distintas que se combinan. Las dos las tuvimos en cuenta al diseñar
`ApplicationService` (`app/services/application_service.rb:46`) y por eso ahí hay
una excepción propia en vez de un `return`.

### 7.a — `return` dentro del bloque hace **COMMIT**

Hasta Rails 6.1, un `return`/`break`/`throw` dentro de un bloque `transaction`
hacía **rollback**. Desde Rails 7 hace **commit** y sólo emite un warning en el
caso de `break`/`throw`. El cambio rompió muchísimo código en silencio.

Lo verifiqué en este repo (Rails 8.1.3.1):

```text
despues de return dentro de transaction, la fila SIGUE (COMMIT)
```

```ruby
# ❌ Rails 7+: la fila queda commiteada
def procesar
  ApplicationRecord.transaction do
    registro.save!
    return :cancelado if alguna_regla_falla?   # COMMIT, no rollback
    otro_registro.save!
  end
end
```

```ruby
# ✅ Lo que hace este repo: una excepción propia que viaja hasta el rescue
class BusinessRuleViolation < StandardError
  attr_reader :result
end

def fail!(code, message, **details)
  raise BusinessRuleViolation, Result.failure(code, message, **details)
end

def transactional
  ApplicationRecord.transaction { yield }
rescue BusinessRuleViolation => e
  e.result           # afuera seguimos devolviendo un Result, no una excepción
end
```

Ver el uso en `app/services/stock/apply_movement.rb:111`: cada regla de negocio
llama a `fail!`, la excepción aborta la transacción con garantía, y el service
igual devuelve un `Result`.

Detalle relacionado: adentro del bloque, para "salir devolviendo un valor" sin
abortar, se usa `next` (`app/services/stock/apply_movement.rb:66`):

```ruby
if (existing = replayed_movement)
  next success(existing)     # `next` sale del BLOQUE devolviendo el valor
end
```

**Comparación con Spring**: en `@Transactional`, un `return` normal commitea
también — hasta ahí igual. La diferencia es que en Spring el rollback se dispara
por *tipo de excepción* (`RuntimeException` sí, checked no, salvo
`rollbackFor`), mientras que en Rails **cualquier** excepción que escape del
bloque hace rollback, con una única excepción especial: `ActiveRecord::Rollback`,
que hace rollback **y se traga a sí misma**.

### 7.b — `ActiveRecord::Rollback` en transacción anidada sin `requires_new`

**Síntoma**: llamás a un método que hace rollback y los datos siguen ahí.

En Rails, `transaction` anidado **no** abre una transacción nueva por defecto:
se "une" a la de afuera (es el equivalente a `Propagation.REQUIRED` de Spring).
`ActiveRecord::Rollback` es capturada por el bloque `transaction` más interno...
que no es una transacción real, así que **no revierte nada** y la de afuera
commitea igual.

Verificado:

```text
tras Rollback en anidada SIN requires_new, la fila externa SIGUE (COMMIT: no revirtio nada)
con requires_new: externa=true interna=false
```

```ruby
# ❌ no revierte nada
ApplicationRecord.transaction do
  SequenceCounter.create!(key: "X", value: 1)
  ApplicationRecord.transaction do
    raise ActiveRecord::Rollback     # se la come el bloque interno
  end
end
# la fila "X" quedó commiteada

# ✅ requires_new abre un SAVEPOINT de verdad
ApplicationRecord.transaction do
  SequenceCounter.create!(key: "A", value: 1)   # sobrevive
  ApplicationRecord.transaction(requires_new: true) do
    SequenceCounter.create!(key: "B", value: 1) # se revierte
    raise ActiveRecord::Rollback
  end
end
```

`requires_new: true` es `Propagation.NESTED` de Spring: un `SAVEPOINT`, no una
transacción física independiente. **No existe** en Rails el equivalente a
`REQUIRES_NEW` (una transacción realmente separada) con la misma conexión: para
eso necesitás otra conexión del pool.

La combinación que te arruina la tarde: un service llamando a otro service, los
dos con `transaction`, y el de adentro haciendo `raise ActiveRecord::Rollback`
para "cancelar". El de adentro cree que canceló; el de afuera commitea todo.

**Regla del proyecto**: dentro de un service, las reglas de negocio nunca usan
`ActiveRecord::Rollback` ni `return`. Usan `fail!`, que levanta una excepción
propia que **no** es capturada por ningún bloque `transaction` intermedio.

**Cómo detectarlo antes**: grep de `ActiveRecord::Rollback` y de `return` dentro
de bloques `transaction`. Y un test que verifique el rollback con dos niveles de
anidamiento.

---

## 8. Callbacks: `after_save` vs `after_commit`

**Síntoma**: se mandó un mail / se encoló un job / se llamó a un webhook para un
registro que después **no existe**, porque la transacción hizo rollback.

```ruby
# ❌ el efecto externo pasa ANTES del COMMIT
after_save :notificar_al_erp

# ✅ el efecto externo pasa DESPUÉS del COMMIT
after_commit :notificar_al_erp, on: [:create, :update]
```

La regla, sin excepciones:

| Tipo de efecto | Callback |
|----------------|----------|
| Escritura en la **misma** base, que debe revertirse junto con todo | `before_save` / `after_save` |
| Cualquier cosa **fuera** de la transacción: HTTP, mail, cola, cache, otra base | `after_commit` |

En este repo, `PurchaseOrderLine` recalcula el total del padre con `after_save`
(`app/models/purchase_order_line.rb:23`) — y está bien, porque es un `UPDATE`
sobre la misma base, en la misma transacción: si hay rollback, se revierten los
dos. El comentario del código deja explícito que es una decisión, no un olvido.

### La trampa fina: `after_commit` dentro de una transacción anidada

`after_commit` dispara cuando commitea la transacción a la que el registro está
asociado, que con anidamiento **no siempre es la más externa**. El resultado es
que encolás un job para datos que todavía pueden revertirse.

La solución de Rails 7.2+ es `ActiveRecord.after_all_transactions_commit`, que
garantiza que el bloque corre cuando commitea la **más externa**. Está en
`app/services/outbox/recorder.rb:47`:

```ruby
ActiveRecord.after_all_transactions_commit do
  next unless Rails.cache.write("outbox/publish_scheduled", 1,
                                expires_in: 2.seconds, unless_exist: true)
  Outbox::PublishPendingJob.perform_later
end
```

Y notá el otro detalle: el evento **sí** se escribe dentro de la transacción
(patrón outbox), lo único que sale afuera es el "empujoncito" para publicar. Si
el encolado falla, el job recurrente lo levanta igual. El estado durable ya
commiteó.

### Otras trampas de callbacks que valen la pena

- **`after_commit` no corre en `update_all` / `delete_all` / `update_column`**:
  esos métodos van directo al SQL, sin instanciar modelos. Si tu lógica depende
  de un callback, un `update_all` la saltea entera.
- **Una excepción en `after_commit` no revierte nada** (ya commiteó) y, según la
  configuración, puede quedar tragada. Envolvela y logueala vos.
- **`after_commit` en tests con transacciones**: si RSpec envuelve cada ejemplo
  en una transacción que hace rollback (`use_transactional_fixtures`), el commit
  nunca ocurre y el callback nunca corre. Es la causa clásica de "el test pasa
  pero en producción no manda el mail" — o al revés.

**Comparación con Java**: `after_commit` es
`TransactionSynchronization#afterCommit` / `@TransactionalEventListener(phase = AFTER_COMMIT)`.
Mismo problema, misma solución. La diferencia es que en Rails el callback vive
*en el modelo*, con lo cual es muy fácil que alguien agregue un efecto externo
sin darse cuenta de que está adentro de una transacción de otro.

---

## 9. Las anclas de regex en Ruby: `^` y `$` son de **línea**

**Síntoma**: pasás una validación de formato con un payload que claramente no
debería pasar. Es una **vulnerabilidad**, no una molestia.

En Ruby, `^` y `$` significan **principio y fin de LÍNEA**, siempre, sin
necesidad de un flag `MULTILINE`. No existe un modo en el que signifiquen
principio y fin de string.

En Java, por defecto `^` y `$` son anclas de **input** (y sólo pasan a ser de
línea con `Pattern.MULTILINE`); además `String.matches()` y `Matcher.matches()`
exigen que **toda** la cadena coincida. Por eso un javero escribe `^...$` y
asume que está cerrando el string. **En Ruby no lo está cerrando.**

Lo verifiqué:

```ruby
/^[A-Z0-9]+$/.match?("VALIDO\n<script>alert(1)</script>")   # => true   ❌
/\A[A-Z0-9]+\z/.match?("VALIDO\n<script>alert(1)</script>") # => false  ✅
/\A[A-Z0-9]+\Z/.match?("VALIDO\n")                          # => true   ⚠️
```

La primera línea cumple el patrón, así que `^...$` da match y el resto del
payload entra igual.

### La tabla completa de anclas

| Ancla | Significa | ¿Segura? |
|-------|-----------|----------|
| `^` | principio de línea | ❌ nunca para validar |
| `$` | fin de línea | ❌ nunca para validar |
| `\A` | principio del string | ✅ |
| `\z` | fin del string, **sin excepciones** | ✅ |
| `\Z` | fin del string, **pero permite un `\n` final** | ⚠️ casi nunca lo que querés |

### El impacto real

Cualquier validación de formato: SKU, email, código de depósito, nombre de
archivo, URL de redirect, header. Si el valor después se interpola en HTML, en
SQL crudo, en un comando de shell, en una cabecera HTTP o en un archivo de
configuración, el `\n` te abre la puerta. El caso de manual es la inyección de
cabeceras HTTP (`Location: /ok\nSet-Cookie: admin=1`).

### Cómo está escrito en este repo

`app/models/product.rb:48`:

```ruby
validates :sku, presence: true, uniqueness: true,
          format: { with: /\A[A-Z0-9][A-Z0-9._-]{1,31}\z/,
                    message: "2-32 caracteres alfanuméricos ASCII, punto, guion o guion bajo" }
```

`app/models/warehouse.rb:11`:

```ruby
validates :code, presence: true, uniqueness: true,
          format: { with: /\A[A-Z0-9-]{2,12}\z/, message: "sólo mayúsculas, números y guiones (2-12)" }
```

`app/models/product.rb:53`, para la moneda: `/\A[A-Z]{3}\z/`.

**Cómo detectarlo antes**: Brakeman lo detecta con el check `ValidationRegex`.
Corrido contra este repo:

```bash
$ bundle exec brakeman -q --no-pager -f plain
Controllers: 20 | Models: 22 | Templates: 34 | Errors: 0 | Security Warnings: 0
No warnings found
```

Corré Brakeman en el CI y fallá el build ante cualquier warning nuevo. Además:
un grep de `format: { with: /\^` en los modelos es una revisión de 10 segundos.

**Bonus de seguridad relacionado**: cuidado con los regex "creativos" sobre
headers, que son vector de ReDoS. Por eso el parseo del Bearer token
(`app/controllers/concerns/api/token_authentication.rb:68`) no usa regex:

```ruby
header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
```

---

## 10. `"false"` es truthy (y los params llegan como String)

**Síntoma**: el filtro `?active=false` devuelve los activos. La feature flag
`?debug=0` prende el debug.

En Ruby, **todo** es truthy salvo `nil` y `false`. Y todo lo que llega por HTTP
es un `String` (o un `Hash`/`Array` de Strings).

```ruby
!!"false"   # => true
!!"0"       # => true
!!""        # => true    (¡el string vacío también!)
!!0         # => true
!![]        # => true
!!({})      # => true
```

```ruby
# ❌ verdadero para "true", "false", "0", "" — o sea, para todo
def index
  scope = scope.where(active: true) if params[:active]
end

# ❌ funciona sólo por casualidad y falla con "1", "yes", "TRUE"
scope = scope.where(active: params[:active] == "true")
```

```ruby
# ✅ app/controllers/api/v1/products_controller.rb:87
def boolean_param(name)
  return nil if params[name].blank?

  ActiveModel::Type::Boolean.new.cast(params[name])
end
```

`ActiveModel::Type::Boolean` trata como **falso** exactamente esta lista:
`false`, `0`, `"0"`, `"f"`, `"F"`, `"false"`, `"FALSE"`, `"off"`, `"OFF"`, `""`,
y `nil`. Todo lo demás es verdadero. Es el mismo casteo que aplica ActiveRecord
al asignar a una columna boolean, así que usarlo te garantiza consistencia entre
el filtro y la persistencia.

Ojo con el `return nil if blank?`: hay tres estados, no dos —`true`, `false` y
"no filtrar"—. Si colapsás `nil` y `false`, `?active=false` y no mandar nada dan
el mismo resultado, que es un bug distinto y más difícil de ver. Por eso el
call site es `scope.where(active: @active) unless @active.nil?`
(`app/queries/products/search.rb:49`), y no `if @active`.

**Comparación con Java**: en Java no hay truthiness — `if (someString)` ni
compila, y `Boolean.parseBoolean("false")` devuelve `false`. Este error es
literalmente imposible de cometer en Java, y por eso los javeros lo cometen en
Ruby: el compilador les cubría la espalda y acá no hay compilador.

---

## 11. `to_i` devuelve 0 en silencio, `Integer()` explota

**Síntoma**: se registró un movimiento de stock de 0 unidades. O de 10 cuando el
cliente mandó `"10 unidades"`, que es peor porque parece que funcionó.

```ruby
"abc".to_i           # => 0     ❌ silencioso
"10 unidades".to_i   # => 10    ❌ peor: parece correcto
"0x1F".to_i          # => 0     ❌
nil.to_i             # => 0     ❌
"".to_i              # => 0     ❌

Integer("10 unidades")
# => ArgumentError: invalid value for Integer(): "10 unidades"   ✅
```

Trampa extra de `Integer()`: **interpreta prefijos de base**. `Integer("0010")`
devuelve `8`, no `10`, porque `0` es el prefijo de octal. Si el input puede venir
con ceros a la izquierda (códigos, cantidades tipeadas a mano), pasá la base
explícita: `Integer(str, 10)`.

Así está en `app/controllers/api/v1/stock_operations_controller.rb:94`:

```ruby
def quantity_param
  Integer(params.require(:quantity))
rescue ArgumentError, TypeError
  raise ActionController::BadRequest, "El parámetro 'quantity' debe ser un entero"
end
```

Y en la capa de servicio, otra vez, porque el service tiene que poder llamarse
desde un job o desde la consola sin pasar por el controller
(`app/services/stock/apply_movement.rb:48`):

```ruby
@quantity = Integer(quantity)
@reserved_delta = Integer(reserved_delta)
```

Notá el `rescue ArgumentError, TypeError`: `Integer(nil)` levanta `TypeError`, no
`ArgumentError`. Rescatar sólo uno de los dos deja pasar el otro.

| Conversión | Input inválido | Cuándo usarla |
|---|---|---|
| `.to_i` | `0` en silencio | nunca sobre input externo |
| `Integer(s)` | `ArgumentError` / `TypeError` | ✅ input externo (con base 10 explícita si hay ceros) |
| `.to_f` | `0.0` en silencio | nunca sobre dinero (ver §13) |
| `Float(s)` | `ArgumentError` | medidas, nunca dinero |
| `BigDecimal(s)` | `ArgumentError` | dinero, si no usás centavos |
| `ActiveModel::Type::Integer.new.cast(s)` | `nil` | cuando querés "inválido = ausente" |

**Comparación con Java**: `Integer.parseInt` siempre fue `Integer()`, no `to_i`.
El instinto de un javero es correcto acá; el problema es que `to_i` es lo que
sale primero al escribir Ruby y nadie te avisa.

---

## 12. `nil` y `false` son los únicos valores falsy de Ruby

Es la contracara del punto 10, y merece su propia entrada porque produce bugs
distintos.

```ruby
[nil, false].map { |v| v ? :truthy : :falsy }        # => [:falsy, :falsy]
[0, "", [], {}, "0"].map { |v| v ? :truthy : :falsy } # => [:truthy, :truthy, :truthy, :truthy, :truthy]
```

Lo que rompe en la práctica:

```ruby
# ❌ un valor legítimo de 0 se trata como "no vino"
cantidad = params[:quantity] || 10        # si params[:quantity] es 0, queda 0 (ok)
cantidad = params[:quantity].presence     # si es "0", queda "0" (ok)
cantidad = 0 || 10                        # => 0 (¡ojo si esperabas el default!)

# ❌ Confundir "atributo ausente" con "atributo false"
if producto.active   # false y nil dan lo mismo -> perdés información
```

Los tres predicados que hay que distinguir:

| Método | `nil` | `false` | `""` | `" "` | `[]` | `0` |
|--------|------|---------|------|-------|------|-----|
| `.nil?` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| `.blank?` (ActiveSupport) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| `.present?` | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |

`false.blank?` es `true`. Esa es la que muerde: `params[:active].presence`
convierte `false` en `nil`. Por eso el `boolean_param` del punto 10 chequea
`blank?` **sobre el String crudo** (donde `"false"` no es blank) y castea
después, en ese orden.

Y el idioma de asignación segura:

```ruby
@idempotency_key = idempotency_key.presence   # "" y "   " -> nil
self.expires_at ||= DEFAULT_TTL.from_now      # sólo si es nil o false
```

`||=` sobre un atributo booleano es un bug esperando: `self.active ||= true`
nunca te va a dejar guardar `false`. Para booleanos, `self.active = true if active.nil?`.

**Comparación con Java**: `Optional.orElse` sólo trata el `null`; no hay
"vacío es falso". Y `Objects.requireNonNullElse(0, 10)` devuelve `0`, como en
Ruby. El problema en Ruby es `blank?`, que junta seis conceptos distintos en un
predicado y es tan cómodo que se usa en lugares donde hace falta `nil?`.

---

## 13. Float para dinero

**Síntoma**: el reporte de valuación difiere en centavos del total de las
líneas. Con volumen, en pesos.

```ruby
0.1 + 0.2               # => 0.30000000000000004
(0.1 + 0.2) == 0.3      # => false

suma = 0.0; 1000.times { suma += 0.01 }
suma                    # => 9.999999999999831   ❌ mil veces un centavo
```

Contra las alternativas correctas, corriendo lo mismo:

```text
1000 x 0.01 en Float      = 9.999999999999831
1000 x 0.01 en BigDecimal = 10.0
1000 x 1 centavo (Integer) = 1000 centavos = USD 10.00
```

Es IEEE-754: `0.1` no tiene representación exacta en binario, como `1/3` no la
tiene en decimal. No es un bug de Ruby, es el mismo `double` de Java.

### Las dos opciones válidas

| | `NUMERIC`/`decimal` + `BigDecimal` | `bigint` de centavos + Value Object |
|---|---|---|
| Exactitud | ✅ | ✅ |
| Velocidad | más lento (aritmética de software en la base y en Ruby) | rapidísimo (enteros nativos) |
| Aritmética | operadores normales | hay que encapsular |
| Riesgo | que alguien haga `.to_f` en el medio | que alguien confunda pesos con centavos |

Este repo usa la segunda (`db/migrate/20260830160400_create_products.rb:30`):

```ruby
t.bigint :cost_cents, null: false, default: 0
t.bigint :price_cents, null: false, default: 0
t.string :currency, null: false, default: "USD"
```

...con un Value Object inmutable, `ValueObjects::Money`
(`app/models/value_objects/money.rb:45`), construido sobre `Data.define` —el
`record` de Ruby 3.2—, que además:

- **prohíbe sumar monedas distintas** (`CurrencyMismatch`, no un número mal);
- **prohíbe multiplicar dinero por dinero** (daría "dólares al cuadrado");
- conoce las monedas sin centavos (`CLP`, `JPY` tienen subunidad 1, no 100);
- construye desde `String`/`BigDecimal`, **nunca desde Float**, en
  `Money.from_amount`, para no heredar el error de redondeo desde el input.

La macro `has_money` (`app/models/concerns/has_money.rb:26`) expone la columna
`*_cents` como Value Object sin que cada modelo repita nada.

### El otro error de dinero: el overflow

`quantity` (int4) × `cost_cents` (int8) puede pasarse de int8 en un inventario
grande. Por eso la valuación castea a `NUMERIC`, que en Postgres es de precisión
arbitraria (`app/queries/stock_items/valuation.rb:38`):

```ruby
Arel.sql("SUM(stock_items.quantity_on_hand::numeric * products.cost_cents)")
```

Es el mismo razonamiento que `long` vs `BigDecimal` en Java.

**Cómo detectarlo antes**: prohibí `t.float` y `t.decimal` sin `scale` para
columnas de plata en la revisión de migraciones. Y un test que sume 10.000
operaciones de un centavo y verifique el total exacto.

---

## 14. Mass assignment y strong parameters

**Síntoma**: un usuario se cambia el rol a `admin`. O cambia el `user_id` de un
recurso ajeno. Es el agujero por el que en 2012 alguien se dio permisos de commit
en el repo de Rails en GitHub.

```ruby
# ❌ ActionController::Parameters ni siquiera lo permite (por eso el tipo existe),
#    pero un .to_unsafe_h o un Hash plano sí
User.new(params[:user].to_unsafe_h)   # el atacante manda {"role": "admin"}
```

```ruby
# ✅ allow-list explícita: lo que no está, no pasa
# app/controllers/api/v1/products_controller.rb:79
def product_params
  params.require(:product).permit(
    :sku, :name, :description, :barcode, :category_id, :unit,
    :cost_cents, :price_cents, :currency, :weight_grams, :active
  )
end
```

### Las trampas que quedan aunque uses `permit`

1. **Permitir de más.** La lista de arriba **no** incluye `id`, `created_at`,
   `lock_version` ni `discarded_at`. En cambio, el controller HTML sí permite
   `:lock_version` (`app/controllers/products_controller.rb:76`), porque el
   formulario lo manda para el optimistic locking. Es una decisión consciente
   por controller, no un copy-paste.

2. **`permit!`** (con bang) permite todo. No existe un caso legítimo en un
   controller que reciba input de un usuario.

3. **`to_unsafe_h`** salta la protección entera. En este repo aparece dos veces
   y las dos con transformación inmediata y validación explícita — por ejemplo
   `app/controllers/api/v1/stock_transfers_controller.rb:66`, que resuelve cada
   SKU contra la base y levanta `RecordNotFound` si no existe:

   ```ruby
   raw.to_unsafe_h.each_with_object({}) do |(sku, qty), acc|
     id = by_sku[sku.to_s.upcase]
     raise ActiveRecord::RecordNotFound, "SKU desconocido: #{sku}" if id.nil?
     acc[id] = Integer(qty)
   end
   ```

4. **Los parámetros anidados necesitan su forma explícita.** `permit(lines: %i[sku quantity])`
   permite un array de hashes con esas dos claves; `permit(:lines)` no permitiría
   nada útil.

5. **Strong parameters no autoriza.** Que el campo esté permitido no significa
   que **ese** usuario pueda escribirlo. La autorización es Pundit
   (`app/policies/*`), y la red de seguridad es el `after_action` que verifica
   que se haya llamado a `authorize` (`app/controllers/api/v1/base_controller.rb:117`).

**Comparación con Java**: es el mismo problema que bindear un request body
directo a una entidad JPA en vez de a un DTO. En Spring lo resolvés con
`@JsonIgnore`, `@InitBinder`/`setDisallowedFields` o —lo sano— un DTO por
endpoint. `permit` es la versión Rails de "usá un DTO", con la ventaja de que es
una allow-list por default y la desventaja de que vive en el controller y hay que
acordarse de mantenerla.

**Cómo detectarlo antes**: Brakeman tiene los checks `MassAssignment`,
`PermitAttributes` y `WithoutProtection`, y los corrió sobre este repo sin
warnings. Además: `config.action_controller.action_on_unpermitted_parameters = :raise`
en test hace que cualquier parámetro no permitido rompa el spec en vez de
descartarse en silencio.

---

## 15. `#enums`: enums con backing entero y el reordenamiento silencioso

**Síntoma**: después de un deploy, todas las órdenes que estaban "canceladas"
figuran como "borrador". No hay migración de datos que lo explique, no hay
`UPDATE` en el log, la base no cambió.

**Por qué**: con backing entero, la base guarda el **ordinal**, y el significado
del ordinal vive en el **código**. Alguien agrega un estado en el medio o
reordena el hash "para que quede más prolijo", y todos los datos históricos
cambian de significado.

```ruby
# ❌ el orden del hash ES el esquema de datos
enum :status, { draft: 0, submitted: 1, cancelled: 2 }

# alguien "ordena alfabéticamente" en un PR de limpieza:
enum :status, { cancelled: 0, draft: 1, submitted: 2 }
```

```text
guardado 0 significaba draft; despues de reordenar, 0 significa cancelled
```

Cero errores, cero warnings, cero filas modificadas. Los datos ahora mienten y
**no hay forma de recuperar la verdad** salvo por backups o por el ledger.

### La solución del repo: backing de String + CHECK

`app/models/user.rb:37`:

```ruby
enum :role, %w[admin manager operator viewer].index_by(&:itself), validate: true
```

`index_by(&:itself)` construye `{"admin"=>"admin", "manager"=>"manager", ...}`:
la clave y el valor son el mismo string, así que la base guarda `"admin"`.
Verificado en la consola:

```ruby
User.roles                # => {"admin"=>"admin", "manager"=>"manager", "operator"=>"operator", "viewer"=>"viewer"}
StockReservation.statuses # => {"held"=>"held", "committed"=>"committed", "released"=>"released", "expired"=>"expired"}
```

Y el cinturón de seguridad en la base
(`db/migrate/20260830154959_create_users.rb:31`):

```ruby
add_check_constraint :users, "role IN ('admin', 'manager', 'operator', 'viewer')",
                     name: "users_role_check"
```

El CHECK es lo que impide que un `update_column`, un seed, una migración de datos
o un `psql` a mano metan un valor inventado. La validación de Rails no protege de
ninguno de esos cuatro.

**Trade-off honesto**: string ocupa más y compara más lento que int. En una tabla
de 500M filas con un enum de alta cardinalidad, la respuesta correcta puede ser
int + una tabla de lookup con FK. Para todo lo demás, string, y `SELECT role FROM users`
se lee solo.

### `validate: true`

Sin esa opción, asignar un valor desconocido levanta `ArgumentError` en el
`role=`, o sea **antes** de que corran las validaciones: no podés mostrarlo en un
formulario. Con `validate: true`, queda como error de validación normal en
`errors[:role]`.

### La otra trampa de `enum`: los métodos bang que colisionan

Rails genera un predicado y un bang por valor: `held?`, `held!`, `committed?`,
`committed!`... y **`committed!` ya existe en ActiveRecord** (lo usa el manejo de
transacciones para disparar los `after_commit`). Pisarlo rompe el framework.

Rails avisa con un `ArgumentError` **al bootear** — mucho mejor que un bug
silencioso. La solución es el prefijo
(`app/models/stock_reservation.rb:22`):

```ruby
enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status
# => status_held?, status_committed!, status_released?, ...

# y alias legibles sólo para los predicados (no para los bang, que son los que colisionan)
def held?      = status_held?
def committed? = status_committed?
```

Otros nombres que colisionan: `new`, `save`, `destroy`, `valid`, `changed`,
`errors`, `persisted`, `frozen`.

**Comparación con Java**: es *exactamente* el problema de
`@Enumerated(EnumType.ORDINAL)` versus `EnumType.STRING` en JPA. Si venís de
Java ya sabés que ORDINAL es una trampa; la diferencia es que en Rails el backing
entero es lo que muestran casi todos los tutoriales.

---

## 16. `update_attribute` y `update_column` saltean cosas distintas

**Síntoma**: hay filas en la base que no pasan sus propias validaciones. Los
callbacks no corrieron. El `updated_at` no cambió.

Los probé sobre un producto real de la base de desarrollo:

```text
sku original: TOR-M5-20
update_attribute devolvio true; en base ahora: "SKU INVALIDO CON ESPACIOS!!"; valido? false
update_column: "OTRO INVALIDO" valido? false
```

`update_attribute` devolvió **`true`**. Si tu código chequea el valor de retorno
para saber si salió bien, te miente.

### La tabla completa

| Método | Validaciones | Callbacks | `updated_at` | Optimistic locking | Devuelve |
|--------|:---:|:---:|:---:|:---:|---|
| `update` | ✅ | ✅ | ✅ | ✅ | `true`/`false` |
| `update!` | ✅ | ✅ | ✅ | ✅ | `true` o `RecordInvalid` |
| `update_attribute` | ❌ | ✅ | ✅ | ✅ | siempre `true` ⚠️ |
| `update_column` | ❌ | ❌ | ❌ | ❌ | `true`/`false` |
| `update_columns` | ❌ | ❌ | ❌ | ❌ | `true`/`false` |
| `update_all` (relación) | ❌ | ❌ | ❌ (salvo que lo pongas) | ❌ | nº de filas |
| `touch` | ❌ | ✅ (`after_touch`) | ✅ | ❌ | `true` |

`update_attribute` es el peor de los tres: saltea validaciones **pero corre
callbacks**, o sea que te deja el objeto en un estado inválido y encima dispara
efectos. Prácticamente nunca es lo que querés. Si querés saltear validaciones a
propósito, `save(validate: false)` al menos lo dice en voz alta.

### Cuándo `update_columns` está bien

Cuando es una **escritura técnica**, no un cambio de dominio, y querés
explícitamente que no corra nada. Dos usos legítimos en este repo:

```ruby
# app/models/api_token.rb:77 — telemetría con throttling.
# Un UPDATE por request sería contención en la fila + WAL para nada.
def touch_usage!
  return if last_used_at.present? && last_used_at > 1.minute.ago

  update_columns(last_used_at: Time.current, requests_count: requests_count + 1)
end
```

```ruby
# app/models/purchase_order.rb:44 — recálculo de un total derivado.
# Corre DESDE un callback de la línea; usar `update!` acá dispararía las
# validaciones y los callbacks del padre en cascada, con riesgo de recursión.
def recalculate_totals!
  update_columns(total_cents: lines.sum(:subtotal_cents),
                 lines_count: lines.count,
                 updated_at: Time.current)
end
```

Fijate que `updated_at` se pone **a mano**: `update_columns` no lo toca, y si no
lo hacés, cualquier cache basado en `cache_key_with_version` (que usa
`updated_at`) sirve datos viejos para siempre. Esa es la conexión silenciosa
entre este error y el §24.

**Comparación con Java**: es como escribir con JDBC crudo salteando el
`EntityManager`: la entidad en memoria queda desincronizada, `@PreUpdate` no
corre y `@Version` no se incrementa. La diferencia es que en Rails los métodos se
llaman casi igual que los buenos y están a un carácter de distancia.

---

## 17. Los valores de `dependent:` y los que borran lo que no querías

**Síntoma**: borraste un usuario y desaparecieron 40.000 movimientos de stock. O
al revés: no podés borrar nada y no entendés por qué.

| Valor | Qué hace | Callbacks del hijo | Riesgo |
|-------|----------|:---:|--------|
| `:destroy` | instancia cada hijo y le llama `destroy` | ✅ | lento con muchos hijos; una excepción deja el borrado a medias |
| `:destroy_async` | igual, pero en un job | ✅ | ventana de inconsistencia; el job puede fallar |
| `:delete_all` | un solo `DELETE ... WHERE parent_id = ?` | ❌ | **saltea callbacks y `dependent:` de los nietos**: deja huérfanos |
| `:nullify` | `UPDATE hijos SET parent_id = NULL` | ❌ | requiere que la FK sea nullable |
| `:restrict_with_error` | agrega un error de validación y no borra | — | ✅ seguro |
| `:restrict_with_exception` | levanta `DeleteRestrictionError` | — | ✅ seguro |
| (ausente) | **no hace nada** | — | ⚠️ huérfanos, salvo que la FK lo impida |

### Lo que se elige en este dominio

En un sistema de stock **no se borra casi nada**: los movimientos históricos
referencian productos, depósitos y proveedores, y un `DELETE` real rompería la
auditoría. Por eso el default del repo es `:restrict_with_error`:

```ruby
# app/models/product.rb:13
has_many :stock_items, dependent: :restrict_with_error
has_many :stock_movements, dependent: :restrict_with_error
has_many :purchase_order_lines, dependent: :restrict_with_error
```

Con dos excepciones deliberadas:

```ruby
# app/models/product.rb:16 — la relación con proveedores es pura asociación, sin historia
has_many :product_suppliers, dependent: :destroy

# app/models/user.rb:17 — nunca destruyas historia contable
has_many :stock_movements, dependent: :nullify
```

`:nullify` sobre `stock_movements` es la decisión clave: si se va un operario,
sus movimientos quedan con `user_id NULL` pero **no se borran**. El ledger sigue
cerrando.

Y para "borrar" un producto, soft delete: `Discardable#discard!` marca
`discarded_at` (`app/models/concerns/discardable.rb:36`). `ProductsController#destroy`
(`app/controllers/products_controller.rb:58`) llama a `discard!`, no a `destroy`.

### La trampa del doble mecanismo

`dependent:` es de **Rails**. La FK con `on_delete:` es de **Postgres**. Son
independientes y hay que alinearlos:

```ruby
# db/migrate/20260830160600_create_stock_items.rb:29
t.references :product, null: false, index: false, foreign_key: { on_delete: :restrict }
```

Si ponés `dependent: :destroy` en Rails y `on_delete: :restrict` en la base,
Rails intenta borrar los hijos y después el padre, y funciona. Pero si alguien
hace `Product.where(...).delete_all` (que **no** corre `dependent:`), la FK lo
frena con un error de Postgres. Eso está bien: es defensa en profundidad.

Al revés es el desastre: `dependent: nil` en Rails + `on_delete: :cascade` en la
base = borrás un producto desde `psql` y se lleva puesto el historial sin que
nadie se entere.

**Cómo detectarlo antes**: revisá cada `has_many` nuevo en el code review. La
pregunta es literal: *"si borro el padre, ¿qué querés que pase con esto?"*. Si la
respuesta es "no sé", la respuesta correcta es `:restrict_with_error`.

---

## 18. Métodos reservados de ActionController **[BUG REAL]**

**Síntoma** — y este es el punto: **todas** las acciones del controller
revientan, no sólo la que agregaste:

```text
ArgumentError: wrong number of arguments (given 3, expected 0)
```

Lo reproduje:

```ruby
class ReservadoController < ActionController::API
  def dispatch = render(plain: "hola")
end
ReservadoController.action(:dispatch).call(env)
# => ArgumentError: wrong number of arguments (given 3, expected 0)
```

**Por qué**: `dispatch` es el método de `ActionController::Metal` que el router
usa para invocar **cualquier** acción: `controller.dispatch(name, request, response)`.
Si definís `def dispatch` en tu controller, pisás el motor de Rails. El router
llama a tu método con tres argumentos, tu método no espera ninguno, y explota
antes de llegar a cualquier acción. El mensaje de error no menciona ni tu
controller ni tu ruta.

Es una diferencia cultural con Java que vale la pena nombrar: en Spring, `@GetMapping`
desacopla el nombre del método del framework, y aunque llames a tu método
`dispatch` no rompés nada porque `DispatcherServlet` es otra clase. En Rails, el
controller **es** el objeto que el framework invoca, así que compartís el espacio
de nombres con él.

### La solución del repo

La URL sigue diciendo `/dispatch`; lo que cambia es el nombre del **método**
(`config/routes.rb:38`):

```ruby
resources :stock_transfers, only: %i[index show new create] do
  member do
    post :dispatch, action: :dispatch_transfer
    post :receive, action: :receive_transfer
  end
end
```

Y en los controllers, `def dispatch_transfer`
(`app/controllers/stock_transfers_controller.rb:45` y
`app/controllers/api/v1/stock_transfers_controller.rb:34`). Mismo criterio en las
purchase orders: `post :receive, action: :receive_order` (`config/routes.rb:87`).

### La lista de nombres a evitar

`dispatch`, `process`, `render`, `params`, `request`, `response`, `send`,
`status`, `action_name`, `performed?`, `head`, `redirect_to`, `session`,
`cookies`, `flash`, `logger`, `url_for`, `helpers`, `controller_name`.

`send` merece una mención aparte: es de `Object`, y pisarlo rompe medio Ruby.

### Cómo detectarlo antes

- Un test de request por **cada** acción del controller. Si el bug está, fallan
  todas juntas, y ese patrón ("fallaron las 6 acciones de un controller y
  ninguna de los demás") es la firma del problema.
- Cuando el nombre natural de tu acción es un verbo genérico, poné el sustantivo
  del dominio: `dispatch_transfer`, `receive_order`. Se lee mejor igual.

---

## 19. `after_action ... only:` apuntando a una acción inexistente **[BUG REAL]**

**Síntoma**: al actualizar de Rails 7.0 a 7.1+, controllers enteros que andaban
empiezan a tirar 500 en **todas** sus acciones.

Reproducido en Rails 8.1.3.1:

```ruby
class DemoController < ActionController::API
  after_action :chequear, only: %i[index]
  def show = render(plain: "ok")
  def chequear = nil
end
```

```text
show EXPLOTA: AbstractController::ActionNotFound:
  The index action could not be found for the :chequear callback on DemoController,
  but it is listed in the controller's :only option.
```

Sin el `only:`, el mismo controller funciona (`sin only: ok`).

**Por qué es un cambio de comportamiento**: hasta Rails 7.0 el `only:` con una
acción inexistente se ignoraba en silencio. Desde 7.1 levanta
`AbstractController::ActionNotFound` **al ejecutar la acción** (no al bootear).
El razonamiento de Rails es correcto —un `only:` que apunta a nada es casi
siempre un typo o un callback que quedó huérfano después de renombrar—, pero la
migración duele porque el error aparece en runtime.

### Dónde nos mordió acá

`Api::V1::BaseController` (`app/controllers/api/v1/base_controller.rb:107`) es la
clase base de **toda** la API. La forma "natural" de verificar el uso de Pundit
sería:

```ruby
# ❌ rompe TODAS las acciones de los controllers que no tienen `index`
after_action :verify_authorized, except: %i[index]
after_action :verify_policy_scoped, only: %i[index]
```

`StockOperationsController` (acciones `receive`, `issue`, `adjust`) y
`ReportsController` (`low_stock`, `valuation`, `reconciliation`) **no tienen
`index`**. Un `only: %i[index]` en la base rompe los dos por completo.

La solución robusta es **un solo callback que decide adentro**
(`app/controllers/api/v1/base_controller.rb:117`):

```ruby
after_action :verify_pundit_usage

def verify_pundit_usage
  action_name == "index" ? verify_policy_scoped : verify_authorized
rescue Pundit::AuthorizationNotPerformedError, Pundit::PolicyScopingNotPerformedError => e
  raise e if Rails.env.local?   # dev/test: explota, querés enterarte ya
  Rails.logger.error(event: "security.authorization_missing",
                     controller: controller_name, action: action_name, error: e.class.name)
end
```

Sin `only:`, sin `except:`, cero acoplamiento entre la clase base y el conjunto
de acciones de sus subclases. La regla general:

> Un callback declarado en una **clase base** no puede usar `only:`/`except:`,
> porque no sabe qué acciones van a tener las subclases.

### Cómo detectarlo antes

- Tests de request de todas las acciones de todos los controllers (otra vez).
- Al renombrar una acción, `grep` del nombre viejo en los `only:`/`except:`.
- Si estás migrando de 7.0 a 7.1+, ese grep es obligatorio antes de deployar.

---

## 20. Timezones: `Time.now`, `Time.current`, `Date.today`, `timestamptz`

**Síntoma**: el reporte "de hoy" tiene un día de corrimiento para algunos
usuarios. Los movimientos de las últimas horas de la noche aparecen en el día
siguiente. Sólo pasa en producción, porque el servidor está en UTC y tu máquina
no.

### Los dos relojes

Ruby tiene el reloj del **sistema operativo** (`ENV["TZ"]`). Rails tiene el
reloj de la **aplicación** (`Time.zone`, configurable por request con
`Time.use_zone`). Los métodos de Ruby usan el primero; los de ActiveSupport, el
segundo.

Lo verifiqué en esta app (config `time_zone = "UTC"`), forzando la zona a Tokio:

```text
Rails.application.config.time_zone = "UTC"
Time.now      -> 2026-08-30 18:18:25 +0000  (Time)
Time.current  -> 2026-08-30 18:18:25 UTC    (ActiveSupport::TimeWithZone)

--- dentro de Time.use_zone("Asia/Tokyo") ---
Time.now      -> 2026-08-30 18:18:25 +0000     <- NO cambió: es la zona del SO
Time.current  -> 2026-08-31 03:18:25 JST       <- sí cambió
Date.today    -> Sun, 30 Aug 2026              <- NO cambió
Date.current  -> Mon, 31 Aug 2026              <- sí cambió, y es OTRO DÍA
```

Ahí está el bug de "un día de corrimiento", en dos líneas.

| Usá | No uses | Por qué |
|-----|---------|---------|
| `Time.current` | `Time.now` | `Time.now` usa la zona del SO, no la de la app |
| `Time.zone.now` | `Time.now` | idéntico a `Time.current`; usá el que más te guste, pero uno solo |
| `Date.current` | `Date.today` | `Date.today` usa la zona del SO |
| `Time.zone.parse(s)` | `Time.parse(s)` | `Time.parse` asume la zona del SO para strings sin offset |
| `1.day.ago`, `30.minutes.from_now` | `Time.now - 86400` | los helpers ya devuelven `TimeWithZone` y respetan DST |
| `Time.zone.at(epoch)` | `Time.at(epoch)` | ídem |

En este repo hay **una sola** forma en uso: `Time.current`, en los 30 lugares que
tocan tiempo (`app/models/stock_item.rb:76`, `app/models/api_token.rb:31`,
`app/models/session.rb:10`, `app/jobs/cleanup/expired_records_job.rb:30`, etc.).
No hay un solo `Time.now` en `app/`.

**Comparación con Java**: `Time.now` es `LocalDateTime.now()` con la zona por
default de la JVM —el clásico problema que resolvés con
`Clock`/`ZoneId.of(...)` inyectado—. `Time.current` es
`ZonedDateTime.now(appZone)`. Y `TimeWithZone` es lo más parecido a
`ZonedDateTime`: sabe su instante absoluto **y** su zona de presentación.

Detalle práctico: los services de este repo inyectan el reloj
(`clock: Time` en `app/services/stock/apply_movement.rb:45`), que es exactamente
el patrón `Clock` de `java.time`, para poder congelar el tiempo en los tests.

### `timestamp` vs `timestamptz`

Por razones históricas, Rails crea columnas `timestamp` **sin** zona en
PostgreSQL. La base guarda `2026-08-30 15:00:00` y **no sabe de qué zona es**;
Rails lo "arregla" convirtiendo todo a UTC antes de escribir... siempre y cuando
la escritura pase por Rails.

Los tres problemas concretos:

1. Un `psql` a mano, un dashboard de BI, un job de Python o una réplica lógica
   **no conocen la convención**. Comparan naive con naive y se equivocan.
2. `now()` de Postgres devuelve `timestamptz`. Compararlo con una columna
   `timestamp` fuerza una conversión implícita usando el `TimeZone` de la sesión,
   que (a) puede dar mal y (b) puede **invalidar el uso del índice** (§3.b).
3. El horario de verano es irresoluble sin la zona.

Este repo lo cambia globalmente (`config/initializers/postgresql_types.rb:31`):

```ruby
ActiveSupport.on_load(:active_record_postgresqladapter) do
  self.datetime_type = :timestamptz
end
```

Verificado contra la base real:

```text
last_movement_at: timestamp(6) with time zone (rails: datetime)
created_at:       timestamp(6) with time zone (rails: datetime)
```

`timestamptz` guarda un **instante absoluto** (microsegundos desde la época, en
UTC) y lo renderiza en la zona que pidas. Es `Instant`/`OffsetDateTime`; el
`timestamp` naive es `LocalDateTime`.

**Contra-caso legítimo**: si querés guardar "las 9 de la mañana **hora local de
cada sucursal**", ahí sí querés naive + la zona en otra columna. Por eso
`warehouses` tiene una columna `timezone` validada contra TZInfo
(`app/models/warehouse.rb:13`) — y ojo con validarla contra
`ActiveSupport::TimeZone::MAPPING`, que es una lista **curada y parcial** de ~150
zonas: `"America/Argentina/Cordoba"` es válida y **no** está en el MAPPING.

**Ojo con el cambio retroactivo**: el initializer sólo afecta a columnas
**nuevas**. Convertir las existentes requiere `ALTER TABLE ... ALTER COLUMN ...
TYPE timestamptz USING ...`, que **reescribe la tabla** con lock exclusivo
(ver §22).

---

## 21. Memoria: Puma y cargar todos los registros

**Síntoma**: el proceso de Puma crece hasta que el OOM killer lo mata; el
balanceador ve 502s. En el log no hay ninguna excepción, el proceso simplemente
desaparece.

**Por qué**: cada worker de Puma es un proceso Ruby con su heap. Un objeto
ActiveRecord no es "una fila": es el objeto, su hash de atributos, los objetos de
tipo, el `@attributes` con valores casteados y sin castear, y la referencia a la
clase. Lo medí sobre un `StockMovement` real de esta base:

```text
un StockMovement completo (deep): ~7632 bytes
una fila de pluck(3 columnas)   : ~560 bytes
ratio: 13.6x

extrapolado a 500.000 filas:
  modelos AR: ~3639 MB
  pluck     : ~267 MB
```

3,6 GB en un worker que probablemente tiene 512 MB de límite. Y el problema
adicional: **CRuby casi nunca le devuelve la memoria al sistema operativo**. Una
sola request que cargó 500.000 filas deja el RSS del worker alto **para siempre**,
aunque los objetos ya se hayan liberado (fragmentación del heap de malloc).

### Los cuatro arreglos, en orden de preferencia

```ruby
# ❌ carga todo en memoria
StockMovement.all.each { |m| procesar(m) }

# ✅ 1. lotes: find_each / in_batches paginan por PK (WHERE id > ?), no con OFFSET
StockMovement.find_each(batch_size: 1000) { |m| procesar(m) }

# ✅ 2. si sólo necesitás columnas, pluck: arrays, no modelos
StockMovement.pluck(:id, :quantity)

# ✅ 3. si es una agregación, que la haga Postgres
StockItems::Availability.call(product_ids: ids)     # un GROUP BY

# ✅ 4. si es un borrado masivo, delete_all en lotes
relation.in_batches(of: 5_000) { |batch| batch.delete_all }
```

Los cuatro están en el repo: `find_each` en
`app/jobs/stock/low_stock_alert_job.rb:18`, `pluck` en todos los query objects,
el `GROUP BY` en `app/queries/stock_items/availability.rb:35`, y el borrado en
lotes en `app/jobs/cleanup/expired_records_job.rb:48`.

Ese último tiene un detalle que se olvida: en Postgres, un `DELETE` no libera el
espacio, deja **tuplas muertas** que el autovacuum tiene que limpiar. Si dejás
crecer una tabla a 200M de filas y después borrás 190M de golpe, el autovacuum no
da abasto, la tabla queda hinchada y las queries se degradan **aunque queden
pocas filas vivas**. Borrar seguido y en lotes chicos mantiene al autovacuum al
día. A escala real, la respuesta buena es **particionar por fecha** y hacer
`DROP PARTITION`, que es instantáneo y no genera tuplas muertas.

### El presupuesto de conexiones y de memoria

```text
conexiones totales = WEB_CONCURRENCY × RAILS_MAX_THREADS × cantidad de bases
```

Este repo usa cuatro bases lógicas (primary, cache, queue, cable), y
`config/database.yml:25` avisa: cada entrada extra abre **su propio pool**, así
que 4 bases × 5 threads = 20 conexiones **por worker**. Con 4 workers son 80
conexiones contra un Postgres que por default acepta 100.

Y el pool de ActiveRecord nunca puede ser menor que los threads de Puma, o vas a
ver `ActiveRecord::ConnectionTimeoutError` bajo carga. Por eso las dos cosas
salen de la misma variable (`.env.example:32`).

**Comparación con Java**: la JVM te da `-Xmx` y devuelve memoria al SO; CRuby no.
Y donde en la JVM un thread pool comparte un heap, en Puma con workers cada
proceso tiene el suyo (copy-on-write ayuda al principio y se degrada con el uso).
El equivalente conceptual de `find_each` es el `ScrollableResults`/`Stream` de
Hibernate con `clear()` periódico del `EntityManager` — con la diferencia de que
en Rails no hay persistence context que limpiar, sólo referencias que soltar.

**Cómo detectarlo antes**: `memory_profiler` y `derailed_benchmarks` en un
endpoint sospechoso; alertas sobre el RSS de los workers; y una regla de revisión:
cualquier `.all`, `.to_a` o `.each` sin `find_each` sobre una tabla que crece.

---

## 22. Migraciones que toman locks y tumban producción

**Síntoma**: corrés una migración, y **antes de que empiece** el sitio se cae por
completo. Todos los endpoints con timeout, incluso los que sólo leen.

**Por qué**: en Postgres, la mayoría del DDL toma un lock `ACCESS EXCLUSIVE`
sobre la tabla, que bloquea **hasta los `SELECT`**. Y —esta es la parte que casi
nadie sabe— **el lock se encola**: si tu migración está esperando un lock que
tiene una query larga, todas las queries que lleguen después se ponen detrás de
tu migración. El sitio se cae mientras la migración **todavía no empezó**.

Este repo usa `strong_migrations` (`config/initializers/strong_migrations.rb`),
que conoce el catálogo de operaciones peligrosas y frena en desarrollo con el
reemplazo seguro escrito en el mensaje de error.

### El catálogo, con el reemplazo

| ❌ Peligroso | ✅ Seguro | Por qué |
|---|---|---|
| `add_index :products, :sku` | `add_index ..., algorithm: :concurrently` + `disable_ddl_transaction!` | un CREATE INDEX normal bloquea las escrituras toda la construcción |
| `change_column_null :products, :sku, false` | CHECK `NOT VALID` → `validate_check_constraint` → recién ahí el NOT NULL | el NOT NULL directo escanea la tabla con lock exclusivo |
| `remove_column` | `ignored_columns` → deploy → `remove_column` | el código viejo todavía la selecciona |
| `rename_column` / `rename_table` | expand-contract (4 deploys) | rompe el código que está corriendo |
| `change_column ... :bigint` | columna nueva + backfill + swap | reescribe la tabla entera |
| backfill con `update_all` en la misma migración que el DDL | migración aparte, en lotes, sin transacción envolvente | el DDL mantiene el lock mientras dura el backfill |

**Expand-contract** para renombrar, que es la respuesta que se espera en una
entrevista: (1) agregar la columna nueva; (2) escribir en las dos; (3) backfill en
lotes; (4) leer de la nueva; (5) borrar la vieja. Cuatro deploys, cero downtime.
Es el mismo patrón que en Flyway/Liquibase; lo que cambia es que Rails no te da
una red y `strong_migrations` sí.

### La configuración que evita la caída en cascada

```ruby
# config/initializers/strong_migrations.rb:60
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
```

Con `lock_timeout`, si la migración no consigue el lock en 10 segundos, **aborta**
en vez de quedarse encolada bloqueando a todos los que vienen atrás. Reintentás
más tarde y listo. Es la diferencia entre "la migración falló" y "el sitio estuvo
caído 8 minutos".

Los otros dos ajustes importantes:

```ruby
StrongMigrations.start_after = 20260830161300      # no analizar las migraciones viejas
StrongMigrations.target_version = ENV.fetch("PG_TARGET_VERSION", 16)
```

`target_version` es la versión de Postgres de **producción**, no la de tu
máquina: `add_column` con default es instantáneo desde Postgres 11 y reescribe la
tabla en versiones anteriores, así que la gema necesita el dato para decidir.

**Cómo detectarlo antes**: `strong_migrations` en el CI + revisar el plan de cada
migración contra el **tamaño real** de la tabla en producción, no contra los datos
de seed. Y `SELECT pg_size_pretty(pg_total_relation_size('stock_movements'))`
antes de tocar nada.

---

## 23. Secretos en el repo, en los logs y en los mensajes de error

Tres superficies distintas, tres controles distintos. Fallan por separado.

### a) En el repo

```text
# .gitignore
/config/*.key      # las master key / credenciales
/.env
/.env.*
!/.env.example
```

`.env.example` (que **sí** se commitea) tiene sólo valores falsos y comentarios.
`dotenv-rails` carga `.env` sólo en development y test; en producción las
variables vienen del entorno real (Kamal, systemd, Kubernetes).

El error clásico no es commitear el secreto: es **commitearlo, borrarlo en el
commit siguiente y creer que se fue**. Está en la historia de git para siempre.
El único arreglo es **rotar la credencial**, no reescribir la historia.

Los tokens de este repo nunca se guardan en claro
(`app/models/api_token.rb:35`): se guarda un SHA-256 y el plaintext existe una
sola vez, en el objeto que devuelve `.issue!`. Es exactamente cómo funcionan los
personal access tokens de GitHub.

### b) En los logs

`config/initializers/filter_parameter_logging.rb:6`:

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]
```

Son coincidencias **parciales**: `passw` matchea `password` y `password_confirmation`;
`_key` matchea `api_key` e `idempotency_key`. Las tres trampas que quedan:

1. **`filter_parameters` no filtra headers.** El `Authorization: Bearer stk_...`
   no lo cubre esta lista. Rails no loguea headers por default, pero cualquier
   logueo manual de `request.headers` sí, y muchas librerías de APM los mandan.
2. **No filtra las URLs.** Un secreto en un query string
   (`?token=abc`) aparece en el log del load balancer, en el `Referer` y en el
   historial del browser. **Nunca** pongas secretos en la URL.
3. **No filtra lo que loguea tu código.** `Rails.logger.info(params.inspect)`
   escupe todo.

Y en producción, `config.log_level = "info"` (`config/environments/production.rb:41`).
El comentario del propio Rails es explícito: *"Change to debug to log everything
(including potentially personally-identifiable information!)"*. `debug` loguea
los binds de cada query.

### c) En los mensajes de error

Este es el que más se olvida. Los mensajes de Postgres filtran nombres de tablas,
columnas, constraints y a veces **datos**. `PG::UniqueViolation: duplicate key
value violates unique constraint "index_users_on_email_address" DETAIL: Key
(email_address)=(ana@empresa.com) already exists.` — ese `DETAIL` es un dato
personal, y va derecho al cliente si devolvés `e.message`.

`app/controllers/concerns/api/error_handling.rb:113`:

```ruby
def render_internal_error(exception)
  Rails.logger.error(event: "api.internal_error", request_id: request.request_id,
                     exception: exception.class.name, message: exception.message,
                     backtrace: exception.backtrace&.first(15))
  render_error(:internal_error,
               "Ocurrió un error inesperado. Contactá a soporte con este id.",
               status: :internal_server_error, request_id: request.request_id)
end
```

Detalle completo al log, **id de correlación** al cliente. Soporte encuentra el
error exacto sin exponer nada.

El mismo criterio en el 404 (`app/controllers/concerns/api/error_handling.rb:74`):
no se devuelve qué modelo ni qué id, porque eso permite **enumerar recursos**
(distinguir "no existe" de "existe pero no es tuyo" es una fuga de información).

Y `config.consider_all_requests_local = false` en producción: con `true`, la
página de error de Rails muestra el **código fuente**, el backtrace completo, las
variables locales y el entorno.

**Cómo detectarlo antes**: `gitleaks`/`trufflehog` en el CI; una revisión de que
ningún `rescue` devuelva `e.message` al cliente; y el check `DetailedExceptions`
de Brakeman.

---

## 24. Cache keys incompletas

**Síntoma**: un usuario ve el reporte de **otro** depósito. O el filtro por
categoría no hace nada porque la primera respuesta quedó cacheada para todos.

**La regla**: la clave de cache tiene que incluir **todo** lo que hace variar el
resultado. Si te olvidás un parámetro, servís el resultado de otra combinación, y
es **silencioso**: no hay error, no hay log, sólo datos incorrectos.

```ruby
# ❌ ignora category_id: el primer request que llegue define lo que ven todos
Rails.cache.fetch("reports/valuation", expires_in: 5.minutes) { ... }

# ✅ app/controllers/api/v1/reports_controller.rb:62
def valuation_cache_key
  [ "reports/valuation", params[:warehouse_code].to_s.upcase, params[:category_id] ].join("/")
end
```

La checklist de qué tiene que entrar en la clave:

| Dimensión | Ejemplo | Qué pasa si falta |
|-----------|---------|-------------------|
| Filtros | `warehouse_code`, `category_id` | servís datos de otro filtro |
| Identidad / tenant | `user_id`, `account_id` | **fuga entre usuarios** |
| Permisos | rol, scopes del token | mostrás datos que el usuario no puede ver |
| Locale / moneda | `I18n.locale` | textos o formatos en el idioma equivocado |
| Versión de los datos | `max(updated_at)`, `count` | servís datos viejos hasta que expire el TTL |
| Versión del código | el deploy | un cambio de formato lee un cache con la forma vieja |

Los dos primeros son de **seguridad**, no de correctitud.

### Trampas específicas

**La normalización tiene que ser parte de la clave.** `warehouse_code` viene del
usuario: `"dep-1"` y `"DEP-1"` son el mismo depósito pero dos claves distintas
(fragmentación del cache) — o, si normalizás en un lado y no en el otro, la misma
clave para cosas distintas. Por eso el `.to_s.upcase` está **en la clave**.

**Cachear objetos ActiveRecord es frágil.** `Warehouse.transit`
(`app/models/warehouse.rb:30`) cachea un modelo:

```ruby
def self.transit
  Rails.cache.fetch("warehouse/transit", expires_in: 1.hour) { find_by!(code: TRANSIT_CODE) }
end
```

Funciona porque es un registro casi inmutable con TTL corto. Pero el objeto se
**serializa** al guardarlo: si agregás una columna, el objeto cacheado no la
tiene, y `warehouse.columna_nueva` puede tirar `NoMethodError` o `nil` hasta que
expire. Para datos que cambian, cacheá el **id** y hacé el `find`, o incluí la
versión del esquema en la clave.

**Cache versionado y `updated_at`.** `record.cache_key_with_version` produce
`products/1-20260830181825000000`, o sea que se invalida sola al escribir. Eso
depende de que `updated_at` **cambie**, y `update_column`/`update_all` no lo
tocan (§16). Ahí tenés el bug de dos entradas atrás manifestándose acá.

**El TTL no es una estrategia de invalidación**, es un techo al daño. Si el dato
tiene que estar fresco, invalidá explícitamente al escribir.

### La misma clase de error fuera del cache: la clave de idempotencia **[BUG REAL]**

Esto no es un cache, pero es exactamente el mismo bug: **una clave sin el
discriminador de tenant**. Lo encontramos escribiendo los tests.

Los controllers le pasan la clave `Idempotency-Key` a los services, que la
guardan en `stock_movements.idempotency_key`. Ese índice único es **global**, no
por usuario. Con la clave cruda:

```text
1. el usuario A manda  Idempotency-Key: "pedido-1"   -> se ejecuta, se guarda
2. el usuario B manda  Idempotency-Key: "pedido-1"   -> ¡otra empresa!
3. el service encuentra el movimiento de A y le devuelve ESE
```

O sea: B **recibe datos de A** (fuga de información) y su operación **no se
ejecuta** (pérdida de datos), las dos cosas en silencio. Y con claves tipo
`"pedido-1"` o `"1"` —que la gente usa— la colisión no es hipotética.

El arreglo, en `app/controllers/concerns/api/idempotency.rb:68`:

```ruby
def idempotency_key
  key = raw_idempotency_key
  return nil if key.nil?

  "u#{current_user&.id || 'anon'}:#{key}"
end
```

Prefijar con el id del usuario aísla los espacios de nombres. Hay un test de
regresión ("las claves están SCOPEADAS POR USUARIO").

La regla, que aplica igual a un cache, a un lock distribuido, a un contador de
rate limit y a una clave de idempotencia: **si la clave la elige el cliente, el
servidor tiene que prefijarla con quién es el cliente.**

---

## 25. Un job con un objeto serializado viejo

**Síntoma**: el job "revierte" un cambio que un usuario acaba de hacer. O falla
con `RecordNotFound` en una excepción que no podés rescatar porque ocurre antes
de tu código.

**La regla, en `app/jobs/application_job.rb:19`, en mayúsculas**:

```ruby
MiJob.perform_later(product)        # ❌
MiJob.perform_later(product.id)     # ✅
```

**Por qué**: Active Job serializa los argumentos (los modelos vía GlobalID) y el
job puede ejecutarse minutos u horas después. Si pasás el objeto:

- el estado que ves en el worker puede ser **viejo** — y si hacés `save`,
  **pisás** lo que otro cambió en el medio;
- si el registro se borró, el job explota con `RecordNotFound` **al
  deserializar**, o sea antes de tu código: no lo podés manejar adentro del
  `perform`;
- el payload es más grande (más red, más base).

Con el id, releés el estado **actual** adentro del job y decidís qué hacer si no
existe.

El manejo del caso "el registro ya no está" está centralizado
(`app/jobs/application_job.rb:63`):

```ruby
discard_on ActiveJob::DeserializationError do |job, error|
  Rails.logger.warn(event: "job.discarded", job: job.class.name,
                    reason: "registro inexistente", error: error.message)
end
```

`discard_on` y no `retry_on`: reintentar un `RecordNotFound` 25 veces es puro
desperdicio, el registro no va a reaparecer. Distinguir "error transitorio"
(retry) de "error permanente" (discard) es lo que mantiene una cola sana; si
reintentás todo, la cola se tapa con basura y los jobs buenos no entran.

### Los dos corolarios

**Todo job debe ser idempotente.** Las colas garantizan **at-least-once**, nunca
exactly-once: un worker puede morir después de hacer el trabajo y antes de marcar
el job como completado. Si tu job manda un mail o descuenta stock, tenés que
poder detectar la repetición.

**No encoles adentro de la transacción.** Si encolás en un `after_save` y la
transacción hace rollback, el worker levanta un job para una fila que no existe —
y como los workers son rápidos, muchas veces lo levanta **antes** de que la
transacción commitee, con lo cual el job no encuentra el registro aunque después
sí exista. Ese es el motivo del `after_all_transactions_commit` del §8 y del
patrón outbox entero.

**Comparación con Java**: es exactamente el problema de mandar una entidad JPA
por JMS. Mandás el id y hacés `em.find` del otro lado. Lo que cambia es que
Active Job **te deja** pasar el modelo y hasta parece que funciona, porque
GlobalID lo resuelve solo.

**Cómo detectarlo antes**: grep de `perform_later(` seguido de algo que no
termine en `_id` o `.id`. Y un test que borre el registro entre el encolado y el
`perform_enqueued_jobs`.

---

## 26. Zeitwerk: nombre de archivo vs constante

**Síntoma**: `NameError: expected file app/models/api_token.rb to define constant
ApiToken`. O peor, en producción: `NameError: uninitialized constant Foo::Bar`
para código que en desarrollo anda perfecto (ver §27).

**El contrato de Zeitwerk es literal**: cada archivo `.rb` bajo un directorio de
autoload debe definir **la constante que corresponde a su ruta**, con la
camelización de ActiveSupport. La ruta es el índice; no hay escaneo.

Verificado en esta app:

```ruby
"api_token".camelize   # => "ApiToken"
"api".camelize         # => "Api"
"v1".camelize          # => "V1"
"html_parser".camelize # => "HtmlParser"
```

Las convergencias que hay que tener claras:

| Ruta | Constante esperada |
|------|--------------------|
| `app/models/stock_item.rb` | `StockItem` |
| `app/models/value_objects/money.rb` | `ValueObjects::Money` |
| `app/controllers/api/v1/base_controller.rb` | `Api::V1::BaseController` |
| `app/services/stock/apply_movement.rb` | `Stock::ApplyMovement` |
| `app/lib/result.rb` | `Result` |
| `app/models/concerns/discardable.rb` | `Discardable` (no `Concerns::Discardable`) |

Fijate en las dos últimas: `app/lib` y `app/models/concerns` son **raíces de
autoload**, no namespaces. Lo confirmé con `Rails.autoloaders.main.dirs`, que
incluye `app/lib`, `app/models/concerns` y `app/controllers/concerns` como raíces
propias. Ese es el motivo por el que el módulo se llama `Discardable` a secas y
no `Concerns::Discardable`.

### El caso de los acrónimos

Si escribís `class APIToken` en `app/models/api_token.rb`, Zeitwerk explota:
espera `ApiToken`. Hay dos salidas, y la elección es del proyecto:

```ruby
# Opción A (la de este repo): el código se adapta a la convención.
class ApiToken < ApplicationRecord   # app/models/api_token.rb
```

```ruby
# Opción B: enseñarle el acrónimo al inflector.
# config/initializers/inflections.rb
ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "API" }
```

Con la opción B, la camelización cambia globalmente:

```ruby
"api_token".camelize   # => "APIToken"
"api".camelize         # => "API"
"APIToken".underscore  # => "api_token"    (sigue siendo consistente)
```

...pero también cambia para **todo lo demás**: los nombres de tabla, las rutas,
`Api::V1` pasa a ser `API::V1`, y hay que renombrar cada constante existente que
contenga "api". Por eso `config/initializers/inflections.rb` en este repo está
comentado entero: no hay ninguna inflexión custom. Es la decisión más barata.

Para un caso aislado, la puerta de escape sin efectos globales es el override por
archivo. En este repo **no existe** ese initializer (no hizo falta); si lo
necesitaras, iría en un archivo nuevo bajo `config/initializers/`:

```ruby
# por ejemplo, config/initializers/zeitwerk.rb — NO existe en este repo
Rails.autoloaders.main.inflector.inflect("api_token" => "APIToken")
```

La diferencia con la opción B es el alcance: `inflect` sólo afecta al
**autoloader** (qué constante espera de qué archivo), no a `camelize`,
`underscore`, los nombres de tabla ni las rutas.

### La herramienta

```bash
$ bin/rails zeitwerk:check
Hold on, I am eager loading the application.
All is good!
```

`zeitwerk:check` hace un eager load completo y verifica que **cada archivo defina
la constante que su ruta promete**. Es rápido, no necesita base de datos y es
obligatorio en el CI: es la única forma de agarrar un archivo mal nombrado que en
desarrollo nunca se cargó.

**Comparación con Java**: es el mismo contrato "un archivo público por clase, con
el nombre de la clase, en el directorio del package" — con la diferencia de que
en Java lo verifica el **compilador**, y en Ruby lo verifica el autoloader
**cuando alguien pide esa constante**. Si nadie la pide, el error no aparece.

---

## 27. Autoload en dev vs eager load en prod ("anda en dev, falla en prod")

**Síntoma**: la app bootea perfecto en tu máquina y en producción se cae al
arrancar, o —peor— anda hasta que alguien entra a la pantalla que nadie probó.

**Por qué**: son dos modos de carga distintos.

```ruby
# config/environments/development.rb:7
config.enable_reloading = true
config.eager_load = false

# config/environments/production.rb:7
config.enable_reloading = false
config.eager_load = true

# config/environments/test.rb:16
config.eager_load = ENV["CI"].present?
```

En **desarrollo** las constantes se cargan **cuando se usan**. Un archivo con un
error de sintaxis, una constante mal nombrada o un `require` roto que nadie
ejecutó **no se carga nunca**, y por lo tanto no falla nunca.

En **producción** se carga **todo al bootear**. Cualquiera de esos problemas
tumba el proceso en el arranque — con el agravante de que el deploy puede pasar
el health check antes de que se note, o directamente entrar en crash-loop.

Fijate en la línea de test: `eager_load` está prendido **sólo en CI**. Esa es la
red: localmente la suite arranca rápido, y en CI se hace el eager load completo,
que es lo que replica el boot de producción.

### Los cuatro problemas que sólo aparecen con eager load

1. **Constante mal nombrada** (§26): en dev nunca se cargó, en prod sí.
2. **Dependencias circulares.** Con autoload lazy, A carga B que carga A y a veces
   sale bien por el orden en que se pidieron; con eager load el orden es
   determinístico y explota.
3. **Código a nivel de clase que toca la base de datos.** Un
   `SCOPES = Setting.pluck(:name)` en el cuerpo de la clase corre **al bootear**.
   En dev corre cuando entrás a esa pantalla (con la base ya lista); en prod corre
   durante el arranque, quizás antes de que la base esté disponible, y el proceso
   muere. El caso patológico: corre durante `db:migrate` de un contenedor nuevo,
   contra una tabla que la migración todavía no creó.
4. **Estado mutable a nivel de clase.** Con reloading, las clases se recargan y el
   estado se pierde; sin reloading, persiste. Un contador o un memo a nivel de
   clase se comporta distinto en cada entorno.

En este repo hay un caso de código a nivel de clase que **sí** corre al bootear y
está hecho a propósito, con cuidado
(`app/controllers/api/v1/base_controller.rb:46`):

```ruby
RATE_LIMIT_STORE =
  if ENV["REDIS_URL"].present?
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"], namespace: "ratelimit")
  elsif Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
    Rails.logger.warn("[RateLimit] Rails.cache es un NullStore: el rate limiting NO funcionaría. ...")
    ActiveSupport::Cache::MemoryStore.new
  else
    Rails.cache
  end
```

Lee variables de entorno y objetos ya inicializados por Rails —**no** la base de
datos— y avisa por log si el store elegido no sirve. Eso último resuelve un fallo
silencioso de seguridad: `rate_limit` hace `store.increment(...)`, un `NullStore`
devuelve `nil`, la comparación `count && count > to` nunca se cumple, y el límite
queda desactivado sin un solo mensaje.

### El mismo fallo silencioso, del lado de los tests **[BUG REAL]**

El default de Rails en el entorno de test es `cache_store = :null_store`, para
que ningún test dependa sin querer de un valor cacheado. Suena razonable y tiene
una consecuencia grave: **todo lo que se apoya en el cache deja de funcionar en
silencio**. Con un null store, los specs de rate limiting daban **verde sin
probar nada**: `increment` devolvía `nil` y el contador nunca superaba el límite.

Por eso `config/environments/test.rb:35` fuerza un store real:

```ruby
config.cache_store = :memory_store
```

...y los specs limpian el cache entre ejemplos
(`spec/requests/api/v1/rate_limiting_spec.rb:18`), porque los contadores
sobreviven entre ejemplos y son la causa número uno de flakiness en esos tests.

La regla general: **un test que verifica una protección tiene que poder fallar.**
Si no lo viste fallar al menos una vez —desactivando la protección a propósito—,
no sabés si prueba algo.

### El otro "anda en dev, falla en prod": el adapter de la cola

`config/initializers/active_job.rb:15` marca la otra mitad del problema: el
adapter `async` es el default de desarrollo y mantiene los jobs en un thread pool
**en memoria**. Si el proceso se reinicia, se pierden todos los jobs pendientes,
sin aviso. Anda perfecto en tu máquina; en producción es pérdida de datos
garantizada. Por eso el default acá es `solid_queue` y `test` en el entorno de
test.

**Cómo detectarlo antes**:

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
bin/rails zeitwerk:check                                # verifica el contrato de nombres
RAILS_ENV=production bin/rails runner 'puts "boot ok"'  # fuerza el eager load real
```

Y `config.eager_load = true` en CI, que es lo que ya hace este repo.

---

## 28. Rate limiting mal discriminado (dos bugs reales de configuración)

Los dos son de configuración, los dos son silenciosos y los dos rompen algo que
creías tener.

### a) Dos `rate_limit` sin `name:` comparten contador **[BUG REAL]**

**Síntoma**: un límite de 20 por minuto corta en la request **11**.

**Por qué**: Rails arma la clave del contador así:

```ruby
["rate-limit", scope, name, by].compact.join(":")
```

y `scope` por defecto es `controller_path`. Si declarás **dos** `rate_limit` que
aplican al mismo controller —uno en la clase base y otro en la subclase— **sin**
pasar `name:`, las dos declaraciones generan **la misma clave**. Comparten un
solo contador y **cada request lo incrementa dos veces**.

Lo comprobamos con curl: `/reports` (20/min) cortaba en la request 11.

**El arreglo**: `name:` distinto en cada límite
(`app/controllers/api/v1/base_controller.rb:75` y
`app/controllers/api/v1/stock_operations_controller.rb:30`):

```ruby
# base: techo global compartido por TODA la API v1
rate_limit to: 600, within: 1.minute, name: "api-global", scope: :api_v1, ...

# subclase: límite más estricto para las escrituras de stock
rate_limit to: 120, within: 1.minute, name: "stock-writes", ...
```

Y `scope:` explícito cuando querés que el techo se comparta entre controllers
distintos (que es lo que queremos: un tope **por token** para toda la API, no uno
por controller).

**El test de regresión** (`spec/requests/api/v1/rate_limiting_spec.rb:49`) hace 15
requests y espera un 200: con el bug, en la 11 ya devolvía 429.

### b) `Rack::Attack` insertado antes de `ActionDispatch::RemoteIp`

**Síntoma**: el primer usuario que hace 300 requests deja afuera a **todo el
mundo**.

**Por qué**: el instinto es `insert_before 0`, lo más arriba posible, para cortar
antes de gastar nada. Pero ahí Rack::Attack corre **antes** de
`ActionDispatch::RemoteIp`, y entonces `request.ip` es la IP del **peer TCP**:
detrás de un load balancer, eso es la IP **del balanceador**. Todos tus usuarios
comparten un único contador.

`config/application.rb:52`:

```ruby
config.middleware.insert_after ActionDispatch::RemoteIp, Rack::Attack
```

Seguís estando muy arriba —antes de la sesión, el routing y los controllers— pero
ya con la IP del cliente real.

**Y el corolario de seguridad**: nunca confíes en `X-Forwarded-For` sin
configurar `config.action_dispatch.trusted_proxies`. Es un header que manda el
**cliente** y lo puede falsificar para evadir el rate limit; `RemoteIp` sólo lo
respeta viniendo de un proxy conocido.

Podés ver el stack completo con `bin/rails middleware`.

---

## Errores que ves en producción

La versión corta, para tener a mano. Síntoma → causa → arreglo.

| # | Síntoma que ves | Causa más probable | Arreglo |
|---|---|---|---|
| 1 | 200 líneas iguales en el log, endpoint de 3 s | N+1 de asociación | `includes` / `with_associations` (§1) |
| 2 | Hiciste `includes` y sigue el N+1 | `sum`/`count` sobre la asociación | query object con `GROUP BY` (§1B) |
| 3 | Un `COUNT(*)` por fila renderizada | `.count` en la vista | `.size` sobre asociación cargada (§1D) |
| 4 | `Product.count` no coincide con `psql` | `default_scope` | scopes explícitos; salir con `unscope(where: :col)` (§2) |
| 5 | Índice creado, `EXPLAIN` dice Seq Scan | función sobre la columna, o tabla chica | índice funcional / `citext` / normalizar (§3) |
| 6 | Dos filas con el mismo SKU | `uniqueness` sin índice único | `add_index unique: true` + `rescue RecordNotUnique` (§4) |
| 7 | `RecordNotUnique` intermitente al crear | `find_or_create_by` | rescatar y releer (§5) |
| 8 | Dos comprobantes con el mismo número | query cache sobre `INSERT ... RETURNING` | `uncached` + `clear_query_cache` (§6) |
| 9 | Se commiteó algo que "cancelaste" | `return` dentro de `transaction` (Rails 7+) | excepción propia + `rescue` (§7a) |
| 10 | El rollback anidado no revirtió nada | `ActiveRecord::Rollback` sin `requires_new` | `requires_new: true` o excepción propia (§7b) |
| 11 | Mail/job para un registro que no existe | efecto externo en `after_save` | `after_commit` / `after_all_transactions_commit` (§8) |
| 12 | Pasa la validación un payload con `\n` | anclas `^` `$` | `\A` y `\z` (§9) |
| 13 | `?active=false` devuelve los activos | `"false"` es truthy | `ActiveModel::Type::Boolean#cast` (§10) |
| 14 | Movimiento de 0 unidades desde la API | `.to_i` sobre basura | `Integer()` + rescue (§11) |
| 15 | `0` tratado como "no vino" | `blank?` donde iba `nil?` | `.nil?`, y `unless x.nil?` (§12) |
| 16 | El total difiere en centavos | Float para plata | centavos enteros + Value Object (§13) |
| 17 | Un usuario se volvió admin | mass assignment | `permit` explícito, nunca `permit!` (§14) |
| 18 | Estados históricos cambiaron de significado | enum con backing entero reordenado | backing de String + CHECK (§15) |
| 19 | Filas que no pasan sus validaciones | `update_attribute` / `update_column` | `update!`, y `update_columns` sólo para escrituras técnicas (§16) |
| 20 | Se borró historial al borrar un usuario | `dependent: :destroy` donde iba `:nullify` | revisar cada `has_many` (§17) |
| 21 | `wrong number of arguments (given 3, expected 0)` | método reservado (`dispatch`) | renombrar el método, no la URL (§18) |
| 22 | `AbstractController::ActionNotFound` tras subir a 7.1 | `only:` a acción inexistente | un callback que decide adentro (§19) |
| 23 | Reporte "de hoy" corrido un día | `Time.now` / `Date.today` | `Time.current` / `Date.current` (§20) |
| 24 | Workers matados por OOM, 502 sin excepción | cargar todo en memoria | `find_each`, `pluck`, `GROUP BY` (§21) |
| 25 | El sitio se cae antes de que la migración empiece | lock encolado | `lock_timeout`, `algorithm: :concurrently` (§22) |
| 26 | Un email en el mensaje de error del 500 | `e.message` al cliente | id de correlación; detalle al log (§23) |
| 27 | Un usuario ve el reporte de otro depósito | cache key incompleta | todos los filtros + tenant en la clave (§24) |
| 28 | El job pisó un cambio del usuario | se serializó el objeto | pasar el id (§25) |
| 29 | `NameError: expected file ... to define constant` | nombre de archivo vs constante | `bin/rails zeitwerk:check` en el CI (§26) |
| 30 | Anda en dev, el proceso muere al bootear en prod | `eager_load` sólo en producción | `eager_load = true` en CI (§27) |
| 31 | El usuario B recibe la respuesta del usuario A | clave de idempotencia sin scope de tenant | prefijar con el id del usuario (§24) |
| 32 | Un límite de 20/min corta en la request 11 | dos `rate_limit` sin `name:` comparten contador | `name:` distinto por límite (§28a) |
| 33 | Un usuario deja afuera a todos los demás | Rack::Attack antes de `RemoteIp`: cuenta la IP del LB | `insert_after ActionDispatch::RemoteIp` (§28b) |
| 34 | Los tests de rate limiting dan verde sin probar nada | `:null_store` en test: `increment` devuelve `nil` | `:memory_store` + limpiar entre ejemplos (§27) |

---

## Cómo responder esto en una entrevista

### 1. "¿Cómo detectás y arreglás un N+1?"

**Respuesta corta**: lo detecto con Bullet en el entorno de test —configurado con
`raise = true`, así el N+1 rompe el build— y con `verbose_query_logs` en
desarrollo, que me dice qué línea originó cada query. Para arreglarlo hay dos
casos distintos: si es un N+1 de **carga de asociaciones**, `includes` (o
`preload`/`eager_load` si necesito controlar si va con dos queries o con un JOIN);
si es un N+1 de **agregación** —un `sum` o un `count` por fila— `includes` no
sirve, y hay que resolverlo con una sola query agregada con `GROUP BY` y pasarle
el resultado precalculado al serializer.

**El trade-off**: `includes` cambia N+1 queries por más memoria y a veces por un
JOIN que devuelve filas duplicadas. Y el problema inverso existe: precargar algo
que después no usás es una query y memoria desperdiciadas. Por eso también dejo
prendido `unused_eager_loading` en Bullet.

**El remate**: la diferencia con Hibernate es que allá el N+1 lo sentís en el
`LazyInitializationException` o lo evitás con `JOIN FETCH`; en ActiveRecord no
hay sesión de persistencia, así que el N+1 **nunca falla, sólo es lento**, y por
eso hace falta una herramienta que lo convierta en un error.

### 2. "Tenés una validación de unicidad. ¿Alcanza?"

**Respuesta corta**: no. `validates :sku, uniqueness: true` hace un `SELECT` y
decide en Ruby: entre ese `SELECT` y el `INSERT` hay una ventana en la que otra
transacción puede insertar el mismo valor. La única garantía es un índice
`UNIQUE` en la base. La validación queda igual, porque da un mensaje de error
lindo en el formulario en el 99,9% de los casos; el índice cubre el 0,1%. Y en el
borde traduzco `ActiveRecord::RecordNotUnique` a un 409 o un 422 para no devolver
un 500.

**El trade-off**: el índice único cuesta escritura en cada INSERT/UPDATE y no te
deja dar un mensaje por campo. Por eso van los dos, no uno.

**El remate**: si la regla de unicidad es condicional —"como mucho un proveedor
preferido por producto"— eso no se puede expresar con una validación, pero sí con
un índice único **parcial**: `add_index ..., unique: true, where: "preferred"`.
Mismo razonamiento para las claves de idempotencia, que sólo deben ser únicas
cuando existen.

### 3. "Contame un bug difícil que hayas encontrado."

**Respuesta corta**: generábamos números de comprobante correlativos con un
`INSERT ... ON CONFLICT DO UPDATE ... RETURNING value`, que es atómico. Pero como
la sentencia devuelve filas, la ejecutábamos con `select_value`, o sea que para
ActiveRecord **era un SELECT**. Y ActiveRecord tiene un query cache por request
que memoriza el resultado de un SQL con los mismos binds. Resultado: dentro de un
mismo request, la segunda llamada devolvía el mismo número sin tocar la base, y
nos quedaban dos comprobantes con la misma referencia.

**Por qué era difícil**: el cache está apagado fuera del executor de Rails, así
que el test unitario pasaba. Sólo fallaba en producción, y de forma intermitente.

**El arreglo**: envolver la sentencia en `connection.uncached { ... }` y llamar a
`clear_query_cache` después, para que nadie lea un estado viejo de esa tabla en
el resto del request. Y un test de regresión que **prende el cache a mano** con
`connection.cache do ... end` y verifica que tres llamadas den 1, 2 y 3.

**La lección generalizable**: cualquier SQL crudo que escriba pero devuelva filas
no debe ejecutarse con `select_*`. Aplica igual a `nextval`, a
`pg_advisory_lock` y a un `SELECT ... FOR UPDATE` ejecutado con `select_all`, que
es peor porque creés que tenés el lock y no lo tenés.

### 4. "¿Cuándo usás `after_save` y cuándo `after_commit`?"

**Respuesta corta**: `after_save` para escrituras en la **misma** base que deben
revertirse junto con el resto de la transacción —por ejemplo recalcular un total
derivado—. `after_commit` para **cualquier** efecto fuera de la transacción: un
mail, un job, un webhook, invalidar un cache. Si mandás el mail en `after_save` y
la transacción hace rollback, mandaste un mail sobre algo que no existe.

**El trade-off**: `after_commit` corre fuera de la transacción, así que si falla
no hay rollback posible: hay que manejar el error a mano. Y en tests con
transacciones envolventes no dispara, lo cual esconde bugs en las dos
direcciones.

**El remate**: la trampa fina es que `after_commit` dispara cuando commitea la
transacción a la que el registro está asociado, que con anidamiento no siempre es
la más externa. Desde Rails 7.2 hay
`ActiveRecord.after_all_transactions_commit`, que garantiza la más externa. Es lo
que usamos para el "empujoncito" del outbox: el evento se escribe **dentro** de
la transacción (así commitea atómicamente con el cambio de estado) y lo único que
sale afuera es el encolado del publicador.

### 5. "¿Cómo hacés una migración sin downtime en una tabla grande?"

**Respuesta corta**: lo primero es entender que en Postgres el DDL toma
`ACCESS EXCLUSIVE`, que bloquea hasta los `SELECT`, y que **el lock se encola**:
una migración esperando un lock deja atrás una fila de queries, y el sitio se cae
antes de que la migración arranque. Por eso lo primero es
`SET lock_timeout = '10s'`: si no consigue el lock rápido, aborta y reintentás,
en vez de tumbar todo.

Después, por operación: índices con `algorithm: :concurrently` (fuera de una
transacción); `NOT NULL` con un CHECK `NOT VALID` primero, validado aparte;
renombres con **expand-contract** en cuatro deploys; y los backfills en una
migración separada, en lotes, nunca en la misma que el DDL.

**El trade-off**: `CONCURRENTLY` tarda el doble, no puede correr dentro de una
transacción, y si falla deja un índice **inválido** que hay que borrar y rehacer.
Expand-contract son cuatro deploys en vez de uno.

**El remate**: no confío en mi criterio, uso `strong_migrations`, que conoce el
catálogo y te frena en desarrollo con el reemplazo seguro escrito en el error. Y
le configuro `target_version` con la versión de Postgres de **producción**, no la
de mi máquina, porque qué es seguro depende de eso: `add_column` con default es
instantáneo desde PG 11 y reescribe la tabla en versiones anteriores.

### 6. "¿Qué diferencias te sorprendieron viniendo de Java?"

**Respuesta corta**, las cinco que más me costaron:

1. **No hay sesión de persistencia ni dirty checking diferido.** Cada `save` es
   un `UPDATE` inmediato. No hay `flush`, no hay `EntityManager`, no hay
   `LazyInitializationException`: una asociación se carga cuando la tocás, desde
   donde sea. Eso convierte un problema de corrección en uno de performance
   silencioso.
2. **`^` y `$` son anclas de línea, siempre.** En Java son de input salvo
   `MULTILINE`, y `matches()` ancla toda la cadena. En Ruby hay que usar `\A` y
   `\z`, y no hacerlo es una vulnerabilidad real, no un detalle de estilo.
3. **Todo es truthy salvo `nil` y `false`.** Un `"false"` que viene de un query
   param es verdadero, y el compilador no está para avisarte.
4. **`.to_i` no falla nunca.** `"10 unidades".to_i` es 10. Sobre input externo va
   `Integer()`, que es el `parseInt` de toda la vida.
5. **La carga de código es por convención de nombre y es perezosa en
   desarrollo.** Un archivo mal nombrado no falla hasta que alguien pide esa
   constante — o hasta el eager load de producción. Por eso `zeitwerk:check` y
   `eager_load = true` en CI son obligatorios.

**El remate**: lo que **sí** se traduce directo es el razonamiento de base de
datos. Las invariantes van en la base con CHECK constraints e índices únicos,
igual que en cualquier stack; el ORM es una comodidad, no una garantía. Esa parte
del oficio viaja intacta.

---

## Para seguir

- `docs/03-base-de-datos-y-activerecord.md` — migraciones seguras, constraints, callbacks en detalle.
- `docs/04-optimizacion-de-queries.md` — N+1, `includes` vs `joins`, EXPLAIN, keyset pagination.
- `docs/06-concurrencia-transacciones-y-locking.md` — lost update, `FOR UPDATE`, optimistic locking, deadlocks.
- `docs/07-colas-jobs-y-mensajeria.md` — outbox transaccional, idempotencia de jobs, at-least-once.
