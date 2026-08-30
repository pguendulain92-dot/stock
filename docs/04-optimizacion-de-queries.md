# Optimización de queries: del N+1 al plan de ejecución

Este es el documento más práctico de la serie. Acá vas a encontrar: cuándo se
ejecuta realmente una `ActiveRecord::Relation` y por qué eso te deja componer
consultas; las cuatro formas de crear un N+1 sin darte cuenta y cómo se detectan;
la diferencia real —en SQL generado— entre `includes`, `preload`, `eager_load` y
`joins`; el N+1 de agregación que `includes` **no** arregla; el costo en memoria
medido de `pluck` vs `select` vs cargar modelos; paginación por keyset contra
`OFFSET`; el catálogo de índices de Postgres con los ejemplos reales de este
schema; por qué un índice no se usa; cómo leer un `EXPLAIN ANALYZE`; y cuándo
desnormalizar, cachear o irse a operaciones bulk.

Todos los planes de ejecución que aparecen abajo los corrí contra
`stock_development` (PostgreSQL 16.13) mientras escribía esto. Los números de
memoria salen de `memory_profiler`. Cuando algo no se puede medir en este repo
lo digo explícitamente en vez de inventarlo.

Escrito para vos, que venís de Spring + JPA/Hibernate. Cada vez que hay una
analogía la marco, y sobre todo marco **dónde se rompe**, que es exactamente
donde se equivoca la gente que llega desde Java.

> Relacionado: docs/03 cubre el pool de conexiones, migraciones, tipos y
> constraints. Acá arrancamos donde termina aquel: la query ya está escrita,
> ¿por qué es lenta?

---

## 1. El cambio mental respecto de Hibernate

Antes de tocar una query hay que desarmar tres supuestos que traés de JPA. No
son detalles: son la causa raíz de la mayoría de los problemas de performance
que escribe un javero en su primer mes de Rails.

| Lo que asumís desde JPA | La realidad en Active Record | Consecuencia |
|---|---|---|
| Hay un persistence context que agrupa el trabajo | **No existe** | No hay `flush()`, no hay write-behind, el SQL sale cuando lo escribís |
| Una asociación no cargada fuera de sesión explota (`LazyInitializationException`) | **Nunca explota: hace la query ahí mismo** | El N+1 es silencioso; no falla, sólo se pone lento |
| El identity map te devuelve la misma instancia | **No existe** | Dos `find` del mismo id son dos objetos distintos con datos posiblemente distintos |
| `fetch = EAGER` / `@EntityGraph` resuelven el fetch plan en el mapeo | El fetch plan se pide **en cada consulta** con `includes` | Si te olvidás en un listado, tenés N+1 |
| Cache de segundo nivel | **No hay** | `Rails.cache` a mano, con clave explícita |
| `@Query` en un `Repository` | Query Objects (`app/queries/`) que devuelven una `Relation` | Componible: el que llama todavía puede filtrar y paginar |

La única cosa que sí se parece a un caché de primer nivel es el **query cache
de la request**: dentro de una misma request/job, ActiveRecord memoriza el
resultado de un SQL idéntico. Lo ves en el log como `CACHE`:

```
Category Load (0.7ms)  SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
CACHE Category Load (0.0ms)  SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
CACHE Category Load (0.0ms)  SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
```

Ojo con esto porque **enmascara N+1 en desarrollo**: si tus 15 productos comparten
3 categorías, el N+1 se ve como 3 queries y no como 15. En producción, con 5000
categorías distintas, se ve como 5000. No confíes en el conteo de queries de un
dataset de seed chiquito.

---

## 2. Lazy loading de `ActiveRecord::Relation`

### 2.1 Una Relation no es una lista: es una consulta a medio armar

`Product.kept.active.order(:name)` no toca la base. Es un objeto que acumula
nodos de Arel. La query sale recién cuando llamás un **método terminal**.

```ruby
rel = Products::Search.call(term: "tornillo")   # 0 queries
rel = rel.where(category_id: 3)                 # 0 queries
rel = rel.limit(25)                             # 0 queries
puts rel.to_sql                                 # 0 queries: te muestra el SQL
rel.each { ... }                                # <- ACÁ sale la query
```

Eso es lo que hace posible el contrato de `ApplicationQuery`
(`app/queries/application_query.rb:19-20`), que es explícito al respecto:

> **REGLA: devolver Relation, no Array.** `to_a` fuerza la ejecución y mata la
> lazy evaluation, la paginación y cualquier optimización posterior.

Por eso `Products::Search#call` (`app/queries/products/search.rb:43-52`) termina
en `relation.includes(:category).order(...)` y no en `.to_a`: el controller
recibe algo que todavía puede paginar, y `pagy` puede meterle `LIMIT/OFFSET` y
un `COUNT` sin que el query object sepa nada de paginación. Es composición al
estilo `Specification` de Spring Data, pero sin tener que declarar interfaces.

### 2.2 Qué dispara la query y qué no

| Método | ¿Ejecuta? | SQL que genera |
|---|---|---|
| `where`, `order`, `limit`, `joins`, `includes`, `select`, `group` | ❌ | ninguno (encadenan) |
| `to_sql`, `explain` | ❌ (`explain` sí ejecuta con `:analyze`) | te muestra el SQL |
| `to_a`, `each`, `map`, `load` | ✅ | `SELECT ...` completo, instancia modelos |
| `first`, `last`, `find`, `find_by` | ✅ | agrega `ORDER BY id` + `LIMIT 1` |
| `count`, `sum`, `average`, `minimum` | ✅ | agregación en la base, **no** carga filas |
| `pluck` | ✅ | `SELECT col1, col2` → arrays de Ruby, sin modelos |
| `exists?`, `any?`, `none?` | ✅ | `SELECT 1 ... LIMIT 1` |
| `size` | depende | si está cargada usa `length` (0 queries), si no hace `COUNT` |
| `find_each`, `in_batches` | ✅ | varias queries paginadas por PK |

### 2.3 `count` vs `size` vs `length`

Verificado con `rel = Product.kept; rel.size; rel.count; rel.load; rel.size; rel.count`:
`size` sobre una relación no cargada hace `COUNT(*)`, pero después del `load` usa
el array y no consulta. `count` **siempre** va a la base, aunque ya tengas las
filas en memoria — por eso un `.count` en la vista después de un `each` es una
query regalada. `length` fuerza la carga completa. Regla: **`size` es el default
correcto**.

### 2.4 Cómo ver el SQL mientras trabajás

En desarrollo ya está configurado (`config/environments/development.rb:55-58`):

```ruby
config.active_record.verbose_query_logs = true      # muestra la LÍNEA de tu código que disparó la query
config.active_record.query_log_tags_enabled = true  # agrega /*application='Stock',controller=...*/ al SQL
```

`verbose_query_logs` es lo que te imprime el `↳ app/models/product.rb:69:in
'total_available'` debajo de cada query. Es la forma más rápida que hay de
encontrar quién generó un N+1. Los query log tags viajan hasta
`pg_stat_activity`, así que en producción podés ver **qué controller o job** está
corriendo una query lenta sin adivinar.

---

## 3. N+1: las cuatro formas de crearlo sin darte cuenta

El N+1 es: una query para traer N registros, más una query por cada uno para
traer algo asociado. Total N+1. Con 25 ms de latencia de red y 200 filas son 5
segundos de una request que debería tardar 30 ms.

### 3.1 Forma 1: tocar una asociación dentro de un loop

```bash
$ bin/rails runner 'Product.limit(3).each { |p| p.category&.name }'

Product Load  (14.6ms)  SELECT "products".* FROM "products" LIMIT 3
Category Load  (0.7ms)  SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
CACHE Category Load     SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
CACHE Category Load     SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2 LIMIT 1
```

El más obvio y el más fácil de arreglar (`includes(:category)`). Fijate el
`CACHE`: en el seed los 3 productos comparten categoría, así que sólo se ve UNA
query real. En producción serían 3.

### 3.2 Forma 2: un `count` o `sum` dentro del serializer

`ProductSerializer` (`app/serializers/product_serializer.rb`) documenta
explícitamente por qué **no** hace esto:

```ruby
# `availability` se pasa POR PARÁMETRO, precalculada con un GROUP BY.
# No la calculamos acá adentro: eso sería el N+1 en persona.
availability: options[:availability],
```

Este es el peor de los cuatro porque el serializer suele estar en otro archivo,
lejos del controller, y nadie lo mira cuando debuggea "el listado está lento".

### 3.3 Forma 3: un método del modelo que consulta

`app/models/product.rb:67-69` tiene tres métodos que son una trampa perfecta, y
el propio código lo avisa:

```ruby
# OJO: esto dispara una query por producto si lo llamás en un loop (N+1).
def total_on_hand  = stock_items.sum(:quantity_on_hand)
def total_reserved = stock_items.sum(:quantity_reserved)
def total_available = stock_items.sum(:quantity_available)
```

Se ve así:

```bash
$ bin/rails runner 'Product.limit(3).each { |p| p.total_available }'

StockItem Sum (0.8ms)  SELECT SUM("stock_items"."quantity_available") FROM "stock_items" WHERE "stock_items"."product_id" = 1
  ↳ app/models/product.rb:69:in 'total_available'
StockItem Sum (0.4ms)  SELECT SUM(...) WHERE "stock_items"."product_id" = 2
  ↳ app/models/product.rb:69:in 'total_available'
StockItem Sum (0.3ms)  SELECT SUM(...) WHERE "stock_items"."product_id" = 3
  ↳ app/models/product.rb:69:in 'total_available'
```

Desde el call site (`products.each(&:total_available)`) no hay **ninguna** pista
sintáctica de que eso pega en la base. Es el equivalente a un getter de una
entidad JPA que por dentro hace un `@Query`: técnicamente legal, operacionalmente
una bomba.

### 3.4 Forma 4: la vista toca una asociación

La vista de productos (`app/views/products/index.html.erb:38-44`) deja el
comentario justamente porque este caso es invisible desde el controller:

```erb
<%# product.category NO dispara query: el query object hizo includes(:category) %>
<td><%= product.category&.name || "—" %></td>
<%# @availability se calculó con UNA query agregada en el controller %>
<td><%= @availability.dig(product.id, :available) || 0 %></td>
```

Lo mismo en `app/views/stock_movements/_table.html.erb:18-22`, que toca
`m.product`, `m.warehouse` y `m.user`. Funciona porque
`StockMovements::Ledger#call` (`app/queries/stock_movements/ledger.rb:58`) hace
`includes(:product, :warehouse, :user)`. Si mañana alguien saca ese `includes`
"porque no lo usa el endpoint JSON", la vista HTML se convierte en 3N queries y
nadie se entera hasta que un depósito grande abre el listado.

### 3.5 El número medido en este repo

El camino real de `ProductsController#index`
(`app/controllers/products_controller.rb:6-14`) contra la versión ingenua:

```bash
# Versión ingenua: category en la vista + total_available por producto
$ bin/rails runner 'Product.kept.order(:name).limit(25).each { |p| p.category&.name; p.total_available }'
=> 23 queries para 15 productos

# El camino real: Products::Search (includes) + pagy count + StockItems::Availability
$ bin/rails runner '... Products::Search.call + Availability.call ...'
=> 4 queries
  1. SELECT "products".* FROM "products" WHERE "discarded_at" IS NULL ORDER BY "name" ASC, "id" ASC
  2. SELECT "categories".* FROM "categories" WHERE "categories"."id" IN (4, 2, 6, 9, 10, 3, 7)
  3. SELECT COUNT(*) FROM "products" WHERE "products"."discarded_at" IS NULL
  4. SELECT "stock_items"."product_id", SUM(quantity_on_hand), SUM(quantity_reserved), SUM(quantity_available)
     FROM "stock_items" WHERE "product_id" IN (...) GROUP BY "product_id"
```

23 son menos que las 31 teóricas (1 + 15 + 15) porque el query cache deduplicó
las categorías repetidas — otra vez la trampa del dataset chico. Lo importante
es lo otro: **4 es una constante**. Con 25, 100 o 1000 productos por página
siguen siendo 4 queries. Ese es el objetivo: que el número de queries no dependa
del número de filas.

---

## 4. Cómo se detecta un N+1

### 4.1 Bullet, configurado para romper el CI

Está en el Gemfile (grupo `development, test`) y configurado en
`spec/support/bullet.rb`:

```ruby
Bullet.enable = true
Bullet.raise = true                    # <- el N+1 LEVANTA UNA EXCEPCIÓN y el test falla
Bullet.unused_eager_loading_enable = true  # detecta también el problema INVERSO
```

Dos decisiones acá que conviene poder defender:

1. **`raise = true`.** Un logger que nadie lee no sirve. La única forma de que
   los N+1 no vuelvan es que el CI los rechace.
2. **Sólo se activa en los ejemplos marcados con `:n_plus_one`**
   (`spec/rails_helper.rb:61-69`). El comentario explica el porqué: en muchos
   specs unitarios el "N+1" es intencional (probás un método que consulta) y
   activarlo globalmente genera falsos positivos que la gente termina
   silenciando... y ahí perdés la herramienta. Es exactamente el mismo problema
   que un SpotBugs con 400 warnings ignorados.

El test que lo usa (`spec/queries/products_search_spec.rb:64-71`):

```ruby
describe "prevención de N+1", :n_plus_one do
  it "trae la categoría con includes" do
    create_list(:product, 5, :with_category)
    described_class.call.to_a.each { |p| p.category&.name }
  end
end
```

`unused_eager_loading_enable` detecta el problema opuesto: hiciste `includes` de
algo que después no usaste. Es una query de más y memoria desperdiciada; en un
listado de 500 filas con una asociación gorda se nota.

### 4.2 `strict_loading`: la versión de Rails, sin gema

`Product.strict_loading.limit(10).each { |p| p.category }` levanta
`ActiveRecord::StrictLoadingViolationError`. Es lo más parecido que hay a la
`LazyInitializationException` de Hibernate, pero *opt-in*: se activa por
asociación (`has_many :x, strict_loading: true`), por modelo
(`self.strict_loading_by_default = true`) o por app. Este repo no lo usa: eligió
Bullet porque además detecta el eager loading inútil.

### 4.3 Las otras herramientas

| Herramienta | Qué te da | Estado en este repo |
|---|---|---|
| `verbose_query_logs` | la línea de Ruby que disparó cada query | ✅ activo en desarrollo |
| `query_log_tags` | comentario SQL con controller/action/job, visible en `pg_stat_activity` | ✅ activo en desarrollo |
| `bullet` | detecta N+1 y eager loading inútil, rompe el test | ✅ en test |
| `rack-mini-profiler` | badge flotante con desglose de tiempo SQL/render por request | ✅ en el Gemfile (`require: false`) |
| `prosopite` | detecta N+1 mirando queries *estructuralmente idénticas* seguidas; menos falsos negativos que Bullet en asociaciones raras y en SQL crudo | ❌ no está |
| APM (Datadog, Scout, New Relic) | traza de producción con la pila de queries por endpoint | ❌ no está |

La diferencia entre Bullet y prosopite en una frase: Bullet instrumenta las
**asociaciones de ActiveRecord**, prosopite mira el **stream de SQL** y detecta
queries con la misma "forma" ejecutadas consecutivamente desde la misma línea.
Por eso prosopite agarra N+1 escritos con SQL crudo o con `find_by` en un loop,
que a Bullet se le escapan.

---

## 5. `includes` vs `preload` vs `eager_load` vs `joins`

Esta es la pregunta de entrevista más frecuente del tema, y la mayoría de la
gente contesta "todos hacen lo mismo". No.

### 5.1 El SQL real de cada uno

```bash
$ bin/rails runner 'Product.preload(:category).limit(3).to_a'
SELECT "products".* FROM "products" LIMIT 3
SELECT "categories".* FROM "categories" WHERE "categories"."id" = 2
```

**`preload`**: siempre dos queries (una por tabla), nunca un JOIN. No podés
filtrar por la tabla asociada.

```bash
$ bin/rails runner 'Product.eager_load(:category).limit(3).to_a'
SELECT "products"."id" AS t0_r0, "products"."active" AS t0_r1, ... ,
       "categories"."id" AS t1_r0, "categories"."active" AS t1_r1, ...
FROM "products" LEFT OUTER JOIN "categories" ON "categories"."id" = "products"."category_id" LIMIT 3
```

**`eager_load`**: una sola query con `LEFT OUTER JOIN` y aliases `t0_r0, t1_r0…`
para desambiguar columnas. Sí podés filtrar por la asociada.

```bash
$ bin/rails runner 'Product.joins(:category).limit(3).to_a'
SELECT "products".* FROM "products" INNER JOIN "categories" ON "categories"."id" = "products"."category_id" LIMIT 3
```

**`joins`**: `INNER JOIN` para **filtrar**, pero **no carga nada** de la
asociación. Si después tocás `product.category`, tenés el N+1 igual — y encima
perdiste las filas sin categoría por el INNER.

### 5.2 `includes` es "elegí vos"

`includes` no genera SQL propio: deja que Rails decida entre la estrategia de
`preload` (2 queries) y la de `eager_load` (LEFT JOIN). Se pasa a LEFT JOIN
cuando la query **necesita** referenciar la tabla asociada:

```bash
# Condición con hash sobre la asociación -> Rails detecta la referencia solo
$ bin/rails runner 'Product.includes(:category).where(categories: { slug: "x" }).limit(3).to_a'
SELECT "products"."id" AS t0_r0, ... FROM "products"
LEFT OUTER JOIN "categories" ON "categories"."id" = "products"."category_id"
WHERE "categories"."slug" = 'x' LIMIT 3
```

Pero con una condición **string** Rails no puede adivinar, y explota:

```bash
$ bin/rails runner 'Product.includes(:category).where("categories.slug = ?", "x").limit(3).to_a'
SELECT "products".* FROM "products" WHERE (categories.slug = 'x') LIMIT 3
=> ActiveRecord::StatementInvalid: PG::UndefinedTable: ERROR: missing FROM-clause entry for table "categories"
```

Ahí necesitás `.references(:category)`. Regla práctica: **si escribís la
condición como string, escribí `references` al lado**.

### 5.3 Por qué `eager_load` con `has_many` puede ser PEOR

Un `LEFT JOIN` uno-a-muchos **multiplica filas** del lado izquierdo. Medido acá:

```bash
$ bin/rails runner 'puts ActiveRecord::Base.connection.select_all(Product.eager_load(:stock_items).to_sql).rows.size'
48        # filas crudas del LEFT JOIN
# productos = 15, stock_items = 48
```

15 productos vuelven como **48 filas**, cada una arrastrando las 17 columnas de
`products` repetidas. Con 500 productos × 4 depósitos y descripciones largas, eso
son megabytes de red y de deserialización para producir el mismo objeto.
`preload` trae 15 + 48 filas, cada una una sola vez.

Peor todavía: `eager_load` + `limit` sobre un `has_many` obliga a Rails a hacer
**dos** queries igual, porque el `LIMIT` no puede aplicarse sobre filas
multiplicadas:

```bash
$ bin/rails runner 'Product.eager_load(:stock_items).limit(3).to_a'
SELECT DISTINCT "products"."id" FROM "products"
  LEFT OUTER JOIN "stock_items" ON "stock_items"."product_id" = "products"."id" LIMIT 3
SELECT "products"."id" AS t0_r0, ... FROM "products"
  LEFT OUTER JOIN "stock_items" ON ... WHERE "products"."id" IN (1, 2, 3)
```

Un `SELECT DISTINCT` con JOIN es un sort o un hash agregado sobre toda la tabla.
Le pagaste el precio del JOIN y del DISTINCT para terminar haciendo dos queries
igual. Por eso `Product.with_associations` (`app/models/product.rb:60`) usa
`includes` y no `eager_load`.

### 5.4 Tabla de decisión

| Quiero… | Usá | SQL |
|---|---|---|
| Cargar la asociación para mostrarla | `preload` | 2+ queries, `IN (...)` |
| Cargar **y** filtrar/ordenar por la asociada | `eager_load` (o `includes` + `references`) | 1 query, `LEFT OUTER JOIN` |
| Sólo filtrar, no necesito los datos | `joins` | `INNER JOIN`, no carga |
| Filtrar sin perder filas del lado izquierdo | `left_joins` | `LEFT OUTER JOIN`, no carga |
| Que Rails elija | `includes` | depende de si hay `references` |
| Filtrar por un `has_many` sin duplicar filas | **subquery**, no join | `WHERE id IN (SELECT ...)` |

La última fila es la que casi nadie menciona, y este repo la usa dos veces con
el razonamiento escrito al lado (`app/queries/products/search.rb:71-78`):

```ruby
# `where(id: subquery)` genera un IN (SELECT ...) que Postgres suele
# convertir en semi-join. Es MEJOR que `joins(:product_suppliers)` acá
# porque un join uno-a-muchos DUPLICA filas del lado izquierdo si un
# producto tiene 3 proveedores, y después tenés que meter un `.distinct`
# que fuerza un sort/hash agregado carísimo.
def by_supplier(relation, supplier_id)
  relation.where(id: ProductSupplier.where(supplier_id:).select(:product_id))
end
```

Fijate que el subquery se arma con `.select(:product_id)` sobre una Relation, no
con `.pluck`. `pluck` traería los ids a Ruby y los mandaría de vuelta como una
lista literal; `select` deja todo adentro de Postgres. La misma técnica está en
`app/queries/stock_items/low_stock.rb:30`.

### 5.5 Las trampas de `joins`

```ruby
# ❌ duplica productos si hay 3 proveedores
Product.joins(:suppliers).where(suppliers: { active: true })

# ❌ arreglarlo con distinct te cuesta un sort de toda la tabla
Product.joins(:suppliers).where(suppliers: { active: true }).distinct

# ✅ semi-join: no duplica y el planner lo resuelve mejor
Product.where(id: ProductSupplier.joins(:supplier).where(suppliers: { active: true }).select(:product_id))
```

Y `joins(:x).includes(:x)` es legal pero suele ser un error: Rails hace el INNER
JOIN para filtrar **y además** el preload. Si querés las dos cosas en una sola
pasada, es `eager_load`.

---

## 6. El N+1 de agregación: lo que `includes` NO arregla

Este merece sección propia porque es donde se cae la respuesta estándar
("¿N+1? `includes` y listo").

El caso real es `StockItems::Availability`
(`app/queries/stock_items/availability.rb`), y el comentario del archivo es
tajante:

> La versión ingenua, la que sale sola:
> `products.map { |p| [p.id, p.stock_items.sum(:quantity_available)] }`
> Para 200 productos son 201 queries. Y **`includes` NO lo arregla**.

¿Por qué no lo arregla? Porque `sum` sobre una asociación tiene dos
comportamientos distintos según cómo lo llames:

```ruby
product.stock_items.sum(:quantity_available)     # -> SELECT SUM(...) : una query POR PRODUCTO, aunque hayas hecho includes
product.stock_items.to_a.sum(&:quantity_available)  # -> sin query, pero trae TODAS las filas a memoria
```

O sea: o tenés N queries, o tenés todas las filas de `stock_items` en RAM. Con
50.000 items eso son cientos de MB de objetos ActiveRecord para producir un
número por producto.

La solución es mover la agregación a la base, con **una** query:

```ruby
# app/queries/stock_items/availability.rb:30-46
relation
  .group(:product_id)
  .pluck(
    :product_id,
    Arel.sql("SUM(quantity_on_hand)"),
    Arel.sql("SUM(quantity_reserved)"),
    Arel.sql("SUM(quantity_available)")
  )
  .to_h { |id, on_hand, reserved, available|
    [ id, { on_hand: on_hand.to_i, reserved: reserved.to_i, available: available.to_i } ]
  }
```

SQL generado y plan real:

```bash
$ bin/rails runner 'StockItems::Availability.call(product_ids: [1,2,3])'
StockItem Pluck (0.6ms)  SELECT "stock_items"."product_id", SUM(quantity_on_hand), SUM(quantity_reserved),
                         SUM(quantity_available) FROM "stock_items"
                         WHERE "stock_items"."product_id" IN (1, 2, 3) GROUP BY "stock_items"."product_id"
```

```
$ psql -d stock_development -c "EXPLAIN (ANALYZE, BUFFERS) SELECT product_id, SUM(quantity_on_hand),
    SUM(quantity_reserved), SUM(quantity_available) FROM stock_items WHERE product_id IN (1,2,3,4,5) GROUP BY product_id;"

 HashAggregate  (cost=1.96..2.08 rows=12 width=32) (actual time=0.031..0.032 rows=5 loops=1)
   Group Key: product_id
   Batches: 1  Memory Usage: 24kB
   ->  Seq Scan on stock_items  (cost=0.00..1.78 rows=18 width=20) (actual time=0.009..0.016 rows=18 loops=1)
         Filter: (product_id = ANY ('{1,2,3,4,5}'::bigint[]))
         Rows Removed by Filter: 30
 Execution Time: 0.064 ms
```

El controller lo consume así
(`app/controllers/api/v1/products_controller.rb:18-27`):

```ruby
# ── ESTA ES LA LÍNEA QUE EVITA EL N+1 DE AGREGACIÓN ──────────────────
availability = StockItems::Availability.call(product_ids: records.map(&:id))
...
data: records.map { |p| ProductSerializer.new(p, availability: availability[p.id]).as_json }
```

Y `Arel.sql` no es cosmético: es la forma de decirle a Rails "esto es SQL que yo
escribí y me hago cargo". Sin eso, Rails 7.1+ levanta
`ActiveRecord::UnknownAttributeReference` para protegerte de inyección en
`pluck`/`order`. **Nunca** metas input del usuario adentro de un `Arel.sql`.

El mismo patrón, con `FILTER`, en `WarehousesController#index`
(`app/controllers/warehouses_controller.rb:10-15`): una query agregada para las
estadísticas de todos los depósitos en vez de 3 queries por depósito en la vista.

```ruby
@stats = StockItem.group(:warehouse_id).pluck(
  :warehouse_id,
  Arel.sql("COUNT(*)"),
  Arel.sql("SUM(quantity_on_hand)"),
  Arel.sql("COUNT(*) FILTER (WHERE quantity_available <= reorder_point AND reorder_point > 0)")
).to_h { |id, skus, units, low| [ id, { skus:, units: units.to_i, low: } ] }
```

`COUNT(*) FILTER (WHERE ...)` es SQL estándar y te deja meter varios contadores
condicionales en un solo scan. En Java lo escribirías con tres `case when` o con
tres queries; acá es una.

---

## 7. `pluck` vs `select` vs cargar modelos: la memoria medida

Instanciar un modelo ActiveRecord no es gratis: por fila hay un objeto, un
`@attributes` con tipos, un `AttributeSet`, y el tracking de cambios.

Medición real con `memory_profiler` sobre 50.000 filas de `stock_movements`
(inserté las filas dentro de una transacción y le hice rollback, así que la base
quedó como estaba):

```bash
$ bin/rails runner /tmp/mem.rb
filas en stock_movements: 51102
pluck(:id, :quantity)        -> 4.4 MB, 101.481 objetos
select(:id,:quantity).to_a   -> 45.2 MB, 306.307 objetos
to_a.map (modelos completos) -> 68.0 MB, 650.812 objetos
```

**`pluck` usa 15 veces menos memoria que cargar los modelos completos.** Y
`select` parcial ayuda pero no tanto: seguís pagando el objeto AR por fila.

| Necesito… | Usá | Costo |
|---|---|---|
| Un hash id → valor, un array de ids, alimentar otra query | `pluck` | mínimo: arrays de Ruby |
| Los mismos objetos pero con menos columnas | `select(:a, :b)` | modelos AR con atributos parciales |
| Llamar métodos del modelo, serializar, validar | cargar completo | el más caro |
| Un solo número | `count` / `sum` / `average` | 1 fila, la base hace el trabajo |

Trampas concretas de cada uno:

**`select` parcial y el atributo faltante.** No devuelve `nil`: tira excepción.

```bash
$ bin/rails runner 'p = Product.select(:id, :sku).first; p.name'
=> ActiveModel::MissingAttributeError: missing attribute 'name' for Product
```

Es lo correcto (mejor fallar que mentir), pero se rompe lejos: pasás el objeto a
un serializer que toca una columna que no seleccionaste y explota en producción.

**`pluck` sobre una relación con `includes` fuerza el JOIN.** Sorpresa fea:

```bash
$ bin/rails runner 'Product.includes(:category).limit(3).pluck(:sku)'
SELECT "products"."sku" FROM "products"
LEFT OUTER JOIN "categories" ON "categories"."id" = "products"."category_id" LIMIT 3
```

Hiciste un JOIN que no necesitabas para nada. Si vas a hacer `pluck`, no
encadenes `includes`.

**`map` en Ruby vs agregación en SQL.** `StockItems::Valuation`
(`app/queries/stock_items/valuation.rb:5-18`) explica exactamente el trade-off:

> Traer 500.000 filas para multiplicar en Ruby es ~500 MB de objetos
> ActiveRecord, segundos de GC, y todo para devolver UN número.

y arriba de eso, el detalle de overflow que se olvida siempre:

```ruby
SUM(stock_items.quantity_on_hand::numeric * products.cost_cents)
```

`int4 * int8` puede pasarse de `int8` en un inventario grande. El cast a
`NUMERIC` (precisión arbitraria en Postgres) es el mismo razonamiento que `long`
vs `BigDecimal` en Java. Postgres **no** hace wraparound silencioso como Java:
tira `ERROR: bigint out of range`. Es preferible, pero igual te tira la request.

---

## 8. Lotes: `find_each`, `in_batches`, `find_in_batches`

### 8.1 Por qué existen

`Product.all.each` carga **todas** las filas en memoria antes de la primera
iteración. Con 2M de filas es un OOM. Los métodos de lote parten el trabajo, y
lo importante es **cómo** paginan:

```bash
$ bin/rails runner 'Product.find_each(batch_size: 5) { |p| p.id }'
SELECT "products".* FROM "products" ORDER BY "products"."id" ASC LIMIT 5
SELECT "products".* FROM "products" WHERE "products"."id" > 5  ORDER BY "products"."id" ASC LIMIT 5
SELECT "products".* FROM "products" WHERE "products"."id" > 10 ORDER BY "products"."id" ASC LIMIT 5
SELECT "products".* FROM "products" WHERE "products"."id" > 15 ORDER BY "products"."id" ASC LIMIT 5
```

`WHERE id > ?`, no `OFFSET`. Cada lote es un salto directo por el índice de la
PK: O(log n) sin importar cuántos lotes lleves. Con `OFFSET 1000000` Postgres
tiene que **generar y descartar** un millón de filas antes de devolverte 5.

| Método | Yield | Cuándo |
|---|---|---|
| `find_each` | un **registro** por vez | procesar fila por fila |
| `find_in_batches` | un **array** de registros | necesitás el lote entero (ej. mandar un batch a una API) |
| `in_batches` | una **Relation** por lote | querés `update_all`/`delete_all` sobre el lote sin instanciar nada |

`in_batches` es el que devuelve una Relation, y por eso es el que usa el job de
limpieza (`app/jobs/cleanup/expired_records_job.rb:43-50`):

```ruby
def delete_in_batches(relation)
  total = 0
  # `in_batches` pagina por PK (`WHERE id > ?`), no con OFFSET: es O(1) por
  # lote sin importar cuántas filas haya. `delete_all` va directo al SQL,
  # sin instanciar modelos ni correr callbacks — que es lo que querés acá.
  relation.in_batches(of: BATCH) { |batch| total += batch.delete_all }
  total
end
```

El motivo de fondo está en el header del job y es de Postgres, no de Rails: un
`DELETE` masivo deja tuplas muertas que el autovacuum no da abasto a limpiar, la
tabla queda hinchada (*bloat*) y las queries se degradan aunque queden pocas
filas vivas. Lotes chicos y frecuentes mantienen al autovacuum al día. A escala
real la respuesta buena es **particionar por fecha y hacer `DROP PARTITION`**,
que es instantáneo y no genera tuplas muertas.

`Stock::ExpireReservations` (`app/services/stock/expire_reservations.rb:36-45`)
usa `in_batches` por otra razón: transacción **por reserva**, no una gigante para
las 50.000. Una transacción larga en Postgres mantiene locks tomados, frena el
VACUUM (no puede limpiar tuplas más nuevas que ella) y si falla al final perdés
todo el trabajo.

### 8.2 La trampa: `find_each` ignora tu `ORDER BY`

Hallazgo real de este repo. `StockItems::LowStock#call`
(`app/queries/stock_items/low_stock.rb:33-36`) ordena por una expresión:

```ruby
relation.includes(:product, :warehouse)
        .order(Arel.sql("(quantity_available - reorder_point) ASC"), :id)
```

y `Stock::LowStockAlertJob` (`app/jobs/stock/low_stock_alert_job.rb:18`) lo
consume con `find_each`. Corrido de verdad:

```bash
$ bin/rails runner 'StockItems::LowStock.call.find_each(batch_size: 5) { |i| i.id }'
Scoped order is ignored, use :cursor with :order to configure custom order.
StockItem Load  SELECT "stock_items".* FROM ... ORDER BY "stock_items"."id" ASC LIMIT 5
```

El orden "más urgente primero" **se descarta**. Para el job da igual (alerta
sobre todos), pero si mañana alguien le pone un `limit` esperando "los 50 más
críticos", va a recibir los 50 de menor `id`. Es el tipo de bug que nadie
encuentra leyendo el diff.

También fijate que `find_each` **re-ejecuta el `includes` por lote**: en cada
iteración salen un `Product Load` y un `Warehouse Load` extra. Es correcto y
esperable, pero cuenta para tu presupuesto de queries.

### 8.3 `cursor:` y `order:` (Rails 8.1) y por qué no alcanza

Rails 8.1 permite un cursor compuesto:

```bash
$ bin/rails runner 'StockItem.find_each(batch_size: 20, cursor: [:warehouse_id, :id], order: [:asc, :asc]) { |i| i.id }'
SELECT ... ORDER BY "warehouse_id" ASC, "id" ASC LIMIT 20
SELECT ... WHERE ("warehouse_id" > 2 OR "warehouse_id" = 2 AND "id" > 14) ORDER BY ... LIMIT 20
SELECT ... WHERE ("warehouse_id" > 3 OR "warehouse_id" = 3 AND "id" > 30) ORDER BY ... LIMIT 20
```

Funciona, pero fijate que Rails genera el **OR expandido**, no la comparación de
tuplas `(a, b) > (x, y)`. Eso no es equivalente para el planner. La medición
está en §9.3 y la diferencia es de 32x.

---

## 9. Paginación: `OFFSET` vs KEYSET (cursor)

### 9.1 El costo de un OFFSET grande, medido

Inserté 303.000 movimientos en una transacción, corrí `ANALYZE`, medí, y le hice
rollback. Este es el plan real de `ORDER BY occurred_at DESC, id DESC LIMIT 50
OFFSET 100000`:

```
 Limit  (cost=40357.90..40363.74 rows=50 width=181) (actual time=145.616..152.380 rows=50 loops=1)
   Buffers: shared hit=4594, temp read=2121 written=3809
   ->  Gather Merge  (cost=28690.42..58160.61 rows=252584) (actual time=113.417..149.113 rows=100050 loops=1)
         Workers Planned: 2
         ->  Sort  (cost=27690.40..28006.13 rows=126292) (actual time=108.697..114.546 rows=33680 loops=3)
               Sort Key: occurred_at DESC, id DESC
               Sort Method: external merge  Disk: 10256kB
               ->  Parallel Seq Scan on stock_movements (actual time=0.025..12.836 rows=101034 loops=3)
 Execution Time: 153.356 ms
```

Leelo así: **`rows=100050` en el Gather Merge** para devolver 50. Materializó
cien mil filas, las ordenó (`external merge Disk: 10256kB` — se fue a disco) y
tiró 100.000. El costo crece linealmente con el número de página: la página 1
vuela, la 5000 tarda segundos.

Y hay un segundo problema, peor porque es de **corrección**: si alguien inserta
una fila mientras paginás, todo se corre un lugar y ves una fila repetida o te
salteás otra. En un ledger append-only, donde las inserciones van justo al
principio del orden, eso pasa todo el tiempo.

### 9.2 Keyset: el plan del mismo dataset

`StockMovements::Ledger` (`app/queries/stock_movements/ledger.rb:76-89`) pagina
por cursor:

```ruby
relation.where(
  "(stock_movements.occurred_at, stock_movements.id) < (?, ?)",
  Time.zone.parse(decoded.fetch("t")), decoded.fetch("i")
)
```

Con el filtro por `stock_item_id` (que es el caso del detalle de un ítem):

```
 Limit  (cost=0.43..153.54 rows=50 width=164) (actual time=0.019..0.210 rows=50 loops=1)
   Buffers: shared hit=101 read=24
   ->  Index Scan using index_stock_movements_ledger on stock_movements
       (cost=0.43..5607.24 rows=1831) (actual time=0.018..0.205 rows=50 loops=1)
         Index Cond: ((stock_item_id = 3) AND (ROW(occurred_at, id) < ROW((now() - '33:20:00'::interval), 99999999)))
 Execution Time: 0.247 ms
```

**0.25 ms contra 153 ms**, y esa diferencia es constante: la página 5000 cuesta
lo mismo que la 1. La clave está en `Index Cond`: la comparación de tuplas entró
**adentro de la condición del índice**, así que Postgres posiciona el cursor en
la entrada exacta y lee 50 entradas contiguas.

Compará con el mismo filtro pero paginando por offset:

```
 Limit (actual time=4.202..4.238 rows=50 loops=1)
   Buffers: shared hit=7238
   ->  Index Scan using index_stock_movements_ledger (actual time=0.014..4.050 rows=5050 loops=1)
         Index Cond: (stock_item_id = 3)
```

Usa el mismo índice, pero leyó **5050 filas para devolver 50**. Ese `rows=5050`
en el nodo hijo contra `rows=50` en el `Limit` es la firma visual del OFFSET.

### 9.3 Por qué la comparación de TUPLAS y no el OR

Este es el detalle que separa una buena respuesta de una excelente. Las dos
formas son lógicamente equivalentes:

```sql
-- A) tupla
WHERE stock_item_id = 3 AND (occurred_at, id) < ('2026-08-30 12:00', 99999999)

-- B) OR expandido (lo que genera find_each con cursor)
WHERE stock_item_id = 3 AND (occurred_at < '2026-08-30 12:00'
                             OR occurred_at = '2026-08-30 12:00' AND id < 99999999)
```

Pero para el planner **no lo son**. Mismo dataset, mismo índice:

```
=== A: TUPLA (a,b) < (x,y) ===
 Limit (actual time=0.021..0.068 rows=50 loops=1)
   ->  Index Only Scan using index_stock_movements_ledger
         Index Cond: ((stock_item_id = 3) AND (ROW(occurred_at, id) < ROW(..., 99999999)))
         Heap Fetches: 50
 Execution Time: 0.097 ms

=== B: OR expandido ===
 Limit (actual time=3.097..3.139 rows=50 loops=1)
   ->  Index Only Scan using index_stock_movements_ledger
         Index Cond: (stock_item_id = 3)
         Filter: ((occurred_at < ...) OR ((occurred_at = ...) AND (id < 99999999)))
         Rows Removed by Filter: 4000
         Heap Fetches: 4050
 Execution Time: 3.156 ms
```

**32x más lento.** Con la tupla, la condición completa es `Index Cond`: un
posicionamiento y a leer. Con el OR, la parte del `occurred_at` cae a `Filter`:
Postgres recorre **todas** las entradas de `stock_item_id = 3` desde el principio
y descarta 4000 en memoria. La lección: la comparación de tuplas es SQL estándar,
no es azúcar sintáctico, y es lo que le permite al planner meter todo el WHERE en
un solo rango del índice.

### 9.4 El índice tiene que tener el MISMO orden

El índice del ledger (`db/migrate/20260830160700_create_stock_movements.rb:80-81`):

```ruby
add_index :stock_movements, [ :stock_item_id, :occurred_at, :id ],
          order: { occurred_at: :desc, id: :desc },
          name: "index_stock_movements_ledger"
```

Tres cosas que tienen que coincidir para que esto funcione:

1. **Las columnas del cursor son sufijo del índice** después de la columna de
   igualdad (`stock_item_id`).
2. **El orden del índice (`DESC, DESC`) coincide con el `ORDER BY` de la query.**
   Por eso en el plan no aparece ningún nodo `Sort`. Un B-tree se puede recorrer
   en ambas direcciones, así que `(ASC, ASC)` también serviría para
   `ORDER BY ... DESC, ... DESC` — lo que **no** sirve es un índice `(a ASC, b ASC)`
   para `ORDER BY a ASC, b DESC`, porque eso no es ni el orden del índice ni su
   reverso exacto.
3. El cursor se serializa opaco (Base64 de un JSON,
   `app/queries/stock_movements/ledger.rb:66-72`), así que el día que cambie el
   criterio de orden no se rompen los clientes que guardaron un cursor.

### 9.5 Hallazgo: el ledger SIN filtro no tiene índice

Los índices de `stock_movements` son todos compuestos con la FK adelante:
`(stock_item_id, occurred_at, id)`, `(product_id, occurred_at)`,
`(warehouse_id, occurred_at)`. **No hay ninguno sobre `(occurred_at, id)` solo.**
Entonces una consulta al ledger global sin filtros no puede usar ninguno:

```
 Limit (actual time=34.804..39.970 rows=50 loops=1)
   ->  Gather Merge
         ->  Sort (Sort Key: occurred_at DESC, id DESC)
               ->  Parallel Seq Scan on stock_movements (actual rows=97667 loops=3)
                     Filter: (ROW(occurred_at, id) < ROW(...))
                     Rows Removed by Filter: 3367
 Execution Time: 40.043 ms
```

Con 300k filas son 40 ms de seq scan paralelo. Con 50M no arranca. Y hay dos
call sites que caen justo ahí: `DashboardController#index`
(`app/controllers/dashboard_controller.rb:12`, `Ledger.call(limit: 15)`) y
`Api::V1::StockMovementsController#index` cuando el cliente no manda filtros.
El arreglo es un `add_index :stock_movements, [:occurred_at, :id], order: { occurred_at: :desc, id: :desc }`
(o forzar un filtro obligatorio en el endpoint). Vale la pena mencionarlo:
saber leer un plan sirve justamente para encontrar esto antes de que duela.

### 9.6 El desempate por `id` no es opcional

`Products::Search::SORTS` (`app/queries/products/search.rb:25-30`) desempata
siempre:

```ruby
SORTS = {
  "name"   => { name: :asc,  id: :asc },
  "sku"    => { sku: :asc,   id: :asc },
  "newest" => { created_at: :desc, id: :desc },
  "price"  => { price_cents: :desc, id: :asc }
}.freeze
```

Sin el desempate, dos filas con el mismo `name` pueden salir en distinto orden en
páginas distintas (el orden de filas iguales no está definido y depende del plan,
que puede cambiar entre ejecuciones) y ves un producto dos veces o nunca. Es el
bug de paginación más común y el más difícil de creer cuando lo reportan. Hay un
test que lo custodia (`spec/queries/products_search_spec.rb:58-61`).

### 9.7 `pagy` y el COUNT

`pagy` hace paginación por offset, y eso implica **dos** queries: la página y un
`SELECT COUNT(*)` para calcular `total_pages`. En tablas grandes ese COUNT puede
costar más que la página. Opciones: `pagy_countless` (no muestra el total),
un conteo aproximado con `reltuples` de `pg_class`, o pasarse a keyset como hizo
el ledger. La config de este repo (`config/initializers/pagy.rb`) acota el
`limit` a 100, que es la otra mitad del problema:

```ruby
Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT[:max_limit] = 100     # sin esto, ?limit=100000 te tumba el proceso
Pagy::DEFAULT[:overflow] = :last_page
```

**Cualquier parámetro de paginación que venga del usuario tiene que estar
acotado.** El ledger hace lo mismo a mano con `MAX_LIMIT = 200` y
`limit.to_i.clamp(1, MAX_LIMIT)`.

---

## 10. Índices en PostgreSQL

### 10.1 Los cuatro tipos que importan

| Tipo | Para qué | Operadores | En este repo |
|---|---|---|---|
| **B-tree** (default) | `=`, `<`, `>`, `BETWEEN`, `IN`, `ORDER BY`, prefijo `LIKE 'abc%'` | casi todo | casi todos |
| **GIN** | valores compuestos: `jsonb`, arrays, trigramas, full-text | `@>`, `?`, `ILIKE '%x%'` con `pg_trgm` | `index_products_on_name_trgm`, `index_api_tokens_on_scopes`, `index_suppliers_on_metadata` |
| **GiST** | rangos, geometría, exclusion constraints | `&&` (overlap), `<@` | ❌ no está (`btree_gist` no está habilitada) |
| **BRIN** | tablas enormes con correlación física fuerte (append-only por fecha) | `<`, `>`, `BETWEEN` | ❌ no está |

Tamaños relativos: un BRIN sobre 50M filas pesa kilobytes contra gigabytes de un
B-tree, porque sólo guarda min/max por bloque de páginas. El candidato natural
acá es `stock_movements.occurred_at`: la tabla es append-only y `occurred_at`
crece monótonamente, que es exactamente la condición que BRIN necesita. El
trade-off: BRIN sirve para rangos amplios ("todo el mes pasado"), no para buscar
una fila puntual, y si la correlación física se rompe (reordenamientos, updates)
deja de servir.

GiST sería el tipo para un exclusion constraint del estilo "no puede haber dos
reservas solapadas del mismo item" — ver docs/03 §8.3, que también aclara que
`btree_gist` no está habilitada en este repo.

Las tres extensiones que sí están (`db/migrate/20260830154900_enable_postgres_extensions.rb`):
`citext`, `pg_trgm` y `btree_gin`. La última es la que deja combinar una columna
escalar (`category_id`) con una GIN (trigramas) en un mismo índice compuesto.

### 10.2 Compuestos y la regla del prefijo izquierdo

Un índice sobre `(a, b, c)` sirve para consultas sobre `a`, sobre `(a, b)` y
sobre `(a, b, c)`. **No** sirve (bien) para consultas sobre `b` sola o `c` sola.
Es la misma regla que en MySQL y en Oracle.

Este repo la aplica de forma explícita, y es una decisión que conviene poder
explicar (`db/migrate/20260830160600_create_stock_items.rb:23-32`):

```ruby
# index: false porque más abajo creamos índices COMPUESTOS que ya cubren
# estas columnas como prefijo izquierdo. [...] Este es EL desperdicio más
# común en schemas de Rails: `t.references` crea un índice automático y
# después uno agrega el compuesto sin pensar.
t.references :product,   null: false, index: false, foreign_key: { on_delete: :restrict }
t.references :warehouse, null: false, index: false, foreign_key: { on_delete: :restrict }
```

Y después:

```ruby
add_index :stock_items, [ :product_id, :warehouse_id ], unique: true
add_index :stock_items, [ :warehouse_id, :product_id ]
```

Los dos compuestos, en los dos órdenes, cubren las dos direcciones de búsqueda.
Un índice extra sobre `product_id` solo sería disco desperdiciado **y una
escritura más en cada INSERT/UPDATE** — que es la mitad que se olvida: los
índices no son gratis, se mantienen en cada escritura.

Un matiz importante que Postgres tiene y conviene saber: aunque un índice sobre
`(a, b)` no sea el ideal para filtrar por `b` sola, Postgres **puede** hacer un
scan completo del índice si le conviene. Lo vi en un plan real (§12.4): usó
`index_stock_movements_on_warehouse_id_and_occurred_at` con `Index Cond` sólo
sobre `occurred_at`, escaneando el índice entero (1096 buffers). Funcionó, pero
no es lo que querés: es "el índice como tabla angosta", no un lookup.

### 10.3 Índices parciales: los ejemplos reales

Un índice parcial sólo contiene las filas que cumplen un predicado. Es de lo
mejor que tiene Postgres y no existe en MySQL.

```ruby
# db/migrate/20260830160600_create_stock_items.rb:73-75
# "En una tabla de 5M filas donde 200 están bajas, este índice tiene 200
#  entradas en vez de 5M."
add_index :stock_items, [ :warehouse_id, :quantity_available ],
          where: "quantity_available <= reorder_point",
          name: "index_stock_items_needing_reorder"
```

```ruby
# db/migrate/20260830161100_create_outbox_events.rb:67-69
# La cola pendiente es chiquita aunque la tabla tenga 500M de eventos históricos.
add_index :outbox_events, :id, where: "published_at IS NULL",
          name: "index_outbox_events_unpublished"
```

```ruby
# db/migrate/20260830160700_create_stock_movements.rb:89-90
# Unique PARCIAL: los movimientos internos (sin clave) no compiten por el índice.
add_index :stock_movements, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"
```

```ruby
# db/migrate/20260830160500_create_product_suppliers.rb:33-34
# "Exactamente un proveedor preferido por producto", garantizado por la base.
add_index :product_suppliers, :product_id, unique: true, where: "preferred",
          name: "index_one_preferred_supplier_per_product"
```

Ese último es el uso más elegante: un **unique parcial** expresa una invariante
de negocio que en Java escribirías como una validación en el service y que se te
rompe bajo concurrencia.

**Para que Postgres use un índice parcial, el WHERE de la query tiene que
IMPLICAR el predicado del índice**, y el probador de implicaciones del planner es
limitado: en la práctica escribí la condición **igual** que en la migración. Por
eso `StockItems::LowStock` (`app/queries/stock_items/low_stock.rb:24`) usa
literalmente `where("quantity_available <= reorder_point")`.

Verificado:

```
$ psql -d stock_development -c "SET enable_seqscan = off;
    EXPLAIN (ANALYZE, BUFFERS) SELECT id, warehouse_id FROM stock_items
    WHERE quantity_available <= reorder_point AND reorder_point <> 0;"

 Index Scan using index_stock_items_needing_reorder on stock_items
   (cost=0.14..12.41 rows=15 width=16) (actual time=0.018..0.022 rows=13 loops=1)
   Filter: (reorder_point <> 0)
 Execution Time: 0.041 ms
```

Fijate que `quantity_available <= reorder_point` **no aparece** como `Filter`:
Postgres sabe que todas las filas del índice ya la cumplen. Sólo filtra por
`reorder_point <> 0`, que no está en el predicado del índice.

### 10.4 Índices sobre expresiones

Si filtrás por `f(columna)`, el índice sobre `columna` no sirve. Necesitás un
índice sobre la expresión:

```sql
CREATE INDEX index_products_on_lower_name ON products (lower(name));
-- sirve para: WHERE lower(name) = 'tornillo'
```

Este repo **evita** el problema en vez de indexar la expresión, que suele ser
mejor decisión: `products.sku` es `citext`
(`db/migrate/20260830160400_create_products.rb:15`), así que
`WHERE sku = 'tor-m5-20'` matchea `'TOR-M5-20'` usando el índice único normal.
El comentario de la migración de extensiones lo dice: sin `citext` tenés que
acordarte de hacer `.downcase` en **todos** los caminos de escritura, y alguien
se va a olvidar. Es una invariante que conviene bajar a la base.

Ojo con la contra de los índices sobre expresiones: la función tiene que ser
`IMMUTABLE`. `lower()` lo es; `now()` o cualquier cosa que dependa del
`TimeZone` de la sesión, no.

### 10.5 Índices para `ORDER BY`

Un `ORDER BY` sobre columnas indexadas en el mismo orden **elimina el nodo Sort**
del plan. El ledger lo hace explícito
(`db/migrate/20260830160700_create_stock_movements.rb:78-81`):

```ruby
# El orden DESC en el índice evita el paso de Sort en el plan de ejecución.
add_index :stock_movements, [ :stock_item_id, :occurred_at, :id ],
          order: { occurred_at: :desc, id: :desc }, name: "index_stock_movements_ledger"
```

Y el índice de productos sirve el WHERE **y** el ORDER BY al mismo tiempo
(`db/migrate/20260830160400_create_products.rb:60-65`):

```ruby
add_index :products, [ :category_id, :name ],
          where: "discarded_at IS NULL AND active",
          name: "index_products_active_by_category"
```

Parcial + compuesto + ordenado: cubre `WHERE category_id = ? AND discarded_at IS
NULL AND active ORDER BY name` en un solo Index Scan sin Sort.

Contraejemplo del propio repo, y es honesto verlo: `StockItems::LowStock` ordena
por `(quantity_available - reorder_point)`, una **expresión**, así que siempre
hay un nodo `Sort`:

```
 Sort  (cost=9.94..9.95 rows=1 width=96) (actual time=0.100..0.102 rows=13 loops=1)
   Sort Key: ((stock_items.quantity_available - stock_items.reorder_point)), stock_items.id
   Sort Method: quicksort  Memory: 26kB
```

Para el volumen de un reporte de reposición (decenas de filas) está perfecto. Si
creciera, la solución sería un índice sobre esa expresión.

### 10.6 Covering indexes e `INCLUDE`

Un **Index Only Scan** es cuando Postgres responde la query sin tocar la tabla,
porque todas las columnas que pedís están en el índice. `INCLUDE` (PG 11+) deja
agregar columnas al índice **sin** que formen parte de la clave de búsqueda: no
las podés usar en el `WHERE`, pero evitan ir al heap.

Lo probé de verdad, creando el índice dentro de una transacción con rollback:

```
$ psql -d stock_development
BEGIN;
CREATE INDEX idx_demo_covering ON stock_items (warehouse_id, product_id)
       INCLUDE (quantity_available, reorder_point);
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT product_id, quantity_available, reorder_point
FROM stock_items WHERE warehouse_id = 1;

 Index Only Scan using idx_demo_covering on stock_items
   (cost=0.14..8.40 rows=15 width=16) (actual time=0.049..0.053 rows=15 loops=1)
   Index Cond: (warehouse_id = 1)
   Heap Fetches: 15
 Execution Time: 0.069 ms
ROLLBACK;
```

Dice `Index Only Scan` pero **`Heap Fetches: 15`**. Ese es el detalle que hay que
saber: el Index Only Scan sólo evita el heap si el *visibility map* dice que la
página está toda visible, y eso lo marca el `VACUUM`. En una tabla recién escrita
(o en una con muchas escrituras) vas a ver `Heap Fetches` alto y el beneficio se
evapora. Si ves eso en producción, la respuesta es tunear el autovacuum, no
agregar otro índice. Rails soporta esto con `add_index ..., include: [:col]`.

### 10.7 Índices redundantes: el caso real de este schema

Corriendo:

```bash
$ psql -d stock_development -c "
  SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
  FROM pg_stat_user_indexes WHERE relname = 'purchase_orders' ORDER BY indexrelname;"

     relname     |                  indexrelname                   | idx_scan |    size
-----------------+-------------------------------------------------+----------+------------
 purchase_orders | index_open_purchase_orders                      |        0 | 8192 bytes
 purchase_orders | index_purchase_orders_on_created_by_id          |        0 | 8192 bytes
 purchase_orders | index_purchase_orders_on_reference              |        0 | 8192 bytes
 purchase_orders | index_purchase_orders_on_supplier_id            |        0 | 8192 bytes
 purchase_orders | index_purchase_orders_on_supplier_id_and_status |        0 | 8192 bytes
 purchase_orders | index_purchase_orders_on_warehouse_id           |        2 | 8192 bytes
 purchase_orders | purchase_orders_pkey                            |        0 | 8192 bytes
```

Ahí está el caso de manual, en este mismo repo:
**`index_purchase_orders_on_supplier_id` es redundante** con
`index_purchase_orders_on_supplier_id_and_status`, porque `supplier_id` es su
prefijo izquierdo. Lo creó `t.references :supplier`
(`db/migrate/20260830161000_create_purchase_orders.rb:7`) y después la línea 32
agregó el compuesto sin poner `index: false`. Exactamente el error que
`create_stock_items.rb` documenta y evita. Para arreglarlo:
`remove_index :purchase_orders, :supplier_id` (con `algorithm: :concurrently` en
producción).

Contrasta con `index_products_on_category_id`, que **no** es redundante frente a
`index_products_active_by_category`: aunque `category_id` es prefijo izquierdo
del compuesto, el compuesto es **parcial** (`WHERE discarded_at IS NULL AND
active`) y por lo tanto no sirve para consultar productos descartados o
inactivos. Un índice parcial nunca reemplaza del todo a uno total.

El `idx_scan` de esa consulta es la métrica para cazar índices muertos en
producción: un índice con `idx_scan = 0` después de semanas de tráfico es puro
costo de escritura. (Acá todos están en 0 porque la base es de desarrollo y
`purchase_orders` está vacía; no leas nada de estos números.)

---

## 11. Por qué un índice NO se usa

Seis causas, y cada una tiene un síntoma distinto en el plan.

### 11.1 Función sobre la columna

```
$ psql -d stock_development -c "SET enable_seqscan = off;
    EXPLAIN (ANALYZE) SELECT id FROM products WHERE upper(sku::text) = 'TOR-M6-001';"

 Seq Scan on products  (cost=10000000000.00..10000000013.60 rows=1 width=8) (actual time=390.405..390.406 rows=0 loops=1)
   Filter: (upper((sku)::text) = 'TOR-M6-001'::text)
   Rows Removed by Filter: 15
 JIT:
   Functions: 4
   Timing: Generation 0.421 ms, Inlining 328.107 ms, Optimization 39.416 ms, Emission 22.817 ms, Total 390.761 ms
 Execution Time: 411.188 ms
```

Ese `cost=10000000000.00` es la penalidad que mete `enable_seqscan = off`:
prueba de que Postgres **no tenía otra opción**. Con `sku = 'TOR-M6-001'` directo,
el mismo Postgres usa el índice único (`Index Cond: (sku = 'TOR-M6-001'::citext)`).
Arreglo: no envolvés la columna, o creás un índice sobre la expresión.

(Bonus del plan: 390 ms de JIT para escanear 15 filas. El JIT de Postgres se
activa por costo estimado, y con un costo inflado artificialmente se dispara sin
sentido. En producción, si ves tiempos raros en queries baratas, `SET jit = off`
es una de las primeras cosas a probar.)

### 11.2 Tipo distinto

Comparar `varchar` con `integer`, o `bigint` con `numeric`, mete un cast
implícito que puede inutilizar el índice — y en Postgres muchas veces directamente
falla con `operator does not exist`. En Rails el caso típico es pasar un String
donde la columna es `bigint`: `where(product_id: "3")` funciona porque
ActiveRecord castea según el tipo de la columna, pero `where("product_id = ?", "3")`
manda el string crudo. Escribí las condiciones con hash siempre que puedas: el
casteo por tipo de columna es una de las cosas que ActiveRecord hace bien.

### 11.3 `ILIKE '%x%'` sin trigram

Un comodín inicial inutiliza un B-tree: el índice está ordenado por prefijo y vos
no tenés prefijo. Con `pg_trgm` + GIN sí se puede:

```
$ psql -d stock_development -c "EXPLAIN (ANALYZE, BUFFERS)
    SELECT id, sku FROM products WHERE name ILIKE '%tornillo%';"

 Bitmap Heap Scan on products (actual time=0.065..0.067 rows=2 loops=1)
   Recheck Cond: ((name)::text ~~* '%tornillo%'::text)
   Heap Blocks: exact=1
   ->  Bitmap Index Scan on index_products_on_name_trgm (actual time=0.040..0.041 rows=2 loops=1)
         Index Cond: ((name)::text ~~* '%tornillo%'::text)
 Execution Time: 0.122 ms
```

Ese es `index_products_on_name_trgm`
(`db/migrate/20260830160400_create_products.rb:56-58`) haciendo su trabajo.
El `Recheck Cond` es normal en un GIN: el índice de trigramas da candidatos
(puede haber falsos positivos) y Postgres re-verifica sobre la fila.

Y el complemento defensivo, en `Products::Search#apply_term`
(`app/queries/products/search.rb:59`):

```ruby
pattern = "%#{Product.sanitize_sql_like(@term.strip)}%"
```

`sanitize_sql_like` escapa `%` y `_` del input. Sin eso, un usuario escribe `%` y
te fuerza un escaneo completo — DoS barato.

### 11.4 Estadísticas viejas

El planner decide con las estadísticas de `ANALYZE`. Si cargaste 10M de filas y
no corriste `ANALYZE`, el planner cree que la tabla está vacía y elige Seq Scan.
Síntoma en el plan: **`rows` estimadas muy lejos de `rows` actuales**. Se ve
justo en el plan de `LowStock`:

```
 Hash Join  (cost=8.17..9.93 rows=1 width=96) (actual time=0.076..0.087 rows=13 loops=1)
```

Estimó 1 fila, salieron 13. Con 13 filas no importa; el mismo error de un
factor 13 sobre 10M de filas te cambia un Nested Loop por un Hash Join y te
arruina la query. Arreglo: `ANALYZE tabla;`, y para columnas correlacionadas,
`CREATE STATISTICS`.

### 11.5 La tabla es chica

**Este es el caso de la base de desarrollo y hay que saberlo antes de sacar
conclusiones.** Con 48 filas en `stock_items`, el planner elige Seq Scan aunque
el índice parcial exista:

```
$ psql -d stock_development -c "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM stock_items
    WHERE quantity_available <= reorder_point AND reorder_point != 0
    ORDER BY (quantity_available - reorder_point) ASC, id ASC;"

 Sort  (cost=2.05..2.09 rows=15 width=96) (actual time=0.104..0.106 rows=13 loops=1)
   ->  Seq Scan on stock_items  (cost=0.00..1.76 rows=15 width=96) (actual time=0.027..0.040 rows=13 loops=1)
         Filter: ((quantity_available <= reorder_point) AND (reorder_point <> 0))
         Rows Removed by Filter: 35
         Buffers: shared hit=1
 Execution Time: 0.197 ms
```

**No es un bug del índice: es el planner haciendo lo correcto.** La tabla entera
entra en 1 página (`Buffers: shared hit=1`). Ir al índice y volver a la tabla
serían más lecturas. Si vas a juzgar un plan, hacelo contra un dataset con volumen
parecido al de producción y con `ANALYZE` corrido.

### 11.6 `OR` mal escrito

El mito es "OR mata el índice". No es cierto: Postgres tiene `BitmapOr` y combina
varios índices. Con la query real de `Products::Search`:

```
$ psql -d stock_development -c "SET enable_seqscan = off; EXPLAIN (ANALYZE, BUFFERS)
    SELECT products.* FROM products WHERE discarded_at IS NULL
    AND (sku = 'TORNILLO' OR name ILIKE '%tornillo%' OR barcode = 'TORNILLO')
    ORDER BY name ASC, id ASC;"

 Sort (actual time=0.118..0.119 rows=2 loops=1)
   Sort Key: name, id
   ->  Bitmap Heap Scan on products (actual time=0.079..0.081 rows=2 loops=1)
         Recheck Cond: ((sku = 'TORNILLO'::citext) OR ((name)::text ~~* '%tornillo%'::text)
                        OR ((barcode)::text = 'TORNILLO'::text))
         Filter: (discarded_at IS NULL)
         ->  BitmapOr (actual time=0.059..0.060 rows=0 loops=1)
               ->  Bitmap Index Scan on index_products_on_sku
                     Index Cond: (sku = 'TORNILLO'::citext)
               ->  Bitmap Index Scan on index_products_on_name_trgm
                     Index Cond: ((name)::text ~~* '%tornillo%'::text)
               ->  Bitmap Index Scan on index_products_on_barcode
                     Index Cond: ((barcode)::text = 'TORNILLO'::text)
 Execution Time: 0.364 ms
```

Tres índices distintos combinados con `BitmapOr` en una sola pasada, incluyendo
el GIN de trigramas y el parcial de `barcode`. Ese es el plan que justifica cómo
está escrito `apply_term`.

El OR **sí** mata el índice cuando **una** de las ramas no es indexable: la rama
mala fuerza un Seq Scan y las demás dejan de importar. En ese caso, la
reescritura es un `UNION` de dos queries indexables.

---

## 12. `EXPLAIN` y `EXPLAIN ANALYZE`

### 12.1 Cómo correrlo sobre este repo

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"

# 1) Desde Rails, sobre cualquier relación o query object
bin/rails runner 'puts StockItems::LowStock.call.explain(:analyze, :buffers).inspect'
bin/rails runner 'puts StockMovements::Ledger.call(limit: 50).explain(:analyze).inspect'

# 2) Sólo el SQL, para pegarlo en psql
bin/rails runner 'puts Products::Search.call(term: "tornillo").to_sql'

# 3) Directo en psql
psql -d stock_development -c "EXPLAIN (ANALYZE, BUFFERS) SELECT ..."
```

⚠️ **Dos trampas con `explain` en Rails 7.1+:**

1. Las opciones son **símbolos posicionales**, no un hash. `explain(:analyze, :buffers)`
   funciona; `explain(analyze: true)` genera `EXPLAIN ({:ANALYZE=>TRUE}) SELECT …`
   y Postgres lo rechaza. Verificado:

   ```bash
   $ bin/rails runner 'StockItems::LowStock.call.explain(analyze: true)'
   => ActiveRecord::StatementInvalid: PG::SyntaxError: ERROR: syntax error at or near "{"
   ```

   Por eso el helper `ApplicationRecord.explain_analyze`
   (`app/models/application_record.rb:44-46`) **está roto hoy**, y el comentario
   de `app/queries/stock_items/low_stock.rb:13` sugiere la forma que no anda.
   Usá `.explain(:analyze, :buffers)` directo sobre la relación.

2. `.explain` devuelve un `ExplainProxy`; `puts` te imprime
   `#<ActiveRecord::Relation::ExplainProxy:0x...>`. Hay que hacer `.inspect`.

Y el detalle bueno: **Rails corre `EXPLAIN` para la query principal Y para las de
preload**. Con `LowStock.call.explain(:analyze, :buffers)` salen tres planes: el
de `stock_items`, el de `SELECT products WHERE id IN (...)` y el de
`SELECT warehouses WHERE id = 1`. `psql` te da uno solo.

⚠️ **`ANALYZE` ejecuta la query de verdad.** Sobre un `UPDATE` o un `DELETE`,
hacelo dentro de una transacción con rollback:

```sql
BEGIN;
EXPLAIN (ANALYZE) DELETE FROM outbox_events WHERE published_at < now() - interval '30 days';
ROLLBACK;
```

### 12.2 Cómo se lee un plan

El plan es un árbol; se lee **de adentro hacia afuera y de abajo hacia arriba**.
Cada nodo trae:

```
Nodo  (cost=INICIO..TOTAL rows=ESTIMADAS width=BYTES) (actual time=INICIO..TOTAL rows=REALES loops=N)
```

| Qué mirar | Qué significa | Alarma cuando… |
|---|---|---|
| `rows` estimadas vs `rows` actuales | qué tan bien entiende el planner tus datos | difieren en más de ~10x → estadísticas viejas o correlación no modelada |
| `loops` | cuántas veces se ejecutó ese subárbol | `loops` alto en el lado interno de un Nested Loop = N+1 dentro de la base |
| `actual time` | **es por loop**: multiplicá por `loops` para el total | — |
| `Rows Removed by Filter` | filas leídas y descartadas | alto → falta un índice o el índice no cubre el predicado |
| `Buffers: shared hit / read` | páginas de cache / de disco | `read` alto → no entra en `shared_buffers` |
| `Sort Method` | `quicksort` (memoria) vs `external merge Disk` | `Disk` → subí `work_mem` o evitá el sort con un índice |
| `Heap Fetches` (en Index Only Scan) | fue al heap igual | alto → el visibility map está desactualizado, falta VACUUM |
| `Batches` (en Hash) | 1 = entró en memoria | >1 → el hash se fue a disco |

### 12.3 Los nodos de acceso

| Nodo | Qué hace | Cuándo lo elige |
|---|---|---|
| **Seq Scan** | lee toda la tabla | tabla chica, o vas a leer un porcentaje grande |
| **Index Scan** | recorre el índice y va al heap por cada match | pocas filas, y necesitás columnas fuera del índice |
| **Index Only Scan** | responde sólo con el índice | todas las columnas están en el índice (ver `Heap Fetches`) |
| **Bitmap Index Scan + Bitmap Heap Scan** | arma un bitmap de páginas y después lee el heap **en orden físico** | cantidad intermedia de filas, o combinando varios índices con `BitmapOr` |

El Bitmap es el que más se malinterpreta: no es "peor que Index Scan", es la
estrategia para cuando hay demasiadas filas para ir al heap una por una (random
I/O) pero muy pocas para leer la tabla entera. Ordenar los accesos por página
convierte random I/O en secuencial.

### 12.4 Los nodos de join, con planes reales

**Hash Join** (el default para joins grandes): construye una hash table con el
lado chico y sondea con el grande. Este es real, sobre 300k movimientos:

```
 Hash Join  (cost=6720.33..13894.45 rows=2953 width=40) (actual time=5.941..7.010 rows=2959 loops=1)
   Hash Cond: (m.product_id = p.id)
   Buffers: shared hit=1271 read=129
   ->  Bitmap Heap Scan on stock_movements m (actual time=5.917..6.398 rows=2959 loops=1)
         Recheck Cond: (occurred_at > (now() - '00:30:00'::interval))
         Heap Blocks: exact=303
         ->  Bitmap Index Scan on index_stock_movements_on_warehouse_id_and_occurred_at
               (actual time=4.864..4.864 rows=8817 loops=1)
               Index Cond: (occurred_at > (now() - '00:30:00'::interval))
               Buffers: shared hit=1096
   ->  Hash  (actual time=0.012..0.014 rows=15 loops=1)
         Buckets: 1024  Batches: 1  Memory Usage: 9kB
         ->  Seq Scan on products p (actual time=0.004..0.008 rows=15 loops=1)
 Execution Time: 7.130 ms
```

Tres cosas para leer acá: (a) `Batches: 1` → la hash table entró en memoria;
(b) `products` va del lado del hash porque es la tabla chica, lo cual es
correcto; (c) el `Bitmap Index Scan` usó un índice compuesto filtrando por su
**segunda** columna — funcionó, pero escaneó el índice entero (1096 buffers para
encontrar 8817 filas). Eso es el prefijo izquierdo cobrándose el peaje.

**Nested Loop**: por cada fila del lado externo, busca en el interno. Forzado
para verlo:

```
$ psql -d stock_development -c "SET enable_hashjoin = off; SET enable_mergejoin = off;
    EXPLAIN (ANALYZE) SELECT si.id, p.sku FROM stock_items si
    JOIN products p ON p.id = si.product_id WHERE si.warehouse_id = 1;"

 Nested Loop  (cost=0.00..5.97 rows=15 width=17) (actual time=0.031..0.056 rows=15 loops=1)
   Join Filter: (p.id = si.product_id)
   Rows Removed by Join Filter: 105
   ->  Seq Scan on stock_items si (actual time=0.011..0.018 rows=15 loops=1)
         Filter: (warehouse_id = 1)
         Rows Removed by Filter: 33
   ->  Materialize (actual time=0.001..0.002 rows=8 loops=15)
         ->  Seq Scan on products p (actual time=0.009..0.012 rows=15 loops=1)
 Execution Time: 0.143 ms
```

**`loops=15`** en el lado interno: es el N+1 dentro de la base. Con 15 filas es
gratis; con 500.000 en el lado externo y un Index Scan interno de 0.1 ms, son 50
segundos. Cuando veas una query lenta con un Nested Loop y `loops` en los
millones, mirá primero las estimaciones: casi siempre el planner subestimó el
lado externo.

**Merge Join**: ordena ambos lados y los recorre en paralelo. Aparece cuando las
dos entradas ya vienen ordenadas por la clave de join (típicamente por índices).
Es raro verlo en OLTP.

Regla mental: Nested Loop es bueno con **pocas** filas del lado externo y un
índice del lado interno; Hash Join es bueno con **muchas** filas y sin índice
útil; Merge Join, con ambos lados ya ordenados.

---

## 13. Encontrar la query lenta real

Optimizar la query que "te parece" lenta es perder el tiempo. Hay que medir.

### 13.1 `pg_stat_statements` — el primero que hay que pedir

Agrega estadísticas acumuladas por *forma* de query (normaliza los literales).
Te dice qué query se lleva el tiempo total, que casi nunca es la más lenta:
una query de 5 ms ejecutada 200.000 veces por hora pesa más que una de 3 s
ejecutada tres veces.

```sql
CREATE EXTENSION pg_stat_statements;   -- requiere shared_preload_libraries = 'pg_stat_statements'

SELECT calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

**En este entorno no se puede activar**, y vale la pena saber por qué:

```bash
$ psql -d stock_development -c "show shared_preload_libraries;"
 shared_preload_libraries
--------------------------
                            # vacío

$ psql -d stock_development -c "select name, installed_version from pg_available_extensions
                                where name = 'pg_stat_statements';"
        name        | installed_version
--------------------+-------------------
 pg_stat_statements |                    # disponible, no instalada
```

`pg_stat_statements` necesita cargarse en `shared_preload_libraries`, y eso
**requiere reiniciar Postgres**. En RDS/Cloud SQL se hace por parameter group.
Es la primera cosa que hay que pedirle a infra en un proyecto nuevo.

### 13.2 `auto_explain` — el plan de la query lenta, en el log

`pg_stat_statements` te dice *cuál*; `auto_explain` te dice *por qué*, logueando
el plan de toda query que pase un umbral. Este sí se puede cargar por sesión, y
lo corrí:

```bash
$ psql -d stock_development <<'SQL'
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_analyze = true;
SET client_min_messages = LOG;
SELECT count(*) FROM stock_movements WHERE kind = 'receipt';
SQL

LOG:  duration: 24.586 ms  plan:
Query Text: SELECT count(*) FROM stock_movements WHERE kind = 'receipt';
Aggregate  (cost=9014.67..9014.68 rows=1 width=8) (actual time=24.564..24.566 rows=1 loops=1)
  ->  Seq Scan on stock_movements  (cost=0.00..9014.44 rows=91 width=0) (actual time=22.519..24.553 rows=51 loops=1)
        Filter: ((kind)::text = 'receipt'::text)
        Rows Removed by Filter: 51
```

En producción va en `postgresql.conf` con `shared_preload_libraries` y
`log_min_duration = '500ms'` o similar, más `log_analyze`, `log_buffers` y
`log_nested_statements`. La contra: `log_analyze` mete overhead de
instrumentación en **todas** las queries, no sólo en las lentas. Con
`auto_explain.sample_rate` se muestrea.

(Dato de color de ese plan: un Seq Scan de 24 ms sobre una tabla que tenía 102
filas. Explicación en §16.)

### 13.3 Índices muertos y tablas hinchadas

```sql
-- índices que nadie usa: puro costo de escritura
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes WHERE idx_scan = 0 ORDER BY pg_relation_size(indexrelid) DESC;

-- proporción de seq scans por tabla: candidata a que le falte un índice
SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup, n_dead_tup
FROM pg_stat_user_tables ORDER BY seq_tup_read DESC;

-- qué está corriendo AHORA (acá aparecen los query log tags de Rails)
SELECT pid, now() - query_start AS duration, state, query
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY duration DESC;
```

La última es la que más sirve en una guardia. Como este repo tiene
`query_log_tags_enabled`, en el `query` vas a ver el comentario
`/*application='Stock',controller='products',action='index'*/` y sabés de dónde
salió sin adivinar.

### 13.4 Del lado de Rails

- `rack-mini-profiler` (ya en el Gemfile, `require: false`): badge flotante con
  el desglose de tiempo SQL/render de cada request. Se activa con
  `bundle exec rails s` y `?pp=help`.
- `ActiveSupport::Notifications.subscribe("sql.active_record")`: contar queries
  programáticamente, que es lo que usé para las mediciones de §3.5.
- Un APM con tracing distribuido para producción. No hay ninguno configurado acá.

---

## 14. Desnormalizar y contadores

Desnormalizar es cambiar consistencia por velocidad de lectura. Está bien
**cuando es una decisión consciente con un mecanismo que la mantiene**. Este repo
tiene tres casos, cada uno con una técnica distinta.

### 14.1 Contador mantenido por callback: `purchase_orders.total_cents`

```ruby
# db/migrate/20260830161000_create_purchase_orders.rb:15-20
# CONTADOR DESNORMALIZADO (counter cache manual).
# Guardar el total en vez de recalcularlo con un SUM sobre las líneas
# evita un N+1 brutal en el listado de órdenes.
t.bigint  :total_cents, null: false, default: 0
t.integer :lines_count, null: false, default: 0
```

Se mantiene desde la línea con `after_save :refresh_order_totals` /
`after_destroy :refresh_order_totals` (`app/models/purchase_order_line.rb:23-24,
36-38`), que llama a:

```ruby
# app/models/purchase_order.rb:43-49
def recalculate_totals!
  update_columns(
    total_cents: lines.sum(:subtotal_cents),
    lines_count: lines.count,
    updated_at: Time.current
  )
end
```

Cuatro decisiones a defender acá:

- **`update_columns`**, no `update!`: salta validaciones, callbacks y optimistic
  locking. Es lo correcto para un contador derivado — si corriera las
  validaciones, tendrías recursión de callbacks y una posible `StaleObjectError`
  por un campo que el usuario no editó.
- **`lines.sum(:subtotal_cents)`** usa la **columna generada** de Postgres
  (`subtotal_cents` = `quantity_ordered::bigint * unit_cost_cents`, stored), así
  que el subtotal nunca puede estar desincronizado del precio y la cantidad.
- **`after_save`, no `after_commit`**: se ejecuta dentro de la transacción, así
  que si algo falla después, el total vuelve atrás con todo lo demás.
- **Contra**: bajo escrituras concurrentes sobre la misma orden, dos callbacks
  pueden pisarse. Para eso está `counter_culture` o un `UPDATE ... SET x = x + n`
  atómico. Con órdenes de compra (un usuario edita una orden por vez) el riesgo
  es aceptable.

Rails tiene `counter_cache` nativo para el caso simple (contar hijos). Acá no
alcanzaba porque además hay que sumar dinero.

### 14.2 Columnas copiadas: `stock_movements.product_id` / `warehouse_id`

```ruby
# db/migrate/20260830160700_create_stock_movements.rb:32-36
# DESNORMALIZACIÓN DELIBERADA. product_id y warehouse_id son derivables de
# stock_item, pero copiarlos evita un JOIN en TODOS los reportes históricos,
# que son la lectura más frecuente y más pesada.
```

Se mantienen con un `before_validation` (`app/models/stock_movement.rb:68-74`), y
como el ledger es inmutable (`readonly? = persisted?`), **nunca pueden
desincronizarse**: se escriben una vez y nadie los toca. Esa es la condición que
hace segura esta desnormalización, y es la que hay que mencionar.

El beneficio se ve en los índices: `(product_id, occurred_at DESC)` y
`(warehouse_id, occurred_at DESC)` sirven los reportes sin tocar `stock_items`.

### 14.3 La proyección: `stock_items.quantity_on_hand`

El caso grande del dominio, explicado en
`db/migrate/20260830160700_create_stock_movements.rb:9-19`:

> `stock_items.quantity_on_hand` es una PROYECCIÓN (un cache).
> `stock_movements` es la VERDAD (el hecho histórico).
> Invariante: `quantity_on_hand == SUM(stock_movements.quantity)` para ese item.
> ¿Por qué no calcular la cantidad con un SUM() cada vez? Porque con millones de
> movimientos el SUM se vuelve carísimo.

Es CQRS en su versión pragmática, y viene con su verificador:
`StockItems::Reconciliation` (`app/queries/stock_items/reconciliation.rb:25-35`)
compara proyección contra ledger en **una** query con `LEFT JOIN`, `GROUP BY` y
`HAVING`:

```ruby
StockItem.left_joins(:stock_movements)
  .group("stock_items.id", "stock_items.quantity_on_hand")
  .having("stock_items.quantity_on_hand <> COALESCE(SUM(stock_movements.quantity), 0)")
  .pluck(...)
```

Dos detalles técnicos que conviene poder explicar: (1) `left_joins` y no `joins`,
porque un item **sin** movimientos y con cantidad distinta de cero es justo el
caso que más querés detectar, y con INNER JOIN desaparecería; (2) ActiveRecord no
tiene `right_joins`, así que la forma idiomática es dar vuelta la relación y
arrancar del lado que querés conservar.

**Regla general para desnormalizar**: hacelo cuando (a) la lectura es mucho más
frecuente que la escritura, (b) tenés un mecanismo que mantiene el valor dentro
de la misma transacción, y (c) tenés un verificador que corre periódicamente. Sin
(c) es cuestión de tiempo hasta que los números no cierren y nadie sepa por qué.

---

## 15. Cacheo

### 15.1 `Rails.cache.fetch`

El store en desarrollo y producción es Solid Cache
(`config/environments/production.rb:50`), o sea **una tabla de Postgres**, no
Redis. Eso cambia el cálculo: un `fetch` cuesta una query, así que cachear algo
que ya era una query rápida no gana nada. Cachear una agregación de 200 ms sí.

Los dos usos reales:

```ruby
# app/controllers/dashboard_controller.rb:9
# El dashboard hace 6 agregaciones. Cachearlas 60 s no cambia nada para el
# usuario y le saca un montón de carga a la base cuando 20 operarios lo
# tienen abierto en una pantalla.
@stats = Rails.cache.fetch("dashboard/stats", expires_in: 60.seconds) { compute_stats }
```

```ruby
# app/controllers/api/v1/reports_controller.rb:32
payload = Rails.cache.fetch(valuation_cache_key, expires_in: 5.minutes) do
  result = StockItems::Valuation.call(warehouse_id: warehouse_id_filter, category_id: params[:category_id])
  { total_units: ..., totals: ..., by_warehouse: ..., generated_at: Time.current.iso8601 }
end
```

### 15.2 El error número 1: la clave incompleta

El propio código lo señala (`app/controllers/api/v1/reports_controller.rb:29-31`):

> La clave incluye TODOS los parámetros que afectan el resultado — si te olvidás
> uno, servís el reporte de otro depósito. Ese es el bug #1 del caching y es
> silencioso.

```ruby
# app/controllers/api/v1/reports_controller.rb:62-64
def valuation_cache_key
  [ "reports/valuation", params[:warehouse_code].to_s.upcase, params[:category_id] ].join("/")
end
```

Es silencioso porque no tira error: devuelve **datos de otro**. Y si el filtro
que faltaba es de autorización, es una fuga de datos entre tenants. La regla:
**la clave tiene que ser función de TODO lo que el bloque lee** — parámetros,
usuario/tenant, permisos, locale, versión del formato de salida.

Segunda regla: cacheá el **payload serializado**, no el objeto. En
`ReportsController#valuation` el bloque devuelve un Hash de primitivas ya
convertido con `as_json`; no guarda `ValueObjects::Money`. Eso te salva de que un
cambio de forma de la clase reviente al deserializar entradas viejas.

Contraejemplo del propio repo, el patrón que **no** conviene copiar
(`app/models/warehouse.rb:29-33`): `Warehouse.transit` cachea el resultado de un
`find_by!`, o sea un **objeto ActiveRecord**. Se serializa entero (caro), vuelve
con atributos potencialmente viejos, y si mañana agregás una columna las entradas
cacheadas de la versión anterior vuelven sin ella. Para un depósito virtual que
casi nunca cambia y sólo se usa por `id` funciona, pero el criterio general es:
**cacheá datos, no objetos con comportamiento**.

### 15.3 Fragment caching y russian doll

Este repo **no usa fragment caching**: lo verifiqué, no hay ningún `<% cache %>`
en `app/views/`. Lo que sigue es cómo se aplicaría.

```erb
<% cache warehouse do %>
  <% warehouse.stock_items.each do |item| %>
    <% cache item do %>...<% end %>
  <% end %>
<% end %>
```

La clave se arma sola con `cache_key_with_version`
(`products/15-20260830172954218272`: modelo, id y `updated_at`). Cuando el
registro se actualiza, la clave cambia y la entrada vieja queda huérfana hasta
que el store la expira. Eso es **key-based expiration**: nunca invalidás,
generás una clave nueva.

*Russian doll* es ese anidamiento: si cambia un item se regeneran el fragmento
del item **y** el del depósito, pero los demás items se sirven del cache. Para
que el externo se entere hay que propagar el `touch`
(`belongs_to :warehouse, touch: true`), y ahí está el trade-off que hay que
decir: `touch: true` convierte cada escritura en dos `UPDATE`, y si muchos hijos
comparten padre todas compiten por la misma fila — contención de locks.

Segunda trampa: si cambia el template pero no el registro, la clave no cambia.
Rails lo resuelve metiendo un digest del template en la clave
(`cache_versioning`), pero **sólo del template, no de los helpers ni del
serializer**. Si tocás un helper, invalidás a mano versionando la clave.

---

## 16. Operaciones bulk

| Método | Callbacks | Validaciones | `updated_at` | Optimistic locking | Instancia modelos |
|---|---|---|---|---|---|
| `create!` / `save!` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `insert_all` / `insert_all!` | ❌ | ❌ | ✅ (Rails 7+) | ❌ | ❌ |
| `upsert_all` | ❌ | ❌ | ✅ | ❌ | ❌ |
| `update_all` | ❌ | ❌ | ❌ | ⚠️ ver abajo | ❌ |
| `delete_all` | ❌ | ❌ | — | ❌ | ❌ |
| `destroy_all` | ✅ | — | — | ✅ | ✅ |

### 16.1 `insert_all!` — el caso real

```ruby
# app/forms/stock_transfer_form.rb:75-88
# `insert_all!` hace UN solo INSERT multi-fila en vez de N. Para 500 líneas
# es la diferencia entre 500 round-trips y 1. Contra: NO corre validaciones
# ni callbacks de ActiveRecord — por eso validamos antes, a mano, arriba.
# Es un trade-off consciente, no un atajo.
StockTransferLine.insert_all!(
  normalized_lines.map { |line|
    { stock_transfer_id: transfer.id, product_id: ..., quantity_requested: ...,
      quantity_dispatched: 0, quantity_received: 0, created_at: now, updated_at: now }
  }
)
```

La estructura correcta: **validar explícitamente antes** (el form lo hace en
`validate_lines`, chequeando SKU inexistente, cantidad no positiva y SKU
repetido) y después insertar en bloque. Saltarse las validaciones sin
reemplazarlas por otra cosa es cómo se meten datos basura.

Dato contra el folklore: **`insert_all` SÍ completa los timestamps** en Rails 7+.
Verificado acá (la tabla `categories` no tiene defaults en la base):

```bash
$ bin/rails runner 'ActiveRecord::Base.transaction do
    r = Category.insert_all([{ name: "ZZ", slug: "zz-...", depth: 0, path: "zz" }],
                            returning: %w[id created_at updated_at])
    puts r.rows.inspect
    raise ActiveRecord::Rollback
  end'
=> [[11, 2026-08-30 17:29:54.218272 +0000, 2026-08-30 17:29:54.218272 +0000]]
```

Lo que sigue siendo cierto es que **no corre callbacks ni validaciones ni asigna
defaults definidos en Ruby** (los de la base sí se aplican). `insert_all` ignora
duplicados según `unique_by`; `insert_all!` levanta la excepción. Y `upsert_all`
hace `INSERT ... ON CONFLICT (...) DO UPDATE`, que es la forma correcta de
sincronizar un catálogo desde un archivo del proveedor.

### 16.2 `update_all` y la sorpresa del `lock_version`

```bash
$ bin/rails runner 'Product.kept.where(id: -1).update_all(name: "x")'
Product Update All (0.5ms)  UPDATE "products" SET "name" = 'x',
  "lock_version" = COALESCE("products"."lock_version", 0) + 1
  WHERE "products"."discarded_at" IS NULL AND "products"."id" = -1
```

Dos cosas: **no toca `updated_at`** (por eso `Stock::Adjust`
lo pone a mano, `app/services/stock/adjust.rb:61-62`:
`update_all(last_counted_at: Time.current, updated_at: Time.current)`), pero
**sí incrementa `lock_version`** porque el modelo tiene optimistic locking. Es
decir: un `update_all` masivo invalida las versiones que tengan en la mano todos
los clientes, y el próximo `PATCH` de cualquiera de ellos va a dar 409. Correcto,
pero hay que saberlo.

El caso más interesante de `update_all` en este repo es el UPDATE condicional
atómico (`app/models/stock_item.rb:104-114`):

```ruby
def self.atomically_decrement(stock_item_id, amount)
  updated = where(id: stock_item_id)
            .where("quantity_on_hand - quantity_reserved >= ?", amount)
            .update_all([...])
  updated == 1
end
```

Un solo UPDATE con la condición de negocio adentro del `WHERE`. Postgres bloquea
la fila durante el UPDATE y evalúa el WHERE sobre la versión más reciente; si
devuelve 0 filas, la condición no se cumplía. Cero round-trips extra, cero riesgo
de deadlock por orden de locks. Es la variante de máximo throughput, y el
comentario del método tiene la respuesta de entrevista completa sobre cuándo usar
cada estrategia de concurrencia (ver también docs/06).

### 16.3 `delete_all` vs `destroy_all`

`delete_all` es un `DELETE FROM ... WHERE`: una query, sin callbacks. Perfecto
para datos efímeros (`app/jobs/cleanup/expired_records_job.rb`). `destroy_all`
carga cada registro y corre los callbacks — necesario si hay `dependent:
:destroy` o efectos de dominio, y carísimo en volumen. Si la tabla tiene FKs con
`on_delete: :restrict` (como acá casi todas), `delete_all` te va a dar
`PG::ForeignKeyViolation` en vez de un mensaje lindo, y eso es lo correcto: la
base te está protegiendo la historia contable.

---

## 17. Bonus medido: MVCC, bloat y el Seq Scan de 24 ms sobre 102 filas

Para medir los planes de §9 inserté 300k filas en `stock_movements` dentro de
transacciones que después hice `ROLLBACK`. La base quedó con los datos
originales... y con `165 MB` de tamaño total para **102 filas** (`n_live_tup`
195, `n_dead_tup` 0). El rollback no borra nada físicamente: en MVCC las tuplas
abortadas quedan hasta que el VACUUM las limpia, y el espacio no vuelve al SO.
Por eso el `auto_explain` de §13.2 mostró un Seq Scan de 24 ms sobre 102 filas:
estaba leyendo páginas mayormente vacías. Un `VACUUM (FULL, ANALYZE)
stock_movements` lo dejó en **136 kB**.

Tres cosas para llevarse: (1) `VACUUM` normal marca el espacio como reutilizable
pero **no** achica el archivo; `VACUUM FULL` sí, pero toma `ACCESS EXCLUSIVE
LOCK` — en producción se usa `pg_repack`. (2) Si una tabla se pone lenta y
`n_dead_tup` es alto contra `n_live_tup`, el problema no es tu query: es el
bloat, típicamente por transacciones largas abiertas que frenan el VACUUM.
(3) Las **secuencias no son transaccionales**: los ids de los inserts revertidos
se consumieron igual y el próximo movimiento real quedó con id 963103 — es
correcto (si no, cada rollback bloquearía a los demás escritores) y explica los
huecos que la gente reporta como bug.

---

## Errores que ves en producción

| Síntoma | Causa | Arreglo |
|---|---|---|
| El listado tarda 4 s y el log tiene 200 queries casi iguales | N+1: la vista o el serializer toca una asociación | `includes(:asociacion)` en el query object; test con Bullet y `:n_plus_one` |
| Metiste `includes` y sigue lento, con 200 `SELECT SUM(...)` | N+1 de **agregación**: `includes` no lo arregla | Una query con `GROUP BY` + `pluck`, como `StockItems::Availability` |
| El worker muere con OOM procesando "todos los registros" | `.all.each` carga todo en memoria | `find_each` / `in_batches`; y `pluck` si sólo necesitás dos columnas |
| El endpoint funciona hasta la página ~500 y ahí se cae | `OFFSET` grande: genera y descarta N filas, y se va a disco (`external merge`) | Keyset con comparación de **tuplas** + índice compuesto en el mismo orden |
| El usuario ve un registro dos veces al paginar | `ORDER BY` sin desempate único, o inserciones mientras pagina | Desempatar por `id` (`Products::Search::SORTS`); cursor en vez de offset |
| Creaste el índice y el plan sigue en Seq Scan | Tabla chica / estadísticas viejas / función sobre la columna / predicado del índice parcial no implicado | `ANALYZE`; escribir el WHERE igual que el predicado; no envolver la columna |
| `ActiveRecord::StatementInvalid: missing FROM-clause entry` | `includes` + condición **string** sobre la asociada | Agregar `.references(:asociacion)`, o usar la forma con hash |
| `ActiveModel::MissingAttributeError: missing attribute 'x'` | `select` parcial y después alguien tocó otra columna | Seleccionar todo, o `pluck` si sólo querés valores |
| `ActiveRecord::UnknownAttributeReference` en `pluck` u `order` | Rails protege contra inyección en SQL crudo | `Arel.sql("...")` — **nunca** con input del usuario |
| El reporte devuelve datos de otro depósito | Clave de cache incompleta | Meter TODOS los parámetros que afectan el resultado en la clave |
| `PG::NumericValueOutOfRange: bigint out of range` en un reporte | `int * int` desbordó en un SUM | Castear a `::numeric` como hace `StockItems::Valuation` |
| El job "de los 50 más urgentes" trae otros 50 | `find_each` **descarta** tu `ORDER BY` | Usar `cursor:`/`order:`, o `.limit(50).to_a` sin `find_each` |
| La tabla se puso lenta después de un borrado masivo | Bloat: tuplas muertas que el autovacuum no alcanza a limpiar | Borrar en lotes chicos y seguido (`in_batches` + `delete_all`); a escala, particionar y `DROP PARTITION`; `pg_repack` para recuperar espacio |
| El listado escribe bien pero cada `PATCH` devuelve 409 | Un `update_all` masivo incrementó `lock_version` de todas las filas | Esperado con optimistic locking; el cliente tiene que releer antes de escribir |
| `Index Only Scan` con `Heap Fetches` altísimo | Visibility map desactualizado | Tunear autovacuum, no agregar índices |
| El plan cambia de un día para otro sin que toques nada | El planner cambió de estrategia por estadísticas nuevas | Es normal; si duele, `CREATE STATISTICS` o revisar `default_statistics_target` |

---

## Cómo responder esto en una entrevista

**«¿Qué es un N+1 y cómo lo arreglás?»**

Una query para traer N registros más una por cada uno para traer algo asociado.
En Rails aparece porque tocar una asociación no cargada **dispara la query en ese
instante** — no hay `LazyInitializationException` que te avise como en Hibernate;
nunca falla, sólo se pone lento. Se arregla con `includes`, y se **previene** con
Bullet configurado con `raise = true` para que el N+1 rompa el CI
(`spec/support/bullet.rb`).
*El remate que separa una buena respuesta*: `includes` arregla el N+1 de **carga
de asociaciones**, no el de **agregación**. Si el serializer llama
`product.stock_items.sum(...)`, `includes` no cambia nada: sigue habiendo una
query por producto. Eso se arregla con un `GROUP BY` que resuelve toda la página
de una — en este repo, `StockItems::Availability`. Medido: 23 queries la versión
ingenua contra 4 constantes la real, para cualquier tamaño de página.

**«Diferencia entre `includes`, `preload`, `eager_load` y `joins`.»**

`preload` = siempre dos queries, `WHERE id IN (...)`, no permite filtrar por la
asociada. `eager_load` = una query con `LEFT OUTER JOIN` y aliases, sí permite
filtrar. `joins` = `INNER JOIN` para filtrar, **no carga nada**. `includes` deja
que Rails elija, y se pasa a LEFT JOIN cuando hay `references` o una condición
con hash sobre la asociada.
*Trade-off*: con `has_many`, `eager_load` puede ser **peor** que `preload` porque
el LEFT JOIN multiplica filas. Medido acá: 15 productos vuelven como 48 filas del
JOIN, cada una con las 17 columnas de `products` repetidas. Y `eager_load` +
`limit` sobre `has_many` obliga a Rails a hacer dos queries igual, con un
`SELECT DISTINCT` de por medio.
*Cuarta opción que casi nadie menciona*: para filtrar por un `has_many` sin
duplicar, un subquery `where(id: Otra.where(...).select(:fk))` — semi-join, sin
`distinct`, plan más simple. Es lo que hace `Products::Search#by_supplier`.

**«¿Cómo paginás una tabla de 50 millones de filas?»**

Keyset (cursor), no `OFFSET`. Con `OFFSET 100000` Postgres genera y descarta cien
mil filas para devolverte 50; lo medí y el plan muestra `rows=100050` con
`Sort Method: external merge Disk: 10256kB`, 153 ms contra 0.25 ms del keyset. Y
además el offset es **incorrecto** bajo escritura concurrente: una inserción
corre todas las filas y ves duplicados o te salteás registros.
La implementación es `WHERE (occurred_at, id) < (:t, :i) ORDER BY occurred_at
DESC, id DESC LIMIT n`, con un índice compuesto en el mismo orden.
*El detalle que separa la respuesta*: tiene que ser la **comparación de tuplas**,
no el OR expandido equivalente. Lo medí: con tuplas todo entra en `Index Cond` y
son 0.097 ms; con el OR, la condición cae a `Filter`, Postgres descarta 4000
filas en memoria y son 3.156 ms. **32x**. Ojo que el `find_each(cursor:)` de
Rails 8.1 genera el OR expandido.
*Contra del keyset*: no podés saltar a la página 37. Para un ledger es
irrelevante; para una grilla administrativa con navegación por número de página,
no.

**«¿Cuándo un índice no se usa?»**

Seis causas: (1) función sobre la columna (`upper(sku) = ...` no usa el índice de
`sku`); (2) tipo distinto que fuerza un cast; (3) `ILIKE '%x%'` sin `pg_trgm` +
GIN; (4) estadísticas viejas — se detecta comparando `rows` estimadas contra
reales en el `EXPLAIN ANALYZE`; (5) la tabla es chica y el Seq Scan es
genuinamente más barato; (6) un `OR` con una rama no indexable.
*El matiz sobre el OR*: "OR mata el índice" es un mito. Postgres tiene `BitmapOr`
y combina varios índices; lo verifiqué con la búsqueda real de este repo, que
combina el unique de `sku`, el GIN de trigramas de `name` y el parcial de
`barcode` en un solo `BitmapOr`. El OR duele cuando **una** rama no es indexable,
porque esa fuerza el Seq Scan y anula a las demás; ahí la reescritura es un
`UNION`.
*Y el que más se olvida*: para que un índice **parcial** se use, el WHERE de la
query tiene que implicar el predicado del índice, y el probador del planner es
limitado — hay que escribir la condición literalmente igual que en la migración.

**«¿Cómo leés un `EXPLAIN ANALYZE`? ¿Qué mirás primero?»**

De adentro hacia afuera. Miro cuatro cosas, en este orden: **estimadas vs reales**
(si difieren 10x o más, el planner está ciego y todo lo demás es consecuencia);
**`loops`** (el `actual time` es *por loop*, y un `loops` alto del lado interno de
un Nested Loop es un N+1 dentro de la base); **`Rows Removed by Filter`** (filas
leídas para tirar: falta un índice o el índice no cubre el predicado); y
**`Buffers`** (`read` alto = no entra en `shared_buffers`).
Después los nodos: Seq Scan / Index Scan / Bitmap Heap Scan / Index Only Scan del
lado del acceso, y Nested Loop / Hash Join / Merge Join del lado del join. Nested
Loop es bueno con pocas filas externas y un índice interno; Hash Join con muchas
filas y sin índice útil.
*Los dos avisos prácticos*: `ANALYZE` **ejecuta** la query, así que sobre un
`UPDATE`/`DELETE` va dentro de una transacción con rollback; y un `EXPLAIN` en la
base de desarrollo **miente por tamaño** — con 48 filas el planner elige Seq Scan
aunque el índice exista, y hace bien.

**«¿Cómo encontrás la query lenta en producción?»**

`pg_stat_statements` primero: te da tiempo **total** por forma de query, que es lo
que importa. La query de 5 ms ejecutada 200.000 veces por hora pesa más que la de
3 s ejecutada tres veces. Después `auto_explain` con un umbral, para tener el
plan de las lentas en el log sin reproducirlas a mano. Del lado de Rails,
`query_log_tags` (activo en este repo) mete el controller y la action como
comentario SQL, así que en `pg_stat_activity` ves de dónde salió cada query sin
adivinar.
*Trade-off*: `pg_stat_statements` necesita `shared_preload_libraries` y por lo
tanto un reinicio de Postgres — es lo primero que hay que pedirle a infra.
`auto_explain` con `log_analyze` instrumenta **todas** las queries, no sólo las
lentas; se acota con `sample_rate`.

**«¿Cuándo desnormalizás?»**

Cuando la lectura es mucho más frecuente que la escritura, tenés un mecanismo que
mantiene el valor **dentro de la misma transacción**, y tenés un verificador que
corre periódicamente. Sin el verificador es cuestión de tiempo hasta que los
números no cierren.
Los tres casos de este repo, de menos a más riesgo: las columnas generadas de
Postgres (`quantity_available`, `subtotal_cents`) no pueden desincronizarse porque
las calcula la base; las FKs copiadas en `stock_movements` tampoco, porque el
ledger es inmutable; y `purchase_orders.total_cents` sí puede, porque lo mantiene
un callback — por eso usa `update_columns` (sin validaciones ni optimistic
locking, que en un derivado sólo darían falsos conflictos) y por eso la
reconciliación proyección-vs-ledger corre en un job nocturno.

**«`insert_all` vs `create!`: ¿qué te estás salteando?»**

Callbacks, validaciones y optimistic locking. A cambio, un `INSERT` multi-fila en
vez de N round-trips — para 500 líneas es la diferencia entre 500 viajes y 1. La
forma correcta es la de `StockTransferForm`: validar explícitamente antes, a
mano, y después insertar en bloque. Saltarse las validaciones sin reemplazarlas
por otra cosa es cómo se meten datos basura.
*Corrección de folklore*: desde Rails 7, `insert_all` **sí** completa
`created_at`/`updated_at`. Lo verifiqué con `returning:` sobre una tabla sin
defaults en la base. Lo que sigue sin correr son los callbacks, las validaciones y
los defaults definidos en Ruby.
*Y el detalle inverso*: `update_all` **no** toca `updated_at` (hay que ponerlo a
mano, como hace `Stock::Adjust`) pero **sí** incrementa `lock_version` si el
modelo tiene optimistic locking — o sea que un update masivo hace que el próximo
`PATCH` de cualquier cliente devuelva 409.

---

## Para seguir

- **docs/03** — pool de conexiones, migraciones seguras (`strong_migrations`),
  tipos de Postgres, constraints y callbacks.
- **docs/05** — por qué las consultas viven en `app/queries/` y no en el modelo.
- **docs/06** — concurrencia: `FOR UPDATE`, optimistic locking, y por qué
  `atomically_decrement` existe.
- **docs/07** — outbox, jobs y el índice parcial de la cola de eventos.

Y el ejercicio que más rinde: agarrá `StockMovements::Ledger`, corré
`.explain(:analyze, :buffers).inspect` con y sin `product_id`, y explicá por qué
cambia el plan. Si podés contar esa diferencia sin mirar los apuntes, este
documento cumplió.
