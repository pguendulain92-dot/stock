# Base de datos, migraciones y ActiveRecord a fondo

Acá tenés la capa de persistencia completa: por qué Active Record no se comporta
como JPA aunque se le parezca, cómo se dimensiona el pool de conexiones y qué
pasa cuando le metés PgBouncer al medio, cómo funciona el multi-database de
Rails 8, cómo se escribe una migración que no tire la producción abajo
(`strong_migrations` a fondo), qué puede y qué no puede representar `db/schema.rb`,
los tipos de Postgres que usa este repo, las constraints que sostienen las
invariantes, la carrera de `validates_uniqueness_of` y el orden real de los
callbacks.

Todo el código citado sale del repositorio y **todas las salidas de consola de
este documento se produjeron corriendo la app** contra `stock_development`
(Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16.13). Los comentarios del código son la
fuente de verdad; esto los amplía.

Los fundamentos de Ruby y la comparación general con Spring están en
`docs/00-ruby-y-rails-para-javeros.md`; el mapa de capas, en
`docs/01-arquitectura.md`.

---

## 1. Active Record no es JPA: qué cambia en la práctica

Active Record (el patrón de Fowler) pone la persistencia **dentro** del objeto de
dominio. JPA/Hibernate implementa Data Mapper con Unit of Work: un
`EntityManager` separado que gestiona un *persistence context*. La API se parece,
la semántica no.

| JPA / Hibernate | Active Record | Consecuencia práctica |
|---|---|---|
| `EntityManager`, persistence context | No existe | No hay "sesión": no hay nada que hacer `flush()` |
| Identity map (1 instancia por PK) | No existe | Dos `find` del mismo id son **dos objetos distintos** |
| Dirty checking diferido al flush | Dirty tracking inmediato, sin escritura automática | Si no llamás `save!`, **no se guarda nada** |
| Entidades *detached* / `merge()` | No existe el concepto | Un objeto viejo es sólo un objeto con datos viejos |
| Lazy loading con proxies + `LazyInitializationException` | Asociación no cargada ⇒ **dispara la query ahí mismo** | El N+1 es silencioso y facilísimo de crear |
| `flush()` antes de una query (write-behind) | Nunca | El SQL sale en el orden en que lo escribiste |
| `@Version` | Columna `lock_version` por convención | `app/models/stock_item.rb:22` |
| Cascade / orphan removal | `dependent:` (§11.5) | Semántica parecida, valores distintos |
| Cache de 2º nivel | No hay | Se usa `Rails.cache` a mano |

**No hay `LazyInitializationException` porque no hay sesión que cerrar.** Ese es
el cambio mental grande: en Hibernate una asociación no inicializada fuera de la
sesión explota; en Rails simplemente hace la query. Nunca falla, sólo se pone
lento — que es peor, porque no lo ves hasta que mirás el log.

Medido en este repo:

```bash
$ bin/rails runner '
count = 0
ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| count += 1 unless p[:name].to_s =~ /SCHEMA|TRANSACTION/ }
StockItem.limit(5).each { |si| si.product.sku }
puts "sin includes: #{count} queries"
count = 0
StockItem.includes(:product).limit(5).each { |si| si.product.sku }
puts "con includes: #{count} queries"'

sin includes: 6 queries
con includes: 2 queries
```

Seis queries (1 + N) contra dos (una por tabla: Rails hace `IN (...)`, no un
JOIN, salvo que uses `preload`/`eager_load` explícitamente). No hay ningún
`fetch = EAGER` que te salve por defecto: hay que pedir `includes` en cada
listado. Por eso los modelos de este repo exponen un scope `with_associations`
(`app/models/product.rb:60`, `app/models/stock_item.rb:47`).

La consecuencia más cara de no tener identity map: **dos instancias del mismo
registro se pisan**. Por eso el dominio bloquea la fila antes de leer y escribir,
en vez de confiar en que el ORM "ya sabe":

```ruby
# app/services/stock/apply_movement.rb:103
StockItem.lock.find(@stock_item_id)   # => SELECT ... FOR UPDATE
```

---

## 2. La conexión: pool, timeouts y la cuenta que nadie hace

`config/database.yml` pasa por ERB antes de ser YAML. Es el equivalente a
`application.properties` + la config de HikariCP, con multi-base de fábrica.

### 2.1 El pool es por proceso, y además por base

En Spring tenés **un** `DataSource` por aplicación. En Rails hay **un pool por
proceso y por entrada de `database.yml` que se use**, y se crean *lazy*, en el
primer uso. Verificado:

```bash
$ bin/rails runner '
pools = ActiveRecord::Base.connection_handler.connection_pools
puts "pools activos: #{pools.map { |p| [p.db_config.name, p.size] }.inspect}"
Rails.cache.write("x", 1)
SolidQueue::Job.first
pools = ActiveRecord::Base.connection_handler.connection_pools
puts "despues de tocar cache/queue: #{pools.map { |p| [p.db_config.name, p.size] }.inspect}"
puts "suma: #{pools.sum(&:size)}"'

pools activos: [["primary", 5]]
despues de tocar cache/queue: [["primary", 5], ["cache", 5], ["queue", 5]]
suma: 15
```

Un proceso que arranca con un solo pool de 5 termina, después de escribir en el
cache y leer la cola, con **15 conexiones potenciales**. Nadie configuró nada
extra: pasó solo.

### 2.2 La cuenta real de conexiones

```
conexiones = procesos_web × pools_usados × max_connections
           + procesos_worker × pools_usados × max_connections
           + consolas, jobs de cron, tareas rake, health checks…
```

Con lo que hay configurado hoy (`config/database.yml:39`, `config/puma.rb:28`):

| Ítem | Valor |
|---|---|
| `max_connections` del pool | `RAILS_MAX_THREADS` (default **5**) |
| Threads de Puma | `RAILS_MAX_THREADS` (default **3** en `config/puma.rb`) |
| Bases posibles por proceso | 4 (`primary`, `cache`, `queue`, `cable`) |
| Peor caso por proceso web | 4 × 5 = **20** |
| 3 workers de Puma × 2 máquinas | 6 × 20 = **120** |

Y el `max_connections` default de Postgres es **100**. Ahí tenés el
`PG::ConnectionBad: FATAL: sorry, too many clients already` clásico, sin haber
escalado nada raro.

Dos reglas:

1. **`max_connections` del pool ≥ threads del proceso.** Si es menor, los threads
   se pelean por conexiones y aparece `ActiveRecord::ConnectionTimeoutError`.
   Más grande que la cantidad de threads no sirve para nada: son conexiones que
   nunca se usan y que igual cuentan contra el límite del servidor.
2. **Contá las cuatro bases, no una.** Es el error de escalado #2 y está avisado
   en `config/database.yml:23-26`.

Ojo con la nomenclatura: en Rails 8.1 la clave es `max_connections`. `pool`
sigue funcionando como alias pero está **deprecado**, y si ponés las dos con
valores distintos Rails levanta un error de configuración ambigua
(`activerecord-8.1.3.1/lib/active_record/database_configurations/hash_config.rb:85,220`).
Verificado:

```bash
$ bin/rails runner 'p ActiveRecord::Base.connection_pool.db_config.configuration_hash
   .slice(:max_connections, :checkout_timeout, :idle_timeout, :variables)'

{:max_connections=>5, :checkout_timeout=>5, :idle_timeout=>300,
 :variables=>{"statement_timeout"=>15000, "lock_timeout"=>10000,
              "idle_in_transaction_session_timeout"=>30000}}
```

### 2.3 `checkout_timeout` e `idle_timeout`

* **`checkout_timeout: 5`** — segundos que un thread espera una conexión libre
  antes de tirar `ActiveRecord::ConnectionTimeoutError`. Es el
  `connectionTimeout` de Hikari. **Bajarlo es bueno**: preferís fallar rápido y
  liberar el thread de Puma antes que acumular requests colgados hasta que se
  llene la cola de aceptación. Un timeout de checkout largo convierte un
  problema de base en una caída del front.
* **`idle_timeout: 300`** — cierra conexiones ociosas. Sirve contra los firewalls
  y NATs que cortan conexiones TCP viejas sin avisar: sin esto, la app se queda
  con una conexión muerta en el pool y el siguiente que la agarra come un
  `PG::ConnectionBad` de la nada.

### 2.4 Los tres timeouts del servidor

Van en `variables:` (`config/database.yml:52-55`) y se aplican con `SET` al
conectar. Verificado contra la sesión real:

```bash
$ bin/rails runner 'c = ActiveRecord::Base.connection
puts c.select_value("show statement_timeout")
puts c.select_value("show lock_timeout")
puts c.select_value("show idle_in_transaction_session_timeout")
puts c.select_value("show transaction_isolation")'

15s
10s
30s
read committed
```

| Variable | Qué mata | Por qué importa |
|---|---|---|
| `statement_timeout` | Una query que pasa de 15 s | Sin esto, una query mala tiene un thread de Puma colgado para siempre y se te agota el pool |
| `lock_timeout` | La **espera** por un lock, a los 10 s | Sin esto, un `SELECT FOR UPDATE` detrás de una transacción zombie espera infinito. Y en migraciones, es lo que evita el desastre de §5.1 |
| `idle_in_transaction_session_timeout` | Una transacción abierta que no hace nada, a los 30 s | Una transacción zombie **bloquea el VACUUM** de las tablas que tocó y hace crecer el bloat. Es el asesino silencioso de Postgres |

Nota importante para el javero: **el nivel de aislamiento por defecto es READ
COMMITTED**, igual que en la mayoría de los Spring Boot con Postgres, y **no** te
protege del lost update. `ApplyMovement` no confía en el aislamiento: bloquea
(`app/services/stock/apply_movement.rb:103`) y además tiene el CHECK constraint
como última red.

### 2.5 PgBouncer: qué rompe el transaction pooling

Cuando la cuenta de §2.2 no cierra, la respuesta es un pooler. PgBouncer tiene
tres modos:

| Modo | La conexión de servidor se devuelve… | Reuso | Qué rompe |
|---|---|---|---|
| `session` | al cerrar la conexión del cliente | bajo | nada, pero tampoco ahorra mucho |
| `transaction` | al terminar **cada** transacción | alto | bastante (ver abajo) |
| `statement` | después de **cada** sentencia | máximo | todo lo que sea multi-sentencia; no lo uses con Rails |

Con `transaction` pooling, **dos sentencias consecutivas de tu app pueden caer en
conexiones de servidor distintas**. De ahí salen todos los problemas:

* **Prepared statements.** Rails, por defecto, prepara las sentencias con nombre
  (`PREPARE a1 …` / `EXECUTE a1`). El `PREPARE` vive en la conexión de servidor;
  el `EXECUTE` puede tocar otra ⇒ `PG::InvalidSqlStatementName: prepared
  statement "a1" does not exist`, o al revés, `already exists`. Arreglo:
  `prepared_statements: false` en `database.yml` (o PgBouncer ≥ 1.21 con
  `max_prepared_statements > 0`, que soporta prepared statements a nivel
  protocolo). El costo de apagarlos es re-planificar cada query: medible, pero
  mucho menor que caerte.
* **Advisory locks de sesión.** `pg_advisory_lock()` es **de sesión**: se libera
  al cerrar la conexión. Con transaction pooling la "sesión" no es estable, así
  que tomás el lock en una conexión y lo intentás liberar en otra ⇒ lock
  filtrado para siempre. Esto pega directo en las **migraciones**: Rails toma un
  advisory lock de sesión para que no corran dos `db:migrate` en paralelo. Regla
  operativa: **las migraciones se corren contra Postgres directo, nunca a través
  del PgBouncer en transaction mode**. La variante segura para el código de
  aplicación es `pg_advisory_xact_lock()`, que se libera con el COMMIT.
* **Los `SET` de sesión.** Los `variables:` de §2.4 se aplican con `SET` al
  conectar. En transaction pooling esa conexión de servidor puede terminar
  sirviendo a otro cliente con tus timeouts pegados, o al revés, tu app puede
  agarrar una conexión sin ellos. Por eso el generador de `strong_migrations`
  imprime literalmente: *"If you use PgBouncer in transaction mode, delete these
  lines and set timeouts on the database user"* — o sea, `ALTER ROLE app SET
  statement_timeout = '15s'`, que se aplica del lado del servidor.
* **`LISTEN`/`NOTIFY`, cursores `WITH HOLD`, tablas temporales,
  `SET LOCAL` fuera de transacción**: todo lo que dependa de que la sesión sea
  tuya. Este repo no se ve afectado por `LISTEN/NOTIFY` porque Solid Cable
  **hace polling** (`config/cable.yml`, `polling_interval: 0.1.seconds`), no
  LISTEN/NOTIFY como el adapter `postgresql` clásico de Action Cable.

---

## 3. Multi-database en Rails 8

### 3.1 Las cuatro bases

Rails 8 arranca con `primary`, `cache`, `queue` y `cable`
(`config/database.yml:62-77`). La idea: que la carga de infraestructura no
contamine la base de negocio. Solid Cache reescribe filas constantemente, Solid
Queue tiene un patrón de INSERT/DELETE brutal — dos cosas que ensucian el vacuum
y las estadísticas de tu base de dominio. Además podés tirar la base de cache sin
pensarlo.

Cada base tiene su propio directorio de migraciones (`migrations_paths:`) y su
propio schema (`db/cache_schema.rb`, `db/queue_schema.rb`, `db/cable_schema.rb`),
y `db:version` te contesta por cada una:

```bash
$ bin/rails db:version
database: stock_development
Current version: 20260830161300

database: stock_development_cache
Current version: 1

database: stock_development_queue
Current version: 1

database: stock_development_cable
Current version: 1
```

Todas las tareas `db:*` tienen variante por base: `db:migrate:primary`,
`db:schema:load:queue`, `db:rollback:cache`, etc.

### 3.2 `connects_to` y `connected_to`

`connects_to` es **declarativo, a nivel de clase**: dice de qué base come una
jerarquía de modelos. En este repo lo usan los engines de Rails:

```ruby
# config/environments/production.rb:54
config.solid_queue.connects_to = { database: { writing: :queue } }
```

La forma general, para tus propios modelos:

```ruby
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class                      # app/models/application_record.rb:25
  connects_to database: { writing: :primary, reading: :replica }
end
```

`connected_to` es **imperativo, por bloque**:

```ruby
ActiveRecord::Base.connected_to(role: :reading) do
  Queries::StockItems::Valuation.call        # todo adentro va a la réplica
end
```

Dos detalles que se preguntan:

* `role:` (writing/reading) elige el **rol**; `shard:` elige el **shard**. Son
  ejes independientes.
* `connected_to` afecta al **thread/fiber actual**, no a la app. Si adentro del
  bloque encolás un job, el job **no** hereda el rol: corre en otro proceso.

### 3.3 Réplicas de lectura y el problema del lag

En `config/database.yml:80-84` está el bloque de ejemplo:

```yaml
# replica:
#   <<: *default
#   database: stock_development
#   replica: true          # <- Rails NUNCA escribe acá y no corre migraciones
#   database_tasks: false  # <- ni db:migrate ni db:schema:dump
```

* `replica: true` marca la conexión como de sólo lectura para Rails.
* `database_tasks: false` saca esa entrada de las tareas `db:*`. Sin esto,
  `db:migrate` intenta migrar la réplica y explota (o peor: le escribe).

**El problema real es el lag.** La replicación de Postgres es asincrónica por
defecto: después de un COMMIT en el primario, la réplica puede tardar
milisegundos o segundos. Escenario clásico:

```
t0  POST /stock_items/1/receive   -> UPDATE en el primario, COMMIT
t1  302 redirect
t2  GET  /stock_items/1           -> lee de la RÉPLICA
t3  la réplica todavía no aplicó el WAL de t0
    => el usuario ve la cantidad VIEJA justo después de haberla cambiado
```

Es *read-your-writes* roto, y en un sistema de stock es inaceptable: el operario
carga 50 unidades, refresca y ve las de antes. Va a cargarlas de nuevo.

Rails trae `ActiveRecord::Middleware::DatabaseSelector`, que resuelve el 90% del
problema con una heurística: si esta sesión escribió hace menos de `delay`
segundos, leé del primario.

```ruby
# config/initializers/multi_db.rb (lo genera `bin/rails g active_record:multi_db`)
Rails.application.configure do
  config.active_record.database_selector = { delay: 2.seconds }
  config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
  config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
end
```

Lo que tenés que poder decir en una entrevista es **por qué eso no alcanza**:

1. El contexto por defecto es la **sesión HTTP**. Un cliente de API con token
   (como el de este repo, `app/models/api_token.rb`) no tiene sesión: no hay
   dónde guardar el timestamp.
2. El `delay` es un número mágico. Si el lag real supera los 2 s (un backup, un
   `VACUUM FULL`, una migración pesada), volvés a leer datos viejos.
3. **Los jobs no pasan por el middleware.** Un job que corre a los 100 ms de la
   escritura y lee de la réplica ve el estado anterior. Este es el bug de
   producción más común con réplicas y por eso los jobs de este repo reciben
   **ids**, no objetos, y releen del primario.

La solución determinística, cuando hace falta de verdad, es comparar LSNs
(`pg_current_wal_lsn()` en el primario contra `pg_last_wal_replay_lsn()` en la
réplica) o simplemente **enrutar a mano**: lecturas de reporte a la réplica
(`Queries::*`), lecturas del camino transaccional al primario. Es lo que hace
que la separación `queries/` vs `services/` de `docs/01-arquitectura.md` sea algo
más que estética.

### 3.4 Lo que NO cruza bases

**Una transacción de Rails no abarca dos bases.** Esto:

```ruby
ActiveRecord::Base.transaction do
  stock_item.update!(quantity_on_hand: 40)   # primary
  SomeCacheModel.create!(...)                # cache  <- OTRA conexión, OTRA transacción
end
```

son **dos** transacciones independientes. No hay XA, no hay two-phase commit, no
hay `@Transactional` distribuido. Si la segunda falla, la primera ya commiteó.
Es exactamente el mismo dual write que resuelve el outbox
(`db/migrate/20260830161100_create_outbox_events.rb`), y la razón por la que
Solid Queue en la **misma** base es transaccionalmente distinto de Sidekiq sobre
Redis (`config/initializers/sidekiq.rb:20-33`).

Tampoco hay JOINs entre bases. Si querés cruzar, traés ids y hacés dos queries.

---

## 4. Migraciones: qué son y cómo se rompen

Una migración es una clase Ruby con un timestamp en el nombre. Rails guarda los
timestamps aplicados en la tabla `schema_migrations` y corre los que faltan, **en
orden de timestamp**, no en orden de merge. Es la diferencia con Flyway
(`V1__`, `V2__`, estrictamente secuencial) y se parece más a Liquibase con
changelogs.

Consecuencia práctica: si vos y un compañero crean migraciones el mismo día y la
de él se mergea primero pero tiene timestamp posterior, en tu máquina ya
migraste la tuya y la de él corre después; en producción corren en orden de
timestamp. **El orden de aplicación puede diferir entre entornos.** Por eso las
migraciones tienen que ser independientes entre sí.

### 4.1 `change` vs `up`/`down`

`change` es una DSL **reversible**: Rails sabe invertir cada comando. Todas las
migraciones de este repo usan `change` (`db/migrate/*.rb`).

| Reversible automáticamente | No reversible ⇒ usá `up`/`down` o `reversible` |
|---|---|
| `create_table`, `create_join_table` | `execute` (SQL crudo) |
| `add_column`, `add_index`, `add_reference` | `change_column` (Rails no sabe el tipo anterior) |
| `add_foreign_key`, `add_check_constraint` | `remove_column` **sin** especificar tipo |
| `rename_table`, `rename_column`, `rename_index` | `change_column_default` sin `from:`/`to:` |
| `enable_extension` | `drop_table` sin bloque |
| `change_column_null`, `change_column_comment` | cualquier migración de **datos** |

Cuando no se puede, tenés tres formas:

```ruby
# 1) up/down explícitos
def up
  execute "CREATE INDEX CONCURRENTLY ... "
end

def down
  execute "DROP INDEX CONCURRENTLY ..."
end

# 2) reversible: para mezclar en un change
def change
  create_table :cosas do |t| ... end

  reversible do |dir|
    dir.up   { execute "CREATE VIEW ..." }
    dir.down { execute "DROP VIEW ..." }
  end
end

# 3) decir explícitamente que no se puede
def down
  raise ActiveRecord::IrreversibleMigration
end
```

El `change_column_default` sí es reversible **si** le pasás `from:` y `to:` —
detalle que se pregunta:

```ruby
change_column_default :products, :currency, from: "USD", to: "ARS"   # reversible
change_column_default :products, :currency, "ARS"                    # irreversible
```

### 4.2 Migraciones de datos vs de esquema: nunca juntas

La tentación es obvia: agrego la columna y la lleno en la misma migración.
Cuatro razones para no hacerlo, en orden de importancia:

1. **La migración de esquema tiene que ser rápida y transaccional; la de datos,
   larga y por lotes.** Un `UPDATE` sobre 5M de filas dentro de la transacción
   DDL mantiene la tabla bloqueada y llena el WAL. Los backfills se hacen con
   `disable_ddl_transaction!` y `in_batches`.
2. **El deploy es una ventana de versiones mezcladas.** Durante el rollout
   conviven código viejo y nuevo. Si el backfill corre antes de que el código
   nuevo esté desplegado, escribís con las reglas viejas.
3. **Los modelos en las migraciones mienten.** Si escribís
   `Product.find_each { |p| p.update!(...) }` dentro de una migración, estás
   usando el modelo de **hoy** con validaciones y callbacks de **hoy** para
   arreglar datos de **ayer**. Seis meses después, alguien agrega una validación
   y `db:migrate:reset` explota en una migración de 2026. La forma correcta,
   si insistís, es una clase efímera:

   ```ruby
   class BackfillCurrency < ActiveRecord::Migration[8.1]
     disable_ddl_transaction!

     class Product < ActiveRecord::Base   # <- clase local, SIN validaciones ni callbacks
       self.table_name = "products"
     end

     def up
       Product.where(currency: nil).in_batches(of: 1_000) do |batch|
         batch.update_all(currency: "USD")
         sleep 0.01   # deja respirar a la réplica
       end
     end
   end
   ```

   Mejor todavía: `update_all` con SQL puro, sin instanciar objetos.
4. **Rollback.** Revertir un esquema es determinístico; revertir datos, no.
   Si van juntas, no podés revertir una sin la otra.

Regla del equipo: **una migración de esquema no toca filas; una migración de
datos no toca DDL.** Y las de datos, idealmente, son tareas rake idempotentes y
re-ejecutables, no migraciones.

---

## 5. `strong_migrations`: el capítulo importante

`gem "strong_migrations", "~> 2.0"` (`Gemfile:131`, resuelta a **2.8.0** en
`Gemfile.lock`). Lo que hace es simple: **falla en desarrollo** cuando escribís
una migración que en producción tomaría un lock peligroso, y te imprime la
versión segura.

No hay initializer en este repo, así que corre con los defaults. Si lo generás
(`bin/rails g strong_migrations:install`) obtenés esto —vale la pena leerlo
porque documenta las decisiones—:

```ruby
StrongMigrations.start_after = 20260830161300
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
StrongMigrations.auto_analyze = true
# StrongMigrations.target_version = "16"
# StrongMigrations.safe_by_default = true
```

### 5.1 El problema real no es tu lock: es la COLA de locks

Esto es lo que hay que entender antes que cualquier receta, y es lo que separa
una respuesta de entrevista mediocre de una buena.

Postgres tiene una cola de locks **FIFO y no reordenable**. Cuando pedís un
`ACCESS EXCLUSIVE` (que es lo que toma casi todo `ALTER TABLE`):

```
t0  Un SELECT lento sobre stock_items lleva 30 s corriendo (tiene ACCESS SHARE).
t1  Tu migración pide ACCESS EXCLUSIVE  -> se ENCOLA detrás del SELECT.
t2  Llega un SELECT normal de la app    -> se encola detrás de TU ALTER.
t3  Llegan 200 requests más             -> todas encoladas.
t4  A los 30 s el SELECT lento termina, tu ALTER corre en 2 ms, y se libera todo.
```

Entre t1 y t4 **la tabla está caída para todo el mundo**, aunque tu `ALTER`
tarde 2 milisegundos. El culpable no es el `ALTER`: es que un lock pendiente
bloquea a todos los que llegan detrás.

De ahí salen las dos reglas de oro:

1. **`lock_timeout` bajo, siempre.** Si en 10 s no conseguiste el lock, abortá y
   reintentá. Preferís una migración que falla a una app caída. Está puesto en
   `config/database.yml:54` (10 s) y `strong_migrations` lo vuelve a poner por
   migración.
2. **Reintento con backoff**, porque una migración que aborta por `lock_timeout`
   no es un error: es el mecanismo funcionando.

```ruby
class AddSomethingSafely < ActiveRecord::Migration[8.1]
  def change
    5.times do |i|
      begin
        add_column :products, :something, :string
        break
      rescue ActiveRecord::LockWaitTimeout
        raise if i == 4
        sleep 2**i
      end
    end
  end
end
```

Y una advertencia que casi nadie sabe: **`statement_timeout` NO limita la espera
por un lock**. El reloj de `statement_timeout` corre sobre la ejecución; la
espera en la cola de locks la controla `lock_timeout`. Por eso hacen falta los
dos.

### 5.2 `add_column` con default: seguro desde PG 11

Antes de PostgreSQL 11, agregar una columna con `DEFAULT` reescribía la tabla
entera con `ACCESS EXCLUSIVE`. Desde PG 11, el default **no volátil** se guarda
en el catálogo (`pg_attribute.atthasmissing`) y las filas viejas lo resuelven al
leer: la operación es **instantánea**.

`strong_migrations` lo sabe: su adapter de Postgres devuelve
`add_column_default_safe? => true`
(`strong_migrations-2.8.0/lib/strong_migrations/adapters/postgresql_adapter.rb:49`).
O sea que esto **pasa** el check en PG 11+:

```ruby
add_column :products, :featured, :boolean, default: false, null: false   # ✅ instantáneo
```

Lo que **sigue** siendo peligroso, y strong_migrations sigue bloqueando:

| Operación | Por qué |
|---|---|
| default **volátil** (`gen_random_uuid()`, `random()`, `clock_timestamp()`) | cada fila necesita un valor distinto ⇒ reescritura completa |
| `t.virtual ... stored: true` sobre una tabla existente | la columna generada hay que materializarla en cada fila ⇒ reescritura |
| columna auto-incremental (`serial`, `bigserial`) | ídem |
| `add_column ... :json` | Postgres no tiene operador de igualdad para `json`: rompe cualquier `SELECT DISTINCT` existente. Usá `jsonb` (§7.2) |

El patrón seguro para un default volátil (lo que imprime el propio gem):

```ruby
class AddUuidToProducts < ActiveRecord::Migration[8.1]
  def up
    add_column :products, :uuid, :uuid                       # sin default: instantáneo
    change_column_default :products, :uuid, -> { "gen_random_uuid()" }   # sólo filas nuevas
  end

  def down
    remove_column :products, :uuid
  end
end

class BackfillUuidToProducts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!                                   # backfill por lotes, fuera de la tx DDL

  def up
    Product.unscoped.in_batches(of: 1_000) do |batch|
      batch.update_all("uuid = gen_random_uuid()")
      sleep 0.01
    end
  end
end
```

### 5.3 `add_index`: siempre `CONCURRENTLY`

Un `CREATE INDEX` normal toma un lock que **bloquea las escrituras** de la tabla
durante toda la construcción. En una tabla como `stock_movements` (append-only,
crece sin parar) eso es una caída de escrituras de minutos.

```ruby
class AddIndexOnStockMovementsReason < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!                    # OBLIGATORIO: CONCURRENTLY no corre en transacción

  def change
    add_index :stock_movements, :reason, algorithm: :concurrently
  end
end
```

Tres cosas que hay que saber y que se preguntan:

1. **`disable_ddl_transaction!` es obligatorio.** Postgres no permite
   `CREATE INDEX CONCURRENTLY` dentro de una transacción, y Rails envuelve cada
   migración en una por defecto. Si te olvidás: `PG::ActiveSqlTransaction`.
2. **Sin transacción, no hay rollback automático.** Si la migración falla a la
   mitad, quedás en un estado intermedio. Por eso una migración con
   `disable_ddl_transaction!` debería hacer **una sola cosa**.
3. **`CONCURRENTLY` puede dejar un índice INVÁLIDO.** Si falla (por ejemplo, por
   una violación de unicidad al construir un índice único), el índice queda en
   `pg_index` con `indisvalid = false`: ocupa lugar, se mantiene en cada
   escritura y **el planner no lo usa**. Hay que buscarlo y borrarlo a mano:

   ```sql
   SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
   DROP INDEX CONCURRENTLY index_que_quedo_invalido;
   ```

   `strong_migrations` tiene `remove_invalid_indexes = true` para que la
   siguiente corrida los limpie sola.

Lo mismo para borrar: `remove_index :tabla, column: :x, algorithm: :concurrently`.

(Los índices de este repo se crearon todos dentro de los `create_table`
originales — `db/migrate/20260830160600_create_stock_items.rb:65-75` — y eso es
seguro: **sobre una tabla nueva, que nadie está usando, ninguna de estas reglas
aplica**. `strong_migrations` lo detecta con `new_table?` y no molesta.)

### 5.4 `NOT NULL` sin bloquear: el CHECK `NOT VALID`

`ALTER TABLE ... SET NOT NULL` tiene que verificar **todas** las filas con
`ACCESS EXCLUSIVE` tomado. En una tabla grande, eso es minutos de caída.

El truco (Postgres 12+): un CHECK `NOT VALID` se agrega **sin** escanear la
tabla; después lo validás con un lock mucho más liviano; y con el CHECK validado
presente, el `SET NOT NULL` es instantáneo porque Postgres se ahorra el escaneo.

```ruby
# Migración 1: agregar el check sin validar (instantáneo)
class AddBinLocationNotNullToStockItems < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :stock_items, "bin_location IS NOT NULL",
                         name: "stock_items_bin_location_null", validate: false
  end
end

# Migración 2 (después del backfill): validar. Escanea, pero NO bloquea escrituras.
class ValidateBinLocationNotNull < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :stock_items, name: "stock_items_bin_location_null"
    change_column_null :stock_items, :bin_location, false   # ahora es instantáneo
    remove_check_constraint :stock_items, name: "stock_items_bin_location_null"
  end
end
```

Y **nunca** `change_column_null :tabla, :col, false, "valor_default"`: esa forma
dispara un `UPDATE` de la tabla entera en una sola sentencia.

### 5.5 FK y CHECK: agregar `NOT VALID`, validar después

Misma idea:

```ruby
# Migración 1
add_foreign_key :stock_movements, :products, validate: false     # no bloquea escrituras
# Migración 2
validate_foreign_key :stock_movements, :products
```

Un `add_foreign_key` normal bloquea escrituras en **las dos** tablas mientras
verifica. Con `validate: false` sólo toma un lock corto; la FK ya se aplica a las
filas nuevas y la validación posterior revisa las viejas sin bloquear.

Ojo: `validate_foreign_key` y `validate_check_constraint` escanean la tabla. Si
tenés `statement_timeout` de 15 s, esa validación se va a morir. Por eso
`strong_migrations` sube el `statement_timeout` a 1 hora sólo para las
migraciones, manteniendo el `lock_timeout` bajo. Es exactamente la combinación
correcta: **paciencia para ejecutar, impaciencia para esperar locks**.

### 5.6 `remove_column`: primero `ignored_columns`

Sacar una columna parece inofensivo y es de lo que más rompe deploys, por una
razón de Rails, no de Postgres: **Active Record cachea las columnas de la
tabla**. Durante el deploy, los procesos viejos siguen con el schema cacheado y
generan `SELECT` e `INSERT` que nombran la columna borrada ⇒
`PG::UndefinedColumn` en producción hasta que termine el rollout.

Secuencia correcta (tres deploys):

```ruby
# Deploy 1: decirle a Rails que la ignore
class Product < ApplicationRecord
  self.ignored_columns += ["barcode"]
end

# Deploy 2: recién ahora, la migración
class RemoveBarcodeFromProducts < ActiveRecord::Migration[8.1]
  def change
    safety_assured { remove_column :products, :barcode, :string }
  end
end

# Deploy 3: sacar el ignored_columns
```

`remove_column :products, :barcode, :string` — **con el tipo** — es lo que la
hace reversible.

### 5.7 Renombrar sin downtime: expand–contract

`rename_column` es irrecuperablemente peligroso en una app viva: entre que corre
la migración y que termina el deploy, el código viejo escribe en una columna que
ya no existe. No hay forma de hacerlo atómico. El patrón es **expand–contract**
(también llamado parallel change), y aplica igual para renombrar una tabla,
cambiar un tipo o partir una columna en dos:

| Fase | Deploy | Qué hacés | Estado |
|---|---|---|---|
| **Expand** | 1 | `add_column :products, :sku_code, :citext` (sin default, instantáneo) | las dos columnas existen; nadie escribe la nueva |
| | 2 | El código escribe en **las dos** y lee de la vieja | doble escritura |
| | 3 | Backfill por lotes de la vieja a la nueva (`disable_ddl_transaction!`) | datos sincronizados |
| **Switch** | 4 | El código lee de la **nueva**, sigue escribiendo en las dos | la vieja es el respaldo; si algo sale mal, volvés atrás sin perder datos |
| **Contract** | 5 | El código deja de escribir la vieja; `ignored_columns` sobre la vieja | |
| | 6 | `remove_column` de la vieja | listo |

Cada fase es un deploy independiente y **reversible por sí solo**. Ese es el
punto: en ningún momento hay una ventana donde el código y el esquema estén en
desacuerdo. Lo mismo, con menos pasos, sirve para cambiar el tipo de una columna
(`change_column` reescribe la tabla entera con `ACCESS EXCLUSIVE`: no lo hagas).

Excepción práctica: un trigger que mantenga las dos columnas sincronizadas te
ahorra los deploys 2 y 3, a cambio de meter un trigger que `schema.rb` no sabe
representar (§6.2).

### 5.8 Los escapes

```ruby
safety_assured { execute "..." }   # "yo sé lo que hago, en esta operación"
StrongMigrations.start_after = 20260830161300   # las migraciones viejas no se revisan
StrongMigrations.target_version = "16"          # revisar contra la versión de PRODUCCIÓN,
                                                # no contra la que tenés en la laptop
StrongMigrations.safe_by_default = true         # add_index pasa a ser CONCURRENTLY solo
```

`target_version` importa más de lo que parece: si desarrollás contra PG 16 y
producción está en PG 10, `add_column` con default **te reescribe la tabla** y el
gem no te iba a avisar.

### 5.9 Tabla resumen

| Operación | Lock en Postgres | Forma segura |
|---|---|---|
| `add_column` sin default | `ACCESS EXCLUSIVE` breve | ✅ segura tal cual |
| `add_column` con default constante (PG 11+) | `ACCESS EXCLUSIVE` breve | ✅ segura tal cual |
| `add_column` con default volátil | reescribe la tabla | columna → `change_column_default` → backfill |
| `add_column` virtual `stored: true` | reescribe la tabla | expand–contract |
| `add_index` | bloquea **escrituras** | `algorithm: :concurrently` + `disable_ddl_transaction!` |
| `remove_index` | bloquea escrituras | ídem |
| `change_column` (tipo) | reescribe la tabla | expand–contract |
| `change_column_null false` | bloquea lecturas y escrituras | CHECK `NOT VALID` → `validate` → `SET NOT NULL` |
| `add_foreign_key` | bloquea escrituras en **dos** tablas | `validate: false` → `validate_foreign_key` |
| `add_check_constraint` | bloquea lecturas y escrituras | `validate: false` → `validate_check_constraint` |
| `add_unique_constraint` | crea un índice único bloqueante | índice único `CONCURRENTLY` → usarlo para la constraint |
| `remove_column` | breve, pero rompe el código viejo | `ignored_columns` un deploy antes |
| `rename_column` / `rename_table` | breve, pero rompe el código viejo | expand–contract |
| `execute "..."` | lo que vos escribas | `safety_assured`, y pensalo dos veces |

---

## 6. `schema.rb` vs `structure.sql`

`db/schema.rb` es un **dump declarativo** del esquema, generado después de cada
`db:migrate`, y es lo que carga `db:schema:load` (que es como se crea la base de
test: rápido y sin re-ejecutar 17 migraciones).

### 6.1 Qué SÍ representa (más de lo que la gente cree)

Mirando `db/schema.rb` de este repo, el dumper de Rails 8.1 captura:

| Cosa | Ejemplo en el repo |
|---|---|
| Extensiones | `enable_extension "citext"`, `"pg_trgm"`, `"btree_gin"` (`db/schema.rb:15-18`) |
| Índices parciales | `where: "(revoked_at IS NULL)"` (`db/schema.rb:34`) |
| Índices con `opclass` y `using` | `opclass: :gin_trgm_ops, using: :gin` (`db/schema.rb:127`) |
| Índices con orden | `order: { occurred_at: :desc, id: :desc }` (`db/schema.rb:240`) |
| CHECK constraints | los 5 de `stock_items` (`db/schema.rb:214-218`) |
| Columnas generadas | `t.virtual "quantity_available", ... stored: true` (`db/schema.rb:203`) |
| Arrays | `t.string "scopes", default: [], array: true` (`db/schema.rb:27`) |
| Tipos PG (`citext`, `jsonb`, `uuid`) | `t.citext "sku"` (`db/schema.rb:120`) |
| Defaults por función | `t.uuid "event_id", default: -> { "gen_random_uuid()" }` (`db/schema.rb:77`) |
| PK no convencional | `create_table "sequence_counters", primary_key: "key", id: :string` (`db/schema.rb:177`) |
| FK con `on_delete` | `add_foreign_key "stock_movements", "users", on_delete: :nullify` (`db/schema.rb:372`) |
| Tipos ENUM nativos | `create_enum` (Rails 7.0+; este repo no los usa a propósito, ver `db/migrate/20260830154959_create_users.rb`) |
| Exclusion constraints | `t.exclusion_constraint` (Rails 7.1+) |

### 6.2 Qué NO puede representar

El dumper genérico hace, en este orden: `schemas`, `extensions`, `types`,
`tables`, `virtual_tables`. Todo lo demás **no existe** para `schema.rb`:

* **Vistas** y **vistas materializadas** (para eso está la gema `scenic`).
* **Triggers**.
* **Funciones** y procedimientos almacenados (gema `fx`).
* **Sequences sueltas** (las que creás con `CREATE SEQUENCE`, no las de un
  `bigserial`).
* **Domains**, **tipos compuestos**, **rangos custom**.
* **Row Level Security** (policies).
* **Particiones** de tablas particionadas.
* **GRANTs**, roles, `COMMENT ON` de objetos que no sean tablas/columnas.
* Cualquier cosa que hayas creado con `execute "..."` en una migración.

El síntoma es siempre el mismo y es **traicionero**: la migración corre bien en
desarrollo (donde ejecutaste el `execute`), pero la base de **test** se arma con
`db:schema:load` y ahí el objeto no existe. Los tests fallan con un error de
Postgres que no tiene nada que ver con el test.

### 6.3 El caso real de este repo: `sequence_counters`

Necesitamos referencias legibles y **sin huecos**: `PO-2026-000045`
(`app/models/purchase_order.rb:56`). Las tres opciones:

| Opción | Concurrencia | Huecos | `schema.rb` |
|---|---|---|---|
| `count + 1` en Ruby | ❌ race condition de manual | — | ✅ |
| `SEQUENCE` de Postgres (`nextval`) | ✅ rapidísima, no bloquea | ❌ **deja huecos**: `nextval` no se revierte en un rollback | ❌ **no la representa** |
| Tabla de contadores + `UPSERT ... RETURNING` | ✅ atómica, serializa por contador | ✅ sin huecos: vive en tu transacción | ✅ |

Elegimos la tercera (`db/migrate/20260830161300_create_sequence_counters.rb`,
`app/models/sequence_counter.rb:16-50`) por **dos** razones, y las dos importan:

1. **Sin huecos.** `nextval` es no-transaccional a propósito (para no serializar).
   Si la transacción hace rollback, el número se perdió: `PO-000044`,
   `PO-000046`. Para un id interno da igual; para un comprobante fiscal, en varios
   países es ilegal.
2. **`schema.rb` no sabe qué es una sequence suelta.** Si la creás con
   `execute "CREATE SEQUENCE po_ref_seq"`, funciona en desarrollo y **desaparece**
   en la base de test. Esa limitación es, textualmente, la razón por la que
   muchos equipos migran a `structure.sql`.

El costo de la tabla: los que piden el **mismo** contador se hacen cola en la
fila (`UPDATE` toma un `ROW EXCLUSIVE` sobre esa fila hasta el COMMIT). Como el
contador es por (tipo, año), la contención es aceptable — y es el precio
inevitable de la numeración sin huecos. Si necesitás correlativos sin huecos y
alto throughput, no existe: son objetivos contradictorios.

### 6.4 Cuándo pasar a `structure.sql`, y qué cuesta

```ruby
# config/application.rb
config.active_record.schema_format = :sql
```

A partir de ahí, `db:migrate` genera `db/structure.sql` con `pg_dump -s` y
`db:schema:load` lo carga con `psql`. Ventaja: **captura absolutamente todo**,
porque es el dump nativo.

Costos reales, que también se preguntan:

* Necesitás `pg_dump` en el PATH de **CI y del contenedor de deploy**, y su
  versión mayor tiene que ser ≥ la del servidor.
* El diff en git es horrible: `pg_dump` reordena cosas y mete OIDs y `SET`s de
  sesión. Cada merge de dos ramas con migraciones es un conflicto.
* Perdés la portabilidad a otras bases (que en la práctica no te importa).
* La tabla `schema_migrations` se dumpea como `INSERT`s: es normal, no lo
  edites.

Criterio: **quedate en `schema.rb` hasta que necesites una vista, un trigger o
una función.** Ese día pasás a `structure.sql` y no mirás atrás. Mientras tanto,
`schema.rb` es más legible y hace mejores diffs. (Y en cualquiera de los dos
casos: `db/schema.rb` está marcado `linguist-generated` en `.gitattributes` para
que GitHub lo colapse en los PRs.)

Una trampa fina de `schema.rb` en este repo: las columnas de tiempo se dumpean
como `t.datetime`, no como `t.timestamptz`. Son `timestamptz` en la base **porque
el initializer de §7.4 lo dice**. Si alguien borra ese initializer, un
`db:schema:load` te reconstruye la base con `timestamp without time zone` y no te
enterás hasta que los horarios empiecen a dar mal.

---

## 7. Los tipos de Postgres que usamos

### 7.1 `citext` — texto case-insensitive

`db/migrate/20260830154900_enable_postgres_extensions.rb:27`. Lo usan `users.email_address`,
`products.sku`, `warehouses.code`, `categories.slug`, `suppliers.tax_id`/`email`.

```bash
$ psql -d stock_development -c "select 'TOR-M5-20'::citext = 'tor-m5-20'::citext as igual;"
 igual
-------
 t
```

Y a nivel Rails, sin ningún `LOWER()` en la query:

```bash
$ bin/rails runner 'puts Product.where("sku = ?", "tor-m5-20").count'
1
```

La alternativa es `LOWER(col)` con índice funcional, que obliga a acordarse del
`LOWER()` en **todos** los caminos de lectura y escritura. `citext` baja la
invariante a la base: el índice `UNIQUE` sobre `citext` hace que `'ABC-1'` y
`'abc-1'` colisionen y no hay forma de olvidarse.

Detalle: `citext` **guarda** el texto como lo escribiste (no lo baja a
minúsculas), sólo compara sin distinguir mayúsculas. Por eso el
`normalizes :sku, with: ->(s) { s.to_s.strip.upcase }`
(`app/models/product.rb:29`) sigue teniendo sentido: normaliza cómo se **muestra**.

### 7.2 `jsonb` vs `json`: no es una preferencia

| | `json` | `jsonb` |
|---|---|---|
| Almacenamiento | texto crudo, tal cual lo mandaste | binario parseado |
| Preserva orden de claves y duplicados | ✅ | ❌ (normaliza) |
| Escritura | más rápida | un poco más lenta (parsea) |
| Lectura / operadores | reparsea cada vez | directo |
| Indexable con GIN | ❌ | ✅ |
| **Operador `=`** | **no existe** | ✅ |

Ese último punto es el que rompe cosas:

```bash
$ psql -d stock_development -c "select '{\"a\":1}'::json = '{\"a\":1}'::json;"
ERROR:  operator does not exist: json = json

$ psql -d stock_development -c "select '{\"b\":2,\"a\":1}'::jsonb = '{\"a\":1,\"b\":2}'::jsonb as igual;"
 igual
-------
 t
```

Sin operador de igualdad, cualquier `SELECT DISTINCT`, `GROUP BY` o `UNION` sobre
una tabla que tenga una columna `json` **falla**. Por eso `strong_migrations`
bloquea `add_column ... :json` y te dice que uses `jsonb`.

Y la normalización de `jsonb`, que sorprende:

```bash
$ psql -d stock_development -c "select '{\"b\":2,\"a\":1, \"a\":3}'::jsonb as normalizado,
                                       '{\"b\":2,\"a\":1, \"a\":3}'::json as crudo;"
   normalizado    |        crudo
------------------+----------------------
 {"a": 3, "b": 2} | {"b":2,"a":1, "a":3}
```

`jsonb` reordena las claves, borra los espacios y se queda con la **última**
clave duplicada. Si necesitás el documento byte a byte (una firma, un webhook que
vas a re-verificar), `jsonb` no sirve: guardalo como `text`.

En este repo `jsonb` se usa en `products.attributes_data`, `suppliers.metadata`,
`stock_movements.metadata`, `outbox_events.payload`/`metadata`,
`idempotency_keys.response_body`. Con índice GIN donde se consulta:

```ruby
# db/migrate/20260830160200_create_suppliers.rb
add_index :suppliers, :metadata, using: :gin, opclass: :jsonb_path_ops
```

`jsonb_path_ops` indexa sólo el operador `@>` (contención): es más chico y más
rápido que el `jsonb_ops` por defecto, a cambio de no servir para `?` (existencia
de clave). Si sólo hacés `metadata @> '{"tier":"gold"}'`, es la elección correcta.

Regla de diseño: `jsonb` para atributos **abiertos y no consultados por el
dominio**. Todo lo que tenga una regla de negocio va a una columna con su tipo,
su CHECK y su índice. `jsonb` no es una excusa para no modelar.

### 7.3 Arrays

```ruby
# db/migrate/20260830160000_create_api_tokens.rb
t.string :scopes, array: true, null: false, default: []
add_index :api_tokens, :scopes, using: :gin
```

Rails los mapea a `Array` de Ruby de forma transparente. El índice GIN habilita
`WHERE scopes @> ARRAY['stock:write']` con índice (un B-tree no sirve para
"contiene").

Cuándo usar array y cuándo tabla de unión: **array** para una lista corta, fija y
sin atributos propios, que se lee entera siempre (los scopes de un token).
**Tabla de unión** apenas necesites atributos en la relación o hacer JOIN
—`product_suppliers` tiene precio, lead time y SKU del proveedor, así que es un
modelo de primera clase con `has_many :through`, no un array.

### 7.4 `timestamptz` vs `timestamp`

Rails, por razones históricas, crea columnas `timestamp` **sin** zona. Este repo
lo cambia globalmente:

```ruby
# config/initializers/postgresql_types.rb
ActiveSupport.on_load(:active_record_postgresqladapter) do
  self.datetime_type = :timestamptz
end
```

Verificado en la base:

```bash
$ psql -d stock_development -c "\d stock_items" | grep created_at
 created_at | timestamp(6) with time zone | not null
```

Por qué importa, en términos que un javero entiende de una: **`timestamp` es
`LocalDateTime` y `timestamptz` es `Instant`**. `LocalDateTime` sin zona no
identifica un instante; sólo funciona si *toda* la cadena respeta la misma
convención tácita.

Rails "arregla" el problema convirtiendo todo a UTC antes de escribir… siempre
que la escritura pase por Rails. Pero:

* Un `psql` a mano, un dashboard de BI, un job de Python o una réplica lógica no
  conocen la convención y comparan naive contra naive.
* `now()` de Postgres devuelve `timestamptz`. Compararlo contra una columna
  `timestamp` fuerza una conversión implícita con el `TimeZone` de la sesión,
  que puede dar mal y —peor— **puede invalidar el uso del índice**.
* El horario de verano es irresoluble sin la zona.

`timestamptz` no guarda la zona: guarda el instante absoluto en UTC y lo renderiza
en la zona que pidas. El contra-caso legítimo —"las 9 de la mañana hora local de
cada sucursal"— quiere `timestamp` naive + la zona en otra columna. Es raro, y
para eso `warehouses` ya tiene su columna `timezone` (`app/models/warehouse.rb:19`).

Cambiar columnas existentes de `timestamp` a `timestamptz` requiere un
`ALTER ... USING`, que **reescribe la tabla**: va con expand–contract (§5.7).

### 7.5 Plata: `bigint` de centavos, no `float`, y `decimal` cuando corresponde

Nunca `float`/`double` para dinero (`0.1 + 0.2 != 0.3` en IEEE-754). Quedan dos
opciones válidas:

| | `numeric`/`decimal` + `BigDecimal` | `bigint` de centavos |
|---|---|---|
| Exactitud | ✅ | ✅ |
| Velocidad | más lento (aritmética de software en la base y en Ruby) | ✅ entero nativo |
| Aritmética en Ruby | `BigDecimal`, cuidado con `Float` colado | `Integer`, imposible equivocarse |
| Fracciones de centavo | ✅ | ❌ |
| Necesita Value Object | no | sí, o te olvidás de dividir por 100 |

Este repo elige **`bigint` de centavos + Value Object**
(`app/models/value_objects/money.rb`, expuesto con la macro `has_money` de
`app/models/concerns/has_money.rb`), que es lo que hace Stripe. `bigint` aguanta
~92 billones de centavos.

`decimal` igual aparece donde la fracción es física y no monetaria:
`products.weight_grams` es `decimal(12,3)` — miligramos exactos.

### 7.6 `uuid`

```ruby
# db/migrate/20260830161100_create_outbox_events.rb:42
t.uuid :event_id, null: false, default: -> { "gen_random_uuid()" }
```

`gen_random_uuid()` viene en Postgres 13+ sin extensiones (antes hacía falta
`pgcrypto`). El tipo `uuid` ocupa 16 bytes; guardarlo como `varchar(36)` ocupa
37 y no valida nada.

Decisión de diseño del repo: **las PKs son `bigint`, no `uuid`**. El `uuid` se usa
sólo para el identificador que **sale al exterior** (el `event_id` que los
consumidores usan para deduplicar). Razón: un `uuid` v4 es aleatorio, así que
cada INSERT cae en una página distinta del índice ⇒ B-trees enormes, mal
locality, WAL inflado. Un `bigint` secuencial inserta siempre a la derecha del
árbol. Si necesitás ids opacos hacia afuera, la respuesta moderna es UUID v7
(ordenable por tiempo), no v4.

### 7.7 Columnas generadas

```ruby
# db/migrate/20260830160600_create_stock_items.rb:44
t.virtual :quantity_available, type: :integer,
          as: "quantity_on_hand - quantity_reserved", stored: true
```

Postgres 12+ las calcula y **persiste** en cada INSERT/UPDATE. Ventajas sobre
calcularlas en Ruby: no se pueden desincronizar, se pueden **indexar**
(`index_stock_items_needing_reorder`, un índice parcial sobre la generada) y las
ven todos los clientes de la base. Es la `@Formula` de Hibernate, pero
materializada.

**La trampa, verificada:**

```bash
$ bin/rails runner '
si = StockItem.first
si.quantity_available = 999
puts "changed: #{si.changes.inspect}"
si.save!
si.reload
puts "despues del reload: #{si.quantity_available}"'

changed: {"quantity_available"=>[105, 999]}
UPDATE "stock_items" SET "updated_at" = '...', "lock_version" = 13
  WHERE "stock_items"."id" = 1 AND "stock_items"."lock_version" = 12
despues del reload: 105
```

Tres cosas para leer despacio:

1. El dirty tracking **registra** el cambio (`changes` lo muestra).
2. La columna generada **no aparece en el UPDATE**: la asignación se descarta en
   silencio. No hay excepción, no hay warning. `StockItem.readonly_attributes`
   devuelve `[]`.
3. **Pero el UPDATE se emite igual**, y bumpea `lock_version` y `updated_at`. O
   sea: asignar a una columna generada no hace nada útil y sí invalida el
   optimistic lock de otro proceso.

Por eso `ApplyMovement#apply_to` hace `item.reload` después del `save!`
(`app/services/stock/apply_movement.rb:139`): es la única forma de leer el
`quantity_available` correcto. En Hibernate, `@Generated(ALWAYS)` dispara el
SELECT de refresco solo; acá lo pedís a mano.

---

## 8. Constraints: la única garantía real

### 8.1 CHECK

Este repo tiene **32 CHECK constraints** en `db/schema.rb`. No son decoración:
codifican las invariantes del dominio en el único lugar donde nadie las puede
saltear.

```ruby
# db/migrate/20260830160600_create_stock_items.rb:77-85
add_check_constraint :stock_items, "quantity_on_hand >= 0",             name: "stock_items_on_hand_non_negative"
add_check_constraint :stock_items, "quantity_reserved <= quantity_on_hand", name: "stock_items_reserved_lte_on_hand"
```

Y el más interesante, la coherencia signo ↔ tipo del ledger
(`db/migrate/20260830160700_create_stock_movements.rb:104`):

```sql
(kind IN ('receipt','transfer_in','return')   AND quantity > 0) OR
(kind IN ('issue','transfer_out','scrap')     AND quantity < 0) OR
(kind IN ('adjustment','count_correction'))
```

Un CHECK puede referenciar **varias columnas de la misma fila**, y eso alcanza
para modelar una máquina de estados:

```sql
-- stock_reservations: si está committed, committed_at no puede ser NULL
(status <> 'committed') OR (committed_at IS NOT NULL)
```

Lo que un CHECK **no** puede hacer: mirar otras filas u otras tablas (no es
determinístico bajo MVCC). Para eso están las FK y las exclusion constraints.

Nombralos siempre (`name:`). Un CHECK sin nombre recibe uno generado que cambia
entre entornos y no lo podés borrar de forma reproducible.

### 8.2 Índices únicos parciales

El truco que más impresiona en una entrevista y que **no se puede expresar con
validaciones de Rails**:

```ruby
# db/migrate/20260830160500_create_product_suppliers.rb:33
add_index :product_suppliers, :product_id,
          unique: true, where: "preferred",
          name: "index_one_preferred_supplier_per_product"
```

"Como mucho un proveedor preferido por producto". Con una validación de Rails
necesitarías un `validates_uniqueness_of ... conditions:` y aun así tendría la
race condition de §9. Con el índice parcial, Postgres lo garantiza y encima el
índice sólo contiene las filas `preferred` (15 entradas en vez de 200.000).

El mismo patrón para la idempotencia:

```ruby
# db/migrate/20260830160700_create_stock_movements.rb:89
add_index :stock_movements, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"
```

Sin el `where`, todos los movimientos internos (sin clave) competirían por el
índice. Con él, sólo se indexan los que tienen clave. Y ojo con la semántica de
`NULL` en un índice único: en Postgres, `NULL` **no colisiona con NULL** (a menos
que uses `NULLS NOT DISTINCT`, PG 15+), así que el `where` acá es por tamaño, no
por corrección — pero el tamaño es la mitad del punto.

### 8.3 Exclusion constraints

Es el `UNIQUE` generalizado: en vez de "no puede haber dos filas iguales", dice
"no puede haber dos filas que se **solapen** según este operador". El caso
canónico es la reserva de recursos por rango de tiempo:

```ruby
# Requiere: enable_extension "btree_gist"   (este repo NO la tiene habilitada:
# las extensiones activas son citext, pg_trgm, btree_gin y plpgsql)
add_exclusion_constraint :room_bookings,
  "room_id WITH =, during WITH &&",
  using: :gist,
  name: "no_overlapping_bookings"
```

Postgres rechaza cualquier reserva cuyo rango `during` se solape con otra de la
misma sala. **Eso es imposible de garantizar desde la aplicación sin bloquear**:
en Ruby harías `SELECT` de solapamientos y después `INSERT`, con la misma
ventana de carrera de §9.

Este repo no la usa porque el dominio de stock no tiene rangos: las reservas
(`stock_reservations`) son cantidades, no intervalos, y la invariante se resuelve
con `quantity_reserved <= quantity_on_hand`. Pero es la respuesta correcta si en
la entrevista te preguntan "¿cómo evitás dobles reservas de un mismo turno?".

### 8.4 Foreign keys y `on_delete`

Rails **no** crea FKs si no se lo pedís. `t.references :product` sin
`foreign_key:` te da la columna y el índice, y nada más. En este repo todas las
FKs son explícitas y todas eligen su `on_delete`:

| `on_delete` | SQL | Qué hace | Dónde se usa acá |
|---|---|---|---|
| `:cascade` | `ON DELETE CASCADE` | borra los hijos | `sessions`, `api_tokens`, `idempotency_keys` → `users`; `purchase_order_lines` → `purchase_orders` |
| `:restrict` | `ON DELETE RESTRICT` | prohíbe borrar el padre | casi todo el dominio: `stock_items`, `stock_movements`, `purchase_orders`… |
| `:nullify` | `ON DELETE SET NULL` | pone NULL en el hijo | `stock_movements` → `users`, `stock_reservations` → `users` |
| (sin opción) | `NO ACTION` | como RESTRICT pero **diferible** al final de la transacción | — |

La decisión de diseño se lee sola en `db/schema.rb:356-381`: **la historia
contable nunca se borra en cascada.** Un movimiento de stock sobrevive al borrado
del usuario que lo hizo (`nullify`), y no podés borrar un producto que tiene
movimientos (`restrict`). Por eso además existe el soft delete
(`app/models/concerns/discardable.rb`).

Dos precisiones para el javero:

* `on_delete:` es del **lado de Postgres**; `dependent:` es del **lado de Rails**
  (§11.5). No son lo mismo y conviene tener los dos: `dependent:` da mensajes de
  error lindos, la FK garantiza que un `DELETE FROM` en `psql` tampoco rompa nada.
* La diferencia entre `RESTRICT` y `NO ACTION`: `RESTRICT` chequea de inmediato;
  `NO ACTION` puede diferirse al COMMIT si la constraint es `DEFERRABLE INITIALLY
  DEFERRED`. Eso es lo que te permite tener referencias circulares que se resuelven
  dentro de una transacción.

**Y siempre indexá la columna de la FK.** Postgres indexa automáticamente el lado
referenciado (la PK), **nunca** el referenciante. Sin ese índice, cada borrado del
padre hace un Seq Scan del hijo para verificar la FK. Rails lo hace bien por
defecto (`t.references` crea el índice), y por eso las migraciones de este repo
que ponen `index: false` (`db/migrate/20260830160600_create_stock_items.rb:29`)
explican en el comentario que hay un índice compuesto que ya cubre la columna
como prefijo izquierdo.

---

## 9. Validaciones vs constraints: la carrera de `validates_uniqueness_of`

Este es el ejemplo que hay que tener listo para la entrevista, porque separa a
quien leyó la guía de Rails de quien sufrió producción.

`app/models/stock_item.rb:36` tiene:

```ruby
validates :product_id, uniqueness: { scope: :warehouse_id }
```

Lo que Rails ejecuta, capturado del log real:

```sql
StockItem Exists? (0.6ms)
SELECT 1 AS one FROM "stock_items"
WHERE "stock_items"."product_id" = 1 AND "stock_items"."warehouse_id" = 1
LIMIT 1
```

Un `SELECT`. **Sin `FOR UPDATE`, sin lock de ningún tipo, en una sentencia
separada del `INSERT`.** Bajo READ COMMITTED, el timeline de dos requests
concurrentes es:

```
        Transacción A                          Transacción B
t0      BEGIN
t1                                             BEGIN
t2      SELECT 1 ... LIMIT 1  -> vacío
t3                                             SELECT 1 ... LIMIT 1  -> vacío
t4      valid? => true
t5                                             valid? => true
t6      INSERT (product 1, warehouse 1)
t7                                             INSERT (product 1, warehouse 1)
t8      COMMIT
t9                                             COMMIT   <-- ¿y ahora?
```

**Sin índice único**, en t9 quedan dos `stock_items` para el mismo par
(producto, depósito). A partir de ese momento el stock queda partido en dos filas
y nunca más cierra: cada operación toma una u otra según el orden del índice.
Es de los bugs de datos más caros que existen, porque no explota — se degrada.

**Con el índice único** (`db/migrate/20260830160600_create_stock_items.rb:65`),
en t7 la transacción B se **bloquea** (Postgres la hace esperar hasta saber si A
commitea) y en t9 recibe `PG::UniqueViolation`, que Active Record traduce a
`ActiveRecord::RecordNotUnique`.

Y entonces la pregunta que sigue: **¿para qué sirve la validación, si el índice
hace el trabajo?** Para el 99,9% de los casos en que no hay carrera: darle al
usuario un mensaje de error en el formulario en vez de un 500. Es defensa en
profundidad, no redundancia:

| | `validates ... uniqueness` | Índice `UNIQUE` |
|---|---|---|
| Atomicidad | ❌ | ✅ |
| Mensaje de error usable | ✅ | ❌ (excepción) |
| Se aplica a `update_column`, seeds, `psql` | ❌ | ✅ |
| Costo | un SELECT extra por save | ninguno (ya lo pagás) |

El patrón correcto es **confiar en el índice y rescatar el choque**
(`app/models/stock_item.rb:121-125`):

```ruby
def self.find_or_provision!(product:, warehouse:)
  find_by(product:, warehouse:) || create!(product:, warehouse:)
rescue ActiveRecord::RecordNotUnique
  # El otro proceso ganó la carrera: su fila ya está commiteada, la leemos.
  find_by!(product:, warehouse:)
end
```

`find_or_create_by!` tiene exactamente la misma race condition y **no** la
rescata: por eso no se usa.

Un detalle que se pregunta: si estás **dentro** de una transacción y comés el
`RecordNotUnique`, la transacción ya está abortada
(`PG::InFailedSqlTransaction` en la siguiente sentencia). El rescate sólo
funciona si la inserción está en su propio `SAVEPOINT`
(`transaction(requires_new: true)`) o si no hay transacción externa. En
`find_or_provision!` se llama desde `ItemResolver`, fuera de la transacción del
service.

La misma lógica aplica a los CHECK: las validaciones de `StockMovement`
(`app/models/stock_movement.rb:35`) duplican a propósito el CHECK de la
migración. La validación da el mensaje; el CHECK garantiza que ni un script, ni
un seed, ni un `psql` metan basura.

---

## 10. Callbacks: el orden real y dónde está la trampa

### 10.1 El orden, verificado

```bash
$ bin/rails runner '
class P3 < ApplicationRecord
  self.table_name = "warehouses"
  before_validation { puts "  1 before_validation" }
  after_validation  { puts "  2 after_validation" }
  before_save       { puts "  3 before_save" }
  around_save       { |_, b| puts "  4 around_save (pre)"; b.call; puts "  8 around_save (post)" }
  before_create     { puts "  5 before_create" }
  after_create      { puts "  6 after_create" }
  after_save        { puts "  7 after_save" }
  after_commit      { puts "  9 after_commit" }
end
P3.create!(code: "ZZ-8196", name: "probe")'

  1 before_validation
  2 after_validation
  3 before_save
  4 around_save (pre)
  5 before_create
TRANSACTION  BEGIN
P3 Create    INSERT INTO "warehouses" (...) RETURNING "id"
  6 after_create
  8 around_save (post)
  7 after_save
TRANSACTION  COMMIT
  9 after_commit
```

Dos cosas que salen sólo de correrlo:

* **El `BEGIN` se emite *lazy*, justo antes del INSERT.** Rails 7.2+ no manda el
  `BEGIN` hasta que hay una sentencia que lo necesita. Si tu `before_validation`
  hace una query, esa query **sí** abre la transacción y queda adentro.
* **`around_save` (post) corre antes que `after_save`.** El orden completo es:
  `after_create` → cierre del `around_save` → `after_save`.

El orden general:

| Momento | `create` | `update` | `destroy` |
|---|---|---|---|
| 1 | `before_validation` | `before_validation` | — |
| 2 | *validaciones* | *validaciones* | — |
| 3 | `after_validation` | `after_validation` | — |
| 4 | `before_save` / `around_save` | ídem | — |
| 5 | `before_create` / `around_create` | `before_update` / `around_update` | `before_destroy` / `around_destroy` |
| 6 | **INSERT** | **UPDATE** | **DELETE** |
| 7 | `after_create` | `after_update` | `after_destroy` |
| 8 | `after_save` | `after_save` | — |
| 9 | **COMMIT** | **COMMIT** | **COMMIT** |
| 10 | `after_commit` (o `after_rollback`) | ídem | ídem |

Del 4 al 8, todo corre **dentro** de la transacción. El 10, **después del COMMIT**.

### 10.2 `after_save` vs `after_commit`

Verificado, con rollback incluido:

```bash
$ bin/rails runner '...'
--- caso 1: transaccion que commitea
  after_save  (dentro de la tx)
  (fin del bloque, antes del COMMIT)
  after_commit (post COMMIT)
--- caso 2: transaccion con rollback
  after_save  (dentro de la tx)
  after_rollback
```

Con rollback, `after_save` **ya corrió**. Ahí está todo el problema:

```ruby
after_save :enviar_email   # ❌ el mail sale aunque la transacción se revierta
after_save :llamar_api     # ❌ el POST sale aunque la transacción se revierta
after_save :encolar_job    # ❌ el worker levanta el job antes del COMMIT y no encuentra la fila
```

**Regla: todo efecto que salga del proceso va en `after_commit`.** Todo lo que
tenga que ser atómico con el registro va en `after_save`. En Rails 8.1 tenés
alias específicos: `after_create_commit`, `after_update_commit`,
`after_destroy_commit`, `after_save_commit`.

El caso del repo, `app/models/purchase_order_line.rb:23`:

```ruby
after_save :refresh_order_totals
after_destroy :refresh_order_totals
```

Y `refresh_order_totals` llama a `purchase_order.recalculate_totals!`
(`app/models/purchase_order.rb:43`), que hace un `update_columns` con
`lines.sum(:subtotal_cents)`. **`after_save` es lo correcto acá**: el total del
padre tiene que ser atómico con la línea. Si la transacción se revierte, no
querés un total recalculado sobre líneas que ya no existen. (El comentario de
`purchase_order_line.rb:20` dice "after_commit y no after_save"; el código dice
`after_save`. **El código está bien y el comentario quedó viejo**: acá el efecto
es *interno a la base y a la misma transacción*, que es exactamente la excepción
a la regla del párrafo anterior.)

### 10.3 Las tres trampas de `after_commit`

1. **No es transaccional.** Si el proceso muere entre el COMMIT de Postgres y la
   ejecución del callback en Ruby, el callback **nunca corre** y no queda rastro.
   Por eso los eventos de dominio van al **outbox**
   (`db/migrate/20260830161100_create_outbox_events.rb`), en la misma
   transacción, y un proceso aparte los publica. `after_commit` no es un
   sustituto del outbox: es la mitad no confiable.
2. **Una excepción en un `after_commit` no revierte nada.** La transacción ya
   commiteó, así que la excepción **sale del bloque** hacia el que llamó y rompés
   la request con los datos ya guardados. Verificado:

   ```bash
   $ bin/rails runner '
   class P4 < ApplicationRecord
     self.table_name = "warehouses"
     after_commit { raise "explota en after_commit" }
   end
   begin; P4.create!(code: "ZZ-1", name: "probe"); rescue => e; puts "salio: #{e.message}"; end
   puts "la fila quedo guardada? #{Warehouse.exists?(code: "ZZ-1")}"'

   salio: explota en after_commit
   la fila quedo guardada? true
   ```

   (En Rails 4.2 estas excepciones se tragaban y se logueaban; desde Rails 5
   propagan. Si el efecto puede fallar, va en un job, no en el callback.)
3. **`after_commit` no corre en tests con transactional fixtures**… bueno, sí
   corre desde Rails 5 gracias a `test_framework` y los savepoints, pero el
   `after_commit` de una transacción anidada con `requires_new: true` se dispara
   sólo cuando commitea la **transacción externa**. Los savepoints no tienen
   commit propio.

### 10.4 Por qué los callbacks con efectos son una trampa de diseño

Más allá del `after_save`/`after_commit`, hay un argumento arquitectónico: un
callback es **una dependencia invisible que se dispara desde cualquier lado**.
Un `Product.update!(name: "x")` en una tarea rake, en un seed o en una consola
dispara todos los callbacks del modelo, incluidos los que mandan mails o llaman
APIs. No hay forma de decir "guardá pero sin efectos" sin ensuciar el modelo con
flags (`skip_callbacks`, `@importing = true`), que es el olor clásico.

Por eso, en este repo, los efectos externos viven en los **services**
(`app/services/stock/apply_movement.rb`), que se llaman explícitamente, reciben
sus colaboradores por constructor (`event_recorder:`, `clock:`) y devuelven un
`Result`. Los callbacks quedan para lo que realmente es responsabilidad del
registro: normalizar (`before_validation`), derivar campos de la propia fila
(`denormalize_from_stock_item`, `app/models/stock_movement.rb:68`) y mantener
consistencia interna dentro de la misma transacción.

---

## 11. Asociaciones

### 11.1 `belongs_to` es obligatorio por defecto

Desde Rails 5, `belongs_to` agrega `validates presence` automáticamente. Para
permitir NULL hay que decirlo:

```ruby
belongs_to :category, optional: true                       # app/models/product.rb:11
belongs_to :user, optional: true                           # app/models/stock_movement.rb:18
belongs_to :reference, polymorphic: true, optional: true   # app/models/stock_movement.rb:19
```

Es lo contrario de JPA, donde `@ManyToOne` es opcional salvo
`@JoinColumn(nullable = false)`.

### 11.2 `has_many :through` y `has_one :through`

```ruby
# app/models/product.rb:16-22
has_many :product_suppliers, dependent: :destroy
has_many :suppliers, through: :product_suppliers

has_one :preferred_product_supplier, -> { where(preferred: true) },
        class_name: "ProductSupplier", inverse_of: :product, dependent: nil
has_one :preferred_supplier, through: :preferred_product_supplier, source: :supplier
```

* Si la tabla de unión **tiene atributos propios** (precio, lead time, SKU del
  proveedor), es un modelo de primera clase y va `has_many :through`.
  `has_and_belongs_to_many` (sin modelo) sólo sirve para joins puras, y casi
  siempre terminás necesitando atributos. Equivale a preferir una entidad de
  unión sobre `@ManyToMany` en JPA, por las mismas razones.
* `source:` hace falta cuando el nombre de la asociación no coincide con el de la
  asociación en el modelo intermedio (`preferred_supplier` → `supplier`).
* El scope inline `-> { where(preferred: true) }` combinado con el índice único
  parcial de §8.2 es el par completo: la base garantiza que hay como mucho uno, y
  el `has_one` lo trae.

### 11.3 Polimórficas: por qué no hay foreign key

```ruby
# app/models/stock_movement.rb:19
belongs_to :reference, polymorphic: true, optional: true
```

En la base son dos columnas sueltas (`db/migrate/20260830160700_create_stock_movements.rb:59-60`):

```ruby
t.string :reference_type    # "PurchaseOrder", "StockTransfer", …
t.bigint :reference_id
```

**No hay `add_foreign_key`, y no puede haberlo**: una FK apunta a **una** tabla,
y acá el destino depende del valor de otra columna. SQL no tiene eso. Las
consecuencias son concretas:

* Podés tener `reference_id = 999` apuntando a una `PurchaseOrder` que no
  existe. La base no se entera.
* Un `ON DELETE` no existe: si borrás la orden, el movimiento queda huérfano.
* Los JOINs son incómodos y no usan bien los índices (hay que filtrar por
  `reference_type` primero — de ahí el índice
  `[:reference_type, :reference_id] where reference_type IS NOT NULL`).
* El `reference_type` guarda **el nombre de la clase Ruby**: si renombrás
  `PurchaseOrder`, tenés que migrar datos.

Las tres alternativas, para tener la respuesta lista:

1. **Columnas exclusivas (arco):** una FK por tipo, todas nullables, más un CHECK
   de "exactamente una no nula". Integridad referencial real, a costa de una
   columna por tipo posible.
   ```sql
   CHECK (num_nonnulls(purchase_order_id, stock_transfer_id) = 1)
   ```
2. **Supertabla:** una tabla `documents` con la PK, y `purchase_orders` /
   `stock_transfers` con FK a ella. Es la herencia de tabla del modelo
   relacional. Correcto y caro (un JOIN más siempre).
3. **Aceptar el polimorfismo** y compensar con tests y un job de auditoría. Es lo
   que hace este repo: para un ledger, la referencia es informativa (dice *por
   qué* pasó el movimiento), no una dependencia dura.

### 11.4 `inverse_of`: cuándo hace falta de verdad

Sin `inverse_of`, `product.stock_items.first.product` es **otro objeto** que
vuelve a la base. Con `inverse_of`, es el mismo objeto en memoria. Importa por
dos cosas: una query menos, y —más importante— que las validaciones sobre el
padre no vean un objeto desactualizado.

Rails lo detecta solo en muchos casos. Verificado en este repo:

```bash
$ bin/rails runner '...'
Product#stock_items       -> inverse_of: :product   (opciones: [:dependent])
Product#product_suppliers -> inverse_of: :product   (opciones: [:dependent])
StockItem#product         -> inverse_of: nil        (opciones: [])
```

Y lo que **rompe** la detección automática, también verificado:

```bash
$ bin/rails runner '
class Probe2 < ApplicationRecord
  self.table_name = "products"
  has_many :stock_items, foreign_key: :product_id
end
puts Probe2.reflect_on_association(:stock_items).inverse_of.inspect'

nil
```

**Basta con pasar `foreign_key:` para que Rails deje de deducir el inverso.** Por
eso las asociaciones con nombre no convencional del repo lo declaran a mano:

```ruby
# app/models/user.rb:19
has_many :requested_transfers, class_name: "StockTransfer",
         foreign_key: :requested_by_id, dependent: :restrict_with_error,
         inverse_of: :requested_by

# app/models/category.rb:7
has_many :children, class_name: "Category", foreign_key: :parent_id,
         dependent: :restrict_with_error, inverse_of: :parent
```

Regla operativa: **si pasás `foreign_key:`, `as:` o `through:`, pasá también
`inverse_of:`.** Con `class_name:` solo, Rails todavía lo deduce (lo confirma
`PurchaseOrder#lines`), pero declararlo no cuesta nada.

Nota: `belongs_to` **nunca** obtiene inverso automático (por eso
`StockItem#product` da `nil`); se resuelve desde el lado del `has_many`.

### 11.5 `dependent:` — los valores y lo que cuestan

Valores válidos en Rails 8.1 (los saqué del código del builder):

| Valor | `has_many` | `has_one` | `belongs_to` | Qué hace |
|---|:--:|:--:|:--:|---|
| `:destroy` | ✅ | ✅ | ✅ | carga cada hijo e invoca sus callbacks. **N queries** |
| `:delete_all` / `:delete` | ✅ | ✅ | ✅ | un solo `DELETE`. **Sin callbacks** |
| `:nullify` | ✅ | ✅ | — | un `UPDATE ... SET fk = NULL` |
| `:restrict_with_error` | ✅ | ✅ | — | agrega un error de validación si hay hijos |
| `:restrict_with_exception` | ✅ | ✅ | — | levanta `DeleteRestrictionError` |
| `:destroy_async` | ✅ | ✅ | ✅ | encola un job que destruye los hijos |

Lo que hay que saber:

* `:destroy` **instancia cada hijo**: borrar un padre con 50.000 hijos son 50.000
  `DELETE` más sus callbacks. Es el `CascadeType.REMOVE` de JPA con el mismo
  problema de performance, y la razón por la que un "borrar cliente" tarda 4
  minutos.
* `:delete_all` es un solo `DELETE`, pero **se saltea los callbacks de los
  hijos**: si los nietos dependían de esos callbacks, quedan huérfanos. Sólo es
  seguro si además tenés `ON DELETE CASCADE` en la base.
* `:destroy_async` mueve el problema a un job. Necesita que la FK **no** sea
  `RESTRICT` (o el padre no se puede borrar hasta que el job termine): es útil,
  pero hay que pensarlo con la FK.
* **`dependent:` no aplica a `delete_all` sobre la relación, ni a `update_all`,
  ni a un `DELETE` en `psql`.** Es lógica de Rails. La red real es el `on_delete`
  de la FK (§8.4). Este repo tiene los dos, y coordinados: donde Rails dice
  `restrict_with_error`, la FK dice `RESTRICT`; donde Rails dice `nullify`, la FK
  dice `SET NULL`.

En este repo, el criterio es explícito: **destroy sólo donde el hijo no tiene
valor sin el padre** (`product_suppliers`, `purchase_order_lines`, `sessions`,
`api_tokens`), `nullify` para los movimientos que sobreviven al usuario, y
`restrict_with_error` para todo lo que sea historia
(`app/models/product.rb:13-18`, `app/models/user.rb:17`).

### 11.6 `counter_cache` y `touch`

```ruby
class PurchaseOrderLine < ApplicationRecord
  belongs_to :purchase_order, counter_cache: true    # requiere lines_count en el padre
end
```

`counter_cache` hace que Rails mantenga `purchase_orders.lines_count` con
`UPDATE ... SET lines_count = lines_count + 1` en cada create/destroy del hijo,
para que `order.lines.size` no haga `COUNT(*)`.

**Este repo NO lo usa**, aunque `purchase_orders` tenga `lines_count`
(`db/migrate/20260830161000_create_purchase_orders.rb`). El mantenimiento es
manual (`app/models/purchase_order.rb:43`):

```ruby
def recalculate_totals!
  update_columns(
    total_cents: lines.sum(:subtotal_cents),
    lines_count: lines.count,
    updated_at: Time.current
  )
end
```

La razón: además del conteo hace falta el **total**, y `counter_cache` sólo sabe
contar. Recalcular las dos cosas de una vez, con `sum(:subtotal_cents)` sobre la
columna generada de Postgres, garantiza que ninguna de las dos se desincronice.

Lo que hay que saber de `counter_cache` igual, porque se pregunta:

* **Serializa las escrituras del padre.** Todo INSERT de un hijo hace UPDATE de
  la misma fila padre: si insertás 1.000 líneas concurrentes en una orden, todas
  se hacen cola en esa fila. En una tabla caliente es una fuente real de
  contención y deadlocks.
* **`update_column`/`update_all`/`delete_all` lo desincronizan** (no pasan por
  los callbacks). Existe `Model.reset_counters(id, :lines)` para arreglarlo.
* Rails 6.1+ tiene `counter_cache: { active: false }` para migrar sin downtime.

`touch: true` en un `belongs_to` actualiza el `updated_at` del padre en cada save
del hijo. Sirve para invalidar cache de fragmentos (`cache [order, "lines"]`) y
tiene **exactamente el mismo problema de contención**, más uno peor: si el padre
también tiene `touch: true` hacia su propio padre, una escritura de hoja actualiza
toda la cadena hacia arriba. Ese es el "touch storm" clásico.

---

## 12. Herramientas

### 12.1 Las tareas `db:*`

| Tarea | Qué hace | Cuándo |
|---|---|---|
| `db:prepare` | crea si no existe, migra si existe | **la que va en el deploy** |
| `db:migrate` | corre las migraciones pendientes | día a día |
| `db:migrate:status` | lista `up`/`down` por migración | "¿por qué no corrió la mía?" |
| `db:rollback STEP=n` | revierte n migraciones | sólo en local |
| `db:migrate:redo` | rollback + migrate | probar que tu `down` funciona |
| `db:schema:load` | carga `schema.rb` de cero | base de test; **destruye datos** |
| `db:seed` / `db:seed:replant` | corre `db/seeds.rb` (el segundo truncando antes) | `db/seeds.rb` es idempotente a propósito |
| `db:reset` | drop + schema:load + seed | reset de desarrollo |
| `db:version` | versión actual **por base** | |
| `db:schema:cache:dump` | genera `db/schema_cache.yml` | ahorra el `SELECT` de columnas al bootear en producción |

Todas tienen sufijo por base: `db:migrate:primary`, `db:rollback:queue`, etc.

En producción, `config.active_record.dump_schema_after_migration = false`
(`config/environments/production.rb:77`): el servidor de producción no tiene por
qué escribir `schema.rb`.

### 12.2 `dbconsole`

```bash
$ bin/rails dbconsole --database=primary
```

Abre `psql` con las credenciales de `database.yml` ya resueltas (incluido el
`DATABASE_URL` de producción). Con multi-base, `--database=` no es opcional en la
práctica. Verificado:

```bash
$ printf 'select count(*) from products;\n' | bin/rails dbconsole --database=primary
 count
-------
    15
```

### 12.3 `EXPLAIN`

Desde Rails, sobre cualquier relación:

```bash
$ bin/rails runner 'puts Product.kept.active.order(:name).limit(5).explain(:analyze, :verbose)'

EXPLAIN (ANALYZE, VERBOSE) SELECT "products".* FROM "products"
 WHERE "products"."discarded_at" IS NULL AND "products"."active" = TRUE
 ORDER BY "products"."name" ASC LIMIT 5
                                       QUERY PLAN
------------------------------------------------------------------------------------------
 Limit  (cost=8.17..8.17 rows=1 width=301) (actual time=0.044..0.046 rows=5 loops=1)
   ->  Sort  (cost=8.17..8.17 rows=1 width=301) (actual time=0.043..0.044 rows=5 loops=1)
         Sort Key: products.name
         Sort Method: top-N heapsort  Memory: 27kB
         ->  Index Scan using index_products_active_by_category on public.products
             (cost=0.14..8.16 rows=1 width=301) (actual time=0.012..0.017 rows=15 loops=1)
 Planning Time: 0.112 ms
 Execution Time: 0.066 ms
```

Ahí se ve funcionando el índice **parcial compuesto**
`index_products_active_by_category` (`where: "discarded_at IS NULL AND active"`).

⚠️ **Cuidado con la firma**: en Rails 7.1+ las opciones de `explain` son
**símbolos posicionales**, no un hash. `explain(:analyze, :verbose)` funciona;
`explain(analyze: true)` genera `EXPLAIN ({:ANALYZE=>TRUE}) SELECT …` y Postgres
lo rechaza con `PG::SyntaxError`. El helper
`ApplicationRecord.explain_analyze` (`app/models/application_record.rb:44`) usa la
forma con hash y por lo tanto **está roto hoy**; usá `.explain(:analyze, :verbose)`
directo sobre la relación hasta que se corrija.

Y el recordatorio de siempre: **`ANALYZE` ejecuta la query de verdad**. Sobre un
`UPDATE` o un `DELETE`, hacelo dentro de una transacción con rollback.

Un `EXPLAIN` sobre la base de desarrollo miente por tamaño. Con 48 filas en
`stock_items`, el planner elige Seq Scan aunque exista el índice parcial:

```bash
$ psql -d stock_development -c "EXPLAIN SELECT * FROM stock_items
                                WHERE warehouse_id = 1 AND quantity_available <= reorder_point;"
 Seq Scan on stock_items  (cost=0.00..1.72 rows=5 width=92)
   Filter: ((quantity_available <= reorder_point) AND (warehouse_id = 1))
```

**No es un bug del índice: es el planner haciendo lo correcto.** Leer 48 filas
secuencialmente es más barato que ir al índice y volver a la tabla. Si vas a
juzgar un plan, hacelo contra un dataset con volumen parecido al de producción y
con `ANALYZE` corrido.

### 12.4 Logs de queries en desarrollo

```ruby
# config/environments/development.rb:55-58
config.active_record.verbose_query_logs = true     # muestra la LÍNEA de tu código que disparó la query
config.active_record.query_log_tags_enabled = true # agrega /*application='Stock',controller=...*/ al SQL
```

Los query log tags viajan hasta `pg_stat_activity`, así que en producción podés
ver **qué controller o job** está corriendo una query lenta sin adivinar. Es la
mejor herramienta que hay para cazar N+1 y queries huérfanas.

---

## Errores que ves en producción

| Síntoma | Causa | Arreglo |
|---|---|---|
| `PG::ConnectionBad: FATAL: sorry, too many clients already` | La cuenta de §2.2: workers × threads × bases × máquinas > `max_connections` | Bajar el pool a la cantidad real de threads, contar las 4 bases, y recién ahí PgBouncer |
| `ActiveRecord::ConnectionTimeoutError: could not obtain a connection from the pool within 5.000 seconds` | Pool más chico que los threads, o conexiones que no se devuelven (threads creados a mano sin `with_connection`) | `max_connections >= RAILS_MAX_THREADS`; en threads propios, `ActiveRecord::Base.connection_pool.with_connection` (ver `spec/support/concurrency.rb:33`) |
| Deploy que "cuelga" la app 3 minutos con un `ALTER TABLE` de 2 ms | La cola de locks de §5.1: una query lenta bloqueó a tu ALTER y tu ALTER bloqueó a todos | `lock_timeout` bajo + reintento con backoff |
| `PG::ActiveSqlTransaction: CREATE INDEX CONCURRENTLY cannot run inside a transaction block` | `algorithm: :concurrently` sin `disable_ddl_transaction!` | agregar `disable_ddl_transaction!` |
| Un índice que existe pero el planner nunca usa | Quedó `INVALID` de un `CONCURRENTLY` que falló | `SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid` y `DROP INDEX CONCURRENTLY` |
| `PG::UndefinedColumn: column products.barcode does not exist` durante un deploy | Se borró la columna sin `ignored_columns` un deploy antes; los procesos viejos tienen el schema cacheado | §5.6, y mientras tanto, reiniciar los procesos viejos |
| Dos filas para el mismo (producto, depósito) y el stock que "no cierra" | `validates uniqueness` sin índice único: la carrera de §9 | índice `UNIQUE` + `rescue RecordNotUnique` |
| `PG::UniqueViolation` al marcar un proveedor como preferido | El índice único parcial `index_one_preferred_supplier_per_product` | desmarcar el anterior en la misma transacción (`app/models/product_supplier.rb:21`) |
| El total de la orden no coincide con las líneas | Alguien usó `update_column`/`update_all` sobre las líneas: no dispara callbacks | recalcular con `recalculate_totals!`; o `reset_counters` si fuera `counter_cache` |
| Un mail enviado por una operación que se revirtió | Efecto externo en `after_save` en vez de `after_commit` | §10.2 |
| Un evento que se perdió sin dejar rastro | Se confió en `after_commit` para publicar; el proceso murió entre el COMMIT y el callback | outbox (`db/migrate/20260830161100_create_outbox_events.rb`) |
| El usuario carga stock, refresca y ve el valor viejo | Lectura de la réplica con lag (§3.3) | `DatabaseSelector`, o enrutar la lectura post-escritura al primario |
| Dos comprobantes con el mismo número | Query cache: `INSERT … RETURNING` ejecutado con `select_value` cuenta como SELECT | `connection.uncached { … }` + `clear_query_cache` (`app/models/sequence_counter.rb:47-48`) |
| Un objeto en memoria con `quantity_available` mentiroso | Columna generada: la calcula Postgres y el objeto no se entera | `reload` después del `save!` (`app/services/stock/apply_movement.rb:139`) |
| `PG::InvalidSqlStatementName: prepared statement "a1" does not exist` | PgBouncer en transaction pooling con prepared statements activos | `prepared_statements: false`, o PgBouncer ≥ 1.21 con `max_prepared_statements` |
| `db:migrate` que se cuelga para siempre detrás de PgBouncer | El advisory lock de sesión de las migraciones (§2.5) | migrar contra Postgres directo, sin pooler |
| El objeto existe en desarrollo y falta en test | Un `execute "CREATE …"` que `schema.rb` no sabe dumpear | pasar a `structure.sql` o modelarlo con la DSL |
| Transacción zombie que bloquea el VACUUM y hace crecer el bloat | Una transacción abierta esperando I/O externo | `idle_in_transaction_session_timeout`, y **nunca** hacer HTTP dentro de una transacción |

---

## Cómo responder esto en una entrevista

**1. "¿Qué diferencia hay entre Active Record y JPA/Hibernate?"**

> Active Record es el patrón de Fowler: el objeto sabe persistirse. JPA es Data
> Mapper con Unit of Work. En la práctica: **no hay `EntityManager`, no hay
> persistence context ni identity map, no hay flush diferido y no existen las
> entidades detached**. El dirty tracking existe pero es local al objeto y no
> escribe nada solo: si no llamás `save!`, no pasa nada. Y como no hay proxies de
> lazy loading, tocar una asociación no cargada **dispara la query en el acto**:
> nunca hay `LazyInitializationException`, sólo N+1 silencioso.
> **Trade-off**: ganás simplicidad y SQL predecible (el orden de las sentencias
> es el orden en que las escribiste); perdés el batching automático del flush y
> la garantía de una sola instancia por fila, así que el control de concurrencia
> lo tenés que hacer explícito — `lock_version` o `SELECT FOR UPDATE`.

**2. "¿Cómo dimensionás el pool de conexiones?"**

> El pool es **por proceso y por base**, no por aplicación. La cuenta es
> `procesos × bases_usadas × max_connections`, y Rails 8 corre con cuatro bases
> por defecto (primary, cache, queue, cable). Lo verifiqué en este repo: un
> proceso que arranca con un pool de 5 termina con 15 conexiones potenciales
> apenas toca el cache y la cola. La regla es `max_connections` del pool igual a
> la cantidad de threads del proceso —ni más ni menos— y `checkout_timeout` bajo
> para fallar rápido.
> **Trade-off de PgBouncer**: en transaction pooling ganás una reducción enorme
> de conexiones, pero rompés los prepared statements con nombre, los advisory
> locks de sesión (incluido el que usa `db:migrate`) y los `SET` de sesión, así
> que los timeouts hay que moverlos al rol de Postgres con `ALTER ROLE`.

**3. "Tenés que agregar un índice y una columna NOT NULL a una tabla de 50
millones de filas, sin downtime. ¿Cómo?"**

> Primero el marco: el problema no es la duración de mi `ALTER`, es que un
> `ACCESS EXCLUSIVE` pendiente **encola a todos los que llegan detrás**, así que
> un ALTER de 2 ms detrás de un SELECT de 30 s tira la tabla abajo 30 segundos.
> Entonces: `lock_timeout` de 10 s y reintento con backoff, siempre.
> El índice: `add_index ..., algorithm: :concurrently` con
> `disable_ddl_transaction!`, y después chequear que no haya quedado inválido.
> El NOT NULL: en tres pasos — `add_check_constraint "col IS NOT NULL",
> validate: false` (instantáneo), backfill por lotes en una migración aparte con
> `disable_ddl_transaction!`, y después `validate_check_constraint` +
> `change_column_null`, que con el CHECK validado ya es instantáneo.
> `strong_migrations` bloquea todo lo peligroso en desarrollo y te imprime esta
> receta. **Trade-off**: son tres o cuatro deploys en vez de uno, y una ventana en
> la que el esquema es "raro". Es el precio de no tener downtime.

**4. "¿Alcanza con `validates_uniqueness_of`?"**

> No, y se demuestra con el SQL: Rails hace un
> `SELECT 1 AS one … LIMIT 1` **sin lock** y después el INSERT. Bajo READ
> COMMITTED, dos transacciones concurrentes ven las dos "libre" y las dos
> insertan. La única garantía es el índice `UNIQUE`, que hace que la segunda
> reciba `RecordNotUnique`. La validación se deja igual, para dar un mensaje de
> error usable en el 99,9% de los casos sin carrera: es defensa en profundidad.
> El patrón es intentar y rescatar el choque, no chequear y después insertar.
> **Trade-off**: el mensaje de la excepción es feo y hay que traducirlo, y si
> estás dentro de una transacción necesitás un savepoint (`requires_new: true`)
> para poder rescatarla.

**5. "¿`after_save` o `after_commit`?"**

> `after_save` corre **dentro** de la transacción, así que corre igual si después
> hay rollback: cualquier efecto que salga del proceso (mail, HTTP, encolar un
> job) tiene que ir en `after_commit`. Lo que tenga que ser atómico con el
> registro va en `after_save` — en este repo, recalcular el total de una orden de
> compra desde sus líneas.
> Y el matiz que importa: **`after_commit` tampoco es confiable para eventos**.
> Si el proceso muere entre el COMMIT y el callback, el evento se pierde sin
> rastro. Para eso está el **outbox**: escribís el evento en la misma transacción
> y un proceso aparte lo publica, con garantía at-least-once e idempotencia del
> lado del consumidor. **Trade-off**: at-least-once significa duplicados, así que
> cada evento lleva un UUID y el consumidor tiene que deduplicar.

**6. "¿Cuándo pasarías de `schema.rb` a `structure.sql`?"**

> El día que necesite una vista, un trigger, una función, una sequence suelta o
> un tipo compuesto: `schema.rb` dumpea schemas, extensiones, tipos ENUM, tablas
> con sus índices, checks, exclusion constraints y FKs, y **nada más**. El
> síntoma típico es que el objeto creado con `execute` funciona en desarrollo y
> desaparece en la base de test, que se arma con `db:schema:load`.
> En este repo el caso concreto es el contador de referencias: usamos una tabla
> `sequence_counters` con `UPSERT … RETURNING` en vez de una `SEQUENCE` de
> Postgres, por dos motivos — `nextval` no se revierte en un rollback y deja
> huecos (inaceptable en un comprobante), y `schema.rb` no sabe representar una
> sequence suelta. **Trade-off** de la tabla: serializa a los que piden el mismo
> contador; **trade-off** de `structure.sql`: diffs horribles en git y dependencia
> de tener `pg_dump` de la versión correcta en CI.

---

## Para seguir

* `docs/00-ruby-y-rails-para-javeros.md` — Ruby, el GVL, y por qué el pool de
  conexiones se multiplica por proceso.
* `docs/01-arquitectura.md` — las capas, el patrón proyección + ledger y el
  contrato `Result`.
* `db/migrate/` — cada migración tiene su justificación escrita arriba. Empezá
  por `20260830160600_create_stock_items.rb` y `20260830160700_create_stock_movements.rb`.
