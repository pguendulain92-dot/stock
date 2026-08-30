# Observabilidad, profiling y performance

Acá está todo lo que hace falta para responder tres preguntas cuando la app ya
está en producción: **¿qué está pasando?** (logs y eventos), **¿cuánto cuesta?**
(métricas y profiling) y **¿por qué está lento?** (diagnóstico paso a paso).

Todos los números y salidas de este documento se midieron en este repo, con
Ruby 3.3.6, Rails 8.1.3.1 y PostgreSQL 16.13. Donde algo **no** está instalado
o **no** se puede correr en este entorno, lo digo explícitamente en vez de
inventar la salida.

Si venís de Java, el mapa mental arranca acá:

| Java / Spring | Rails 8 | Dónde se rompe la analogía |
|---|---|---|
| SLF4J + Logback + `logback.xml` | `Rails.logger` (`ActiveSupport::BroadcastLogger`) | No hay appenders declarativos ni XML. Configurás el objeto logger a mano en `config/environments/*.rb`. |
| MDC (`MDC.put("requestId", …)`) | `ActiveSupport::TaggedLogging` + `Current` | El MDC es un `ThreadLocal` que vos limpiás; `Current` lo resetea el framework (ver `app/models/current.rb`). |
| Micrometer `MeterRegistry` | `ActiveSupport::Notifications` | Notifications es un **bus de eventos**, no un registro de métricas. Emite eventos; agregar/contar es tu problema. |
| Spring Boot Actuator (`/actuator/health`, `/metrics`) | sólo `/up` | Rails trae **un** health check trivial. No hay `/metrics`, ni `/env`, ni `/threaddump`. Todo lo demás lo escribís vos. |
| JFR, async-profiler, VisualVM | `stackprof`, `memory_profiler`, `rack-mini-profiler` | Sampling similar, pero **no hay un agente que se enchufe a un proceso vivo**: el profiler se activa desde adentro del proceso. |
| Heap dump + MAT | `GC.stat`, `ObjectSpace`, `memory_profiler` | No hay heap dump binario estándar ni herramienta de análisis equivalente a MAT. |
| Thread pool de Tomcat | workers (procesos) + threads de Puma | Con el GVL, más threads **no** dan más CPU. La unidad de paralelismo real es el **proceso**. |
| HikariCP (un pool por app) | `ActiveRecord` pool (**uno por proceso y por base**) | Este repo tiene 4 bases: el multiplicador es `workers × threads × bases`. |

---

## 1. Logging

### 1.1 Qué logger tenés realmente

```bash
$ bin/rails runner 'puts Rails.logger.class; puts Rails.logger.broadcasts.map(&:class).inspect; puts Rails.logger.formatter.class'
ActiveSupport::BroadcastLogger
[ActiveSupport::Logger]
ActiveSupport::Logger::SimpleFormatter
```

`BroadcastLogger` (Rails 7.1+) es un **compuesto**: mantiene una lista de
loggers y le manda cada mensaje a todos. Es lo que permite que en desarrollo
escribas a `log/development.log` **y** a STDOUT sin duplicar código. En Java
serías vos configurando dos appenders en Logback; acá es un objeto que envuelve
a otros objetos.

En producción el logger se reemplaza entero (`config/environments/production.rb:37-44`):

```ruby
config.log_tags = [ :request_id ]
config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
config.silence_healthcheck_path = "/up"
```

Cuatro decisiones, las cuatro deliberadas:

* **STDOUT, no un archivo.** 12-factor, factor XI: el proceso no gestiona logs,
  los escupe. Quien rota, agrega y envía es el supervisor (systemd, Docker,
  Kamal). Un archivo dentro del contenedor se pierde en el próximo deploy.
* **`log_tags = [:request_id]`** prefija *todas* las líneas de una request con
  su id. Sin esto, con 5 threads concurrentes las líneas se intercalan y no
  podés reconstruir nada.
* **`log_level` por variable de entorno**: podés subir a `debug` en un pod
  puntual sin redeployar.
* **`silence_healthcheck_path`**: el balanceador pega a `/up` cada 5 segundos.
  Son ~17.000 líneas por día por instancia, de puro ruido, que además te cuestan
  plata en el colector.

### 1.2 Niveles: el costo real de un log que no se imprime

En Java estás acostumbrado a `if (log.isDebugEnabled())`. En Ruby el problema es
el mismo y la solución también, pero el orden de magnitud sorprende. Medido en
este repo con `Rails.logger.level = INFO` (o sea: **ninguno de estos cuatro logs
se escribe**):

```
Rails.logger (ActiveSupport::BroadcastLogger):
  debug("id=#{item.id}")                      1964 ns/op
  debug { "id=#{item.id}" }                   2411 ns/op
  debug(item.attributes.to_json)             31682 ns/op   <-- 12x
  debug { item.attributes.to_json }           2581 ns/op

Logger simple (ActiveSupport::Logger a File::NULL):
  debug("id=#{item.id}")                       536 ns/op
  debug { "id=#{item.id}" }                    169 ns/op
  debug(item.attributes.to_json)             29474 ns/op   <-- 174x
  debug { item.attributes.to_json }            167 ns/op

de referencia: item.attributes.to_json solo  28788 ns/op
```

La lección: **el argumento se evalúa siempre, el bloque no**. Con un mensaje
barato la diferencia es ruido (el bloque tiene su propio costo de `yield`); con
un mensaje que serializa un modelo, la forma con argumento cuesta 12 veces más
sobre el logger de este repo y 174 veces más sobre un logger pelado — y ese
costo lo pagás en producción, en el camino caliente, para generar una string que
se tira a la basura. Fijate que los ~29 µs son el `to_json`, no el logger: el
logger no llega ni a mirarlo.

Regla: si construir el mensaje cuesta algo (`inspect`, `to_json`, un `map`),
**usá bloque**.

> Nota sobre los números: ~2 µs por llamada suena mucho para un no-op, y la
> comparación de las dos tablas dice exactamente de dónde sale: el mismo no-op
> sobre un `ActiveSupport::Logger` pelado cuesta ~170 ns. Los otros ~1.8 µs son
> el `BroadcastLogger` recorriendo su lista de destinos. En producción el
> logger es uno solo (no hay broadcast) y baja. Lo que importa es la
> **proporción**, no el absoluto.

### 1.3 Logging estructurado: lo que este repo hace y lo que le falta

El repo loguea con hashes en todos lados. Por ejemplo `app/jobs/application_job.rb:68-73`:

```ruby
around_perform do |job, block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Rails.logger.info(event: "job.start", job: job.class.name, jid: job.job_id, queue: job.queue_name)
  block.call
  Rails.logger.info(event: "job.finish", job: job.class.name, jid: job.job_id,
                    duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1))
```

Dos cosas buenas antes de la mala:

1. **`Process::CLOCK_MONOTONIC`, no `Time.now`.** El reloj de pared salta (NTP,
   horario de verano) y te puede dar duraciones negativas. Es exactamente
   `System.nanoTime()` vs `System.currentTimeMillis()` en Java, y la misma
   trampa.
2. **Un campo `event:` estable.** El nombre del evento es la clave de agregación;
   el texto libre no se agrupa.

Y ahora la mala. Esto es lo que sale **de verdad** por el log (copiado de una
corrida real del servidor de este repo):

```
[req-123] {:event=>"stock.receive", :sku=>"TOR-M5-20", :qty=>10}
```

Eso **no es JSON**. Es `Hash#inspect` de Ruby, con `=>` y símbolos. Ni Loki ni
Datadog ni CloudWatch lo parsean: te queda como un blob de texto y perdés
exactamente lo que querías ganar. `ActiveSupport::Logger::SimpleFormatter` es
literalmente una línea — `String === msg ? msg : msg.inspect` — así que
**cualquier cosa que no sea un `String` se va por `inspect`**, incluidas las
excepciones (a diferencia del `Logger::Formatter` de la stdlib, que sí les da
trato especial y les imprime clase, mensaje y backtrace).

**El arreglo** (probado, corre tal cual en Rails 8.1):

```ruby
# config/initializers/logging.rb  (NO existe todavía en este repo)
class JsonLogFormatter < ActiveSupport::Logger::SimpleFormatter
  # ⚠️ Sin este include, `logger.tagged { }` explota con
  # NoMethodError: undefined method `tagged' for SimpleFormatter.
  # TaggedLogging delega los tags EN EL FORMATTER, no en el logger.
  include ActiveSupport::TaggedLogging::Formatter

  def call(severity, time, _progname, msg)
    payload = msg.is_a?(Hash) ? msg : { message: msg.to_s }
    { ts: time.utc.iso8601(3), level: severity, tags: current_tags }
      .merge(payload).compact_blank.to_json + "\n"
  end
end
```

Salida real con ese formatter:

```json
{"ts":"2026-08-30T18:56:26.308Z","level":"INFO","tags":["req-123"],"event":"stock.receive","sku":"TOR-M5-20","qty":10}
{"ts":"2026-08-30T18:56:26.308Z","level":"WARN","tags":["req-123","user-7"],"message":"stock bajo"}
```

El `include ActiveSupport::TaggedLogging::Formatter` es el detalle que casi
nadie sabe hasta que lo rompe: **los tags viven en el formatter**, no en el
logger. Si le asignás un formatter propio a un logger tagueado sin ese módulo,
`tagged` deja de existir y el boot revienta.

### 1.4 Correlación: request_id de punta a punta

Tres piezas, que en este repo ya están:

1. **`ActionDispatch::RequestId`** (middleware) toma el header `X-Request-Id`
   entrante o genera un UUID. Verificado:

   ```
   x-request-id: d53cf4a8-9d61-40b3-a9ef-8e20a6a346e8
   x-runtime: 0.004947
   ```

   Si tenés un proxy adelante que ya genera un id de traza, **propagalo** en ese
   header: si no, cada salto inventa el suyo y no podés unir la traza.

2. **`Current`** (`app/models/current.rb`, seteado en
   `app/controllers/application_controller.rb`) lo guarda para el resto del
   stack, y `Outbox::Recorder#default_metadata`
   (`app/services/outbox/recorder.rb`) lo copia dentro de **cada evento de
   dominio**. O sea: podés tomar una fila de `outbox_events` y encontrar la
   request HTTP que la originó.

3. **Query log tags** (`config/environments/development.rb:58`) meten el
   contexto **adentro del SQL**, como comentario. Verificado:

   ```sql
   SELECT "products".* FROM "products" WHERE "products"."discarded_at" IS NULL
   ORDER BY "products"."name" ASC, "products"."id" ASC LIMIT 2 OFFSET 0
   /*action='index',application='Stock',controller='products'*/
   ```

   ```bash
   $ bin/rails runner 'puts ActiveRecord::QueryLogs.tags.inspect'
   [:application, :job, :controller, :action]
   ```

   (El comentario sale **ordenado alfabéticamente**, no en el orden en que
   declaraste los tags: `QueryLogs#rebuild_handlers` hace un
   `sort_by! { |(key, _)| key.to_s }`. Por eso arriba se ve `action` primero y
   por eso `job` no aparece: en una request es `nil` y se descarta.)

   Esto es oro puro en una guardia: cuando mirás `pg_stat_activity` y ves una
   query de 40 segundos, el comentario te dice **qué controller la disparó** sin
   que tengas que adivinar. En Java el equivalente sería un
   `StatementInspector` de Hibernate que vos escribís; acá viene de fábrica.

   Para producción conviene agregar el `request_id` a los tags:

   ```ruby
   # config/environments/production.rb
   config.active_record.query_log_tags_enabled = true
   config.active_record.query_log_tags = [
     :application, :controller, :action, :job,
     { request_id: ->(context) { context[:controller]&.request&.request_id } }
   ]
   ```

   ⚠️ **El mito que vas a escuchar y que es falso**: "un tag de alta
   cardinalidad como `request_id` fragmenta `pg_stat_statements`". No. Postgres
   calcula el `queryid` **jumbleando el árbol de parseo**, y el lexer descarta
   los comentarios antes de eso. Comprobado en este entorno:

   ```sql
   SET compute_query_id = on;
   EXPLAIN (VERBOSE, COSTS OFF) SELECT id FROM products WHERE id = 1 /*request_id='AAA'*/;
   --   Query Identifier: -4731695479662933080
   EXPLAIN (VERBOSE, COSTS OFF) SELECT id FROM products WHERE id = 1 /*request_id='ZZZ'*/;
   --   Query Identifier: -4731695479662933080   <-- el MISMO
   ```

   Lo que sí te cuesta un tag por request:

   * **El texto que guarda `pg_stat_statements` es el de la primera ejecución
     que creó la entrada.** Vas a ver *un* `request_id` congelado ahí adentro,
     que no tiene nada que ver con las 200.000 ejecuciones que agrupa. Sacar
     conclusiones de ese comentario es el error real.
   * **Todo lo que agrupa por texto crudo sí se fragmenta**: pgBadger y demás
     analizadores de log, la salida de `auto_explain`, el `GROUP BY query` que
     te armás a mano sobre `pg_stat_activity`.
   * **Bytes**: el comentario viaja por la red en **cada** query y se repite en
     cada línea de `log_min_duration_statement`. (En el WAL no entra: el WAL
     guarda cambios físicos de tuplas, no el texto del SQL.)

   CPU no es el problema: con
   `config.active_record.cache_query_log_tags = true` (default `false`) el
   comentario se arma **una vez por request** y se reusa para todas sus
   queries; Rails invalida ese cache con
   `ActiveSupport::ExecutionContext.after_change`, o sea al cambiar de
   request/job. Regla: tags de baja cardinalidad siempre; `request_id` cuando
   te importe correlacionar el log de Postgres con el de la app.

### 1.5 Qué NO loguear

| Riesgo | Mitigación en este repo | Archivo |
|---|---|---|
| Passwords, tokens, emails en params | `filter_parameters += [:passw, :email, :secret, :token, :_key, :crypt, :salt, ...]` | `config/initializers/filter_parameter_logging.rb` |
| Un `inspect` de modelo que vuelca toda la fila | `config.active_record.attributes_for_inspect = [ :id ]` | `config/environments/production.rb:80` |
| Ruido del health check | `config.silence_healthcheck_path = "/up"` | `config/environments/production.rb:44` |
| Assets | `config.assets.quiet = true` | `config/environments/development.rb:67` |
| Backtraces enormes en cada error | `backtrace: exception.backtrace&.first(15)` | `app/controllers/concerns/api/error_handling.rb:116-120` |

El filtro por `:email` es más agresivo de lo que parece: cualquier parámetro que
**contenga** "email" se reemplaza por `[FILTERED]`, incluido `email_address` del
login. Eso es correcto (un email es dato personal) pero te va a sorprender la
primera vez que quieras debuggear un login desde los logs.

Lo que el repo **no** hace y conviene saber: `filter_parameters` filtra
parámetros de la request, **no** lo que vos escribís a mano. Si hacés
`Rails.logger.info(user: user.attributes)`, ahí va el `password_digest`. El
filtro no te salva de vos mismo.

**El costo de loguear.** Una app de tráfico medio genera entre 5 y 20 líneas por
request. A 500 req/s son ~1 millón de líneas por minuto. Los colectores cobran
por GB ingerido: un log de debug dejado prendido "un ratito" en producción es una
factura sorpresa y, peor, latencia — escribir a STDOUT es una syscall bloqueante
y con el GVL bloquea al proceso entero, no sólo al thread.

### 1.6 lograge: la línea única

**No está instalado en este repo** (`bundle list | grep lograge` no devuelve
nada). Lo que hace: reemplaza las 4-6 líneas que Rails escribe por request
(`Started GET`, `Processing by`, `Rendered`, `Completed`) por **una sola**
estructurada.

Para qué sirve: el default de Rails es legible para un humano y horrible para
una máquina — hay que correlacionar líneas por su tag para reconstruir una
request. Lograge emite un evento por request, con `duration`, `db`, `view`,
`status`, `controller#action`.

Cuándo **no** usarlo: si ya escribís tu propio suscriptor de
`process_action.action_controller` (§2), lograge es redundante. Y su formato
`:json` no incluye por defecto los campos que agregó Rails 8.1
(`queries_count`, `cached_queries_count`), así que vas a terminar escribiendo un
`custom_options` igual. Mi recomendación para este repo: escribir el suscriptor
propio (son 15 líneas, ver §2.5) y ahorrarse la dependencia.

---

## 2. `ActiveSupport::Notifications`: el bus de eventos interno

### 2.1 Qué es y qué NO es

Es un **pub/sub in-process**. Rails instrumenta cada operación relevante
(queries, render, encolado de jobs, lecturas de cache) publicando un evento con
un nombre y un payload; cualquiera puede suscribirse. Los logs "bonitos" de
Rails no son `puts` desperdigados: son suscriptores
(`ActiveRecord::LogSubscriber`, `ActionController::LogSubscriber`) escuchando
este bus.

La comparación con Java, y dónde se rompe:

* Se parece a **Micrometer** en que es el punto de enganche universal para
  instrumentar. Se rompe en que Micrometer **es un registro de métricas**
  (counters, timers, histogramas, con dimensiones y exportadores). Notifications
  te da eventos crudos: agregar, calcular percentiles y exportar es 100% tuyo.
* Se parece a **Spring Actuator** en que es "de dónde sale la observabilidad del
  framework". Se rompe en que Actuator te da endpoints HTTP listos y
  Notifications no expone absolutamente nada por HTTP.
* Se parece a los **ApplicationEvent** de Spring en la forma (`publish` /
  `@EventListener`). Se rompe en que Notifications es **síncrono y en el mismo
  thread**: tu suscriptor corre dentro de la request, y si tarda, la request
  tarda. No hay `@Async` gratis.

### 2.2 La API, en tres formas

```ruby
# a) Suscriptor con objeto Event (LA forma que querés usar)
ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  event.name        # "sql.active_record"
  event.duration    # ms (float)
  event.payload     # hash
  event.allocations # objetos asignados durante el evento
  event.cpu_time    # ms de CPU
  event.idle_time   # ms esperando (IO). Definido como duration - cpu_time,
                    # o sea: duration == cpu_time + idle_time, exacto.
  event.gc_time     # ms de GC dentro del evento. NO es un tercer sumando:
                    # el GC ya está contado adentro de cpu_time.
end

# b) Suscriptor "crudo" (5 argumentos). Es lo que usa este repo en
#    config/initializers/rack_attack.rb:268 — funciona, pero te obliga a
#    calcular la duración a mano.
ActiveSupport::Notifications.subscribe(/rack_attack/) do |name, start, finish, id, payload|
end

# c) Publicar tu propio evento
ActiveSupport::Notifications.instrument("apply_movement.stock", kind: "receipt") do
  # ...
end
```

`event.idle_time` es la métrica que más se subestima: te separa "mi código es
lento" de "estoy esperando a Postgres". En Java lo sacarías de un
`Timer` + tracing; acá viene en el evento.

### 2.3 Los eventos que emite Rails, medidos en este repo

Suscribiéndome a `/.*/` y disparando **una** request autenticada a
`GET /api/v1/products?limit=5` más un `perform_later`:

```
sql.active_record                                    135
!connection.active_record                              6
instantiation.active_record                            5
cache_increment.active_support                         3
start_transaction.active_record                        3
transaction.active_record                              3
cache_write.active_support                             2
cache_read.active_support                              1
start_processing.action_controller                     1
process_action.action_controller                       1
request.action_dispatch                                1
enqueue.active_job                                     1
```

Dos detalles que valen la entrevista:

* **La convención del `!`.** Los eventos que empiezan con `!`
  (`!connection.active_record`, `!compile_template.action_view`) son internos y
  de alta frecuencia. Los suscriptores genéricos de Rails los **excluyen** a
  propósito: `ActionDispatch::ServerTiming` se suscribe con el patrón
  `/\A[^!]/`. Si vos te suscribís a `/.*/`, te los comés todos.
* **`rate_limit.action_controller` existe pero sólo se emite cuando el límite se
  supera.** Mirando el fuente de Rails 8.1
  (`actionpack/lib/action_controller/metal/rate_limiting.rb`), el `instrument`
  está **adentro** del `if count && count > to`. O sea: **no** sirve para medir
  "cuánto le falta a este cliente para chocar el límite"; sólo te avisa de los
  429. Para lo primero tenés que instrumentar vos.

Otros eventos que vas a ver y conviene conocer: `render_template.action_view`,
`render_partial.action_view`, `redirect_to.action_controller`,
`halted_callback.action_controller` (¡el que te dice que un `before_action` cortó
la request!), `perform.active_job`, `deliver.action_mailer`, y toda la familia
`*.solid_queue` que Solid Queue publica (`SolidQueue.instrument(canal)` emite
`"#{canal}.solid_queue"`): `claim`, `polling`, `dispatch_scheduled`, `retry`,
`discard`, `release_claimed`, `start_process`, `shutdown_process`,
`thread_error`. Es la base para monitorear la cola sin consultarle la base.

### 2.4 El payload real (no adivinado)

`process_action.action_controller`, capturado en una request real de este repo:

```
controller            "Api::V1::ProductsController"
action                "index"
format                :json
method                "GET"
path                  "/api/v1/products?limit=3"
status                200
view_runtime          0.267    # ms
db_runtime            33.374   # ms
queries_count         8
cached_queries_count  0
duration              145.7    # ms
allocations           72790
cpu_time              110.75   # ms
idle_time             34.95    # ms
```

`queries_count` y `cached_queries_count` son de Rails 8.1 y son **la métrica
anti-N+1 más barata que existe**: alertar cuando `queries_count > 30` en un
endpoint te encuentra los N+1 antes que cualquier herramienta.

`sql.active_record`:

```
sql                "SELECT \"products\".* FROM \"products\" WHERE ..."
name               "Product Load"
binds              []
type_casted_binds  []
async              false
allow_retry        true
connection         #<ActiveRecord::ConnectionAdapters::PostgreSQLAdapter …>
transaction        nil
affected_rows      3
row_count          3
```

⚠️ **`payload[:name]` puede ser `"SCHEMA"` o `"TRANSACTION"`.** Si contás
queries sin filtrar eso, tus números están inflados por los `BEGIN`/`COMMIT` y
por la introspección del schema.

### 2.5 Instrumentar tu propio código

El repo instrumenta cero código propio. Así se hace, con un objeto real de este
repo:

```ruby
# app/queries/stock_items/low_stock.rb — envolviendo el cuerpo de #call
def call
  ActiveSupport::Notifications.instrument("query.stock",
                                          query: "low_stock", warehouse_id: @warehouse_id) do |payload|
    relation = StockItem.where("quantity_available <= reorder_point")
    relation = relation.where(warehouse_id: @warehouse_id) if @warehouse_id
    relation = relation.where.not(reorder_point: 0) unless @include_zero_reorder
    relation = relation.where(product_id: Product.kept.active.select(:id)) if @only_active_products
    relation = relation.includes(:product, :warehouse)
                       .order(Arel.sql("(quantity_available - reorder_point) ASC"), :id)

    payload[:count] = relation.size   # el payload es mutable DENTRO del bloque
    relation
  end
end
```

Salida real, con un suscriptor que imprime `payload` y `duration`:

```
query.stock {:query=>"low_stock", :warehouse_id=>nil, :count=>13} 55.05ms
query.stock {:query=>"low_stock", :warehouse_id=>1, :count=>13}    1.93ms
```

⚠️ Dos trampas en esas cinco líneas, y las dos son clásicas:

* **La primera corrida no vale.** 55 ms contra 1,93 ms es el costo de arrancar
  (conexión, carga del schema, preparado del statement), no el de la query.
  Medir la primera iteración es la forma más común de mentirse solo.
* **`relation.size` sobre una relación no cargada dispara un `COUNT(*)`**, y la
  relación se materializa recién cuando el llamador la recorre, o sea **afuera**
  del bloque. `event.duration` acá mide el `COUNT`, no el fetch. Si querés medir
  el trabajo real, cerrá el bloque con `relation.to_a` y usá `.size` sobre el
  array ya cargado.

El `payload[:count] = …` adentro del bloque es el patrón importante: te permite
publicar datos que **sólo se conocen después** de ejecutar. En Java sería un
`Timer.Sample` que completás al final.

Y el suscriptor que convierte eso en una línea de log estructurada por request
(los 15 renglones que reemplazan a lograge):

```ruby
# config/initializers/request_logging.rb  (NO existe todavía)
ActiveSupport::Notifications.subscribe("process_action.action_controller") do |event|
  p = event.payload
  Rails.logger.info(
    event: "http.request",
    controller: p[:controller], action: p[:action],
    method: p[:method], path: p[:path].split("?").first,
    status: p[:status] || (p[:exception] && 500),
    duration_ms: event.duration.round(1),
    db_ms: p[:db_runtime]&.round(1),
    view_ms: p[:view_runtime]&.round(1),
    queries: p[:queries_count], cached_queries: p[:cached_queries_count],
    allocations: event.allocations,
    request_id: p[:request]&.request_id,
    user_id: Current.user&.id
  )
end
```

Ojo con `p[:path]`: incluye el query string, o sea datos del usuario. Cortarlo
en el `?` evita filtrar parámetros al log y baja la cardinalidad.

### 2.6 El costo de instrumentar (medido)

`ActiveSupport::Notifications.instrument` sobre un bloque trivial, 300.000
iteraciones, mejor de 3 corridas, Ruby 3.3.6:

| Escenario | Costo por llamada |
|---|---|
| Sin `instrument` (baseline) | **64 ns** |
| `instrument` sin ningún suscriptor | **502 ns** |
| `instrument` + 1 suscriptor de **5 argumentos** | **4433 ns** (4,4 µs) |
| `instrument` + 1 suscriptor de **1 argumento** (`Event`) | **7603 ns** (7,6 µs) |
| `instrument` + el catch-all de `ServerTiming` | **7703 ns** (7,7 µs) |

Cuatro conclusiones:

1. **Instrumentar sin suscriptores es casi gratis** (~0,5 µs). Podés dejar
   `instrument` en el código sin miedo; lo que cuesta es *escuchar*.
2. **La aridad del bloque decide el precio.** Con 5 argumentos
   (`|name, start, finish, id, payload|`) Rails usa un suscriptor `Timed`, que
   sólo anota dos timestamps. Con 1 argumento construye un
   `Notifications::Event` completo — y ese objeto mide CPU, allocations y GC en
   cada evento: **1,7 veces más caro**. La API linda no es la barata.
3. **Cada suscriptor multiplica el costo.** Un suscriptor que hace I/O (escribe
   a un socket, a un archivo) dentro del evento te mete esa latencia **en la
   request**. Si tenés que mandar métricas por red, encolá en un buffer y flusheá
   aparte.
4. **En desarrollo tus mediciones están sesgadas.** `config.server_timing = true`
   (`config/environments/development.rb:16`) instala un suscriptor con el patrón
   `/\A[^!]/` — o sea, **a todos los eventos** — que crea un objeto `Event` por
   cada uno. Eso multiplica por ~15 el costo de instrumentar respecto de "sin
   suscriptores", y no hace falta levantar el servidor para pagarlo: en un
   `bin/rails runner` pelado ese suscriptor **ya está enganchado**, porque el
   middleware se registra al construirse el stack. Se ve así:

   ```ruby
   ActiveSupport::Notifications.notifier.listening?("cualquier.cosa")  # => true
   ActionDispatch::ServerTiming.unsubscribe                            # sacarlo antes de medir
   ```

   Ese header tan útil…

   ```
   server-timing: cache_read.active_support;dur=0.05, cache_increment.active_support;dur=65.03,
                  sql.active_record;dur=40.71, instantiation.active_record;dur=57.16,
                  process_action.action_controller;dur=259.61
   ```

   …no es gratis. En producción `server_timing` está apagado, y está bien así.

   (De paso, ese `cache_increment.active_support;dur=65.03` es el `rate_limit`
   del `BaseController` pegándole a **Solid Cache sobre Postgres**. 65 ms de los
   259 ms de la request se fueron en contar. Es exactamente lo que advierte el
   comentario de `app/controllers/api/v1/base_controller.rb:38`: para contadores
   de alta frecuencia, Redis.)

---

## 3. Qué métricas importan

### 3.1 El promedio miente, y miente siempre para el mismo lado

100 requests: 99 tardan 10 ms y una tarda 5 segundos.

* Promedio: **59,9 ms**. Suena bien.
* p50: **10 ms**. p95: **10 ms**. El 1% peor: **5.000 ms**.

El promedio es sensible a los outliers pero los **diluye**: nunca te dice cuánta
gente sufrió. Y como la latencia no tiene distribución normal (tiene cola larga
por GC, locks, checkpoints, cache misses), la media no describe nada.

Tres reglas:

* **Alertá sobre p95/p99, no sobre el promedio.**
* **Los percentiles no se promedian.** El p99 de 10 servidores **no** es el
  promedio de sus p99. Si tu sistema de métricas hace eso, te está mintiendo.
  Necesitás histogramas agregables (Prometheus `histogram_quantile`, HDRHistogram).
* **Un usuario ve muchas requests.** Si una página hace 20 llamadas y cada una
  tiene p99 = 1 s, la probabilidad de que el usuario **no** vea ninguna lenta es
  0.99²⁰ ≈ 82%: uno de cada cinco usuarios pega una request lenta. Por eso a
  escala se mira p99 y p99.9, no p95.

### 3.2 Los tres marcos, y cuál usar

| Marco | Para qué | Señales |
|---|---|---|
| **Four Golden Signals** (Google SRE) | Servicios de request/response | Latencia, tráfico, errores, saturación |
| **RED** | Lo mismo, orientado a dashboards | Rate, Errors, Duration |
| **USE** (Brendan Gregg) | **Recursos**, no servicios | Utilization, Saturation, Errors |

No compiten: **RED para servicios, USE para recursos**. Un dashboard sano tiene
RED de cada endpoint arriba y USE de CPU, memoria, pool de conexiones y colas
abajo. La saturación es la que casi todos se olvidan y es la que **predice** el
incidente: la latencia sube cuando la saturación ya lleva un rato alta.

Detalle que se pregunta: **latencia de errores y latencia de éxitos van
separadas**. Un 500 que responde en 3 ms te baja el p99 artificialmente y te
oculta que el servicio se está cayendo.

### 3.3 Las métricas concretas de ESTE repo

| Métrica | De dónde sale | Umbral razonable |
|---|---|---|
| p95/p99 por `controller#action` | `process_action.action_controller` → `event.duration` | depende del endpoint; alertá sobre desvío, no sobre absoluto |
| `db_runtime` / `duration` | mismo evento | > 60% = el problema es la base |
| `queries_count` por acción | mismo evento (Rails 8.1) | > 30 en un `index` ⇒ N+1 |
| Tasa de 5xx | mismo evento, `payload[:status]` | > 0.1% sostenido |
| Tasa de 429 | `throttle.rack_attack` (suscrito en `config/initializers/rack_attack.rb:268`) + `rate_limit.action_controller` | un pico ⇒ o hay ataque, o le rompiste la integración a un cliente |
| Pool de conexiones | `ActiveRecord::Base.connection_pool.stat` | `waiting > 0` sostenido = saturación |
| Profundidad de cola | `solid_queue_ready_executions` | crecimiento monótono = los workers no dan abasto |
| **Latencia** de cola | `now() - min(created_at)` de los ready | \> `polling_interval × 10` |
| Lag del outbox | `min(occurred_at)` de `published_at IS NULL` | > 300 s (el propio `rake stock:outbox` lo marca) |
| Heartbeat de workers | `solid_queue_processes.last_heartbeat_at` | > 5 min ⇒ worker muerto (ver abajo) |
| Drift del ledger | `Stock::ReconcileBalancesJob` → log `status: "DRIFT_DETECTED"` | **cualquier valor > 0 es un bug** |
| Cache hit ratio de Postgres | `pg_statio_user_tables` | < 95% ⇒ falta RAM o falta índice |

**Profundidad *y* latencia de cola, no una sola.** Una cola con 10.000 jobs que
se drena en 3 segundos está sana. Una cola con 3 jobs cuyo más viejo espera hace
20 minutos está rota (worker colgado, o un job envenenado). La profundidad mide
el backlog; la latencia mide si te están atendiendo.

```sql
-- Profundidad y espera máxima por cola (base stock_development_queue).
-- Salida real de este repo con las colas vacías:
--   development_maintenance | 0 | 0 | 0 | 0 |
--   development_outbox      | 0 | 0 | 0 | 0 |
SELECT j.queue_name,
       count(*) FILTER (WHERE r.id IS NOT NULL) AS listos,
       count(*) FILTER (WHERE c.id IS NOT NULL) AS en_curso,
       count(*) FILTER (WHERE s.id IS NOT NULL) AS programados,
       count(*) FILTER (WHERE f.id IS NOT NULL) AS fallados,
       round(EXTRACT(epoch FROM now() - min(r.created_at)))::int AS espera_max_s
FROM solid_queue_jobs j
LEFT JOIN solid_queue_ready_executions r     ON r.job_id = j.id
LEFT JOIN solid_queue_claimed_executions c   ON c.job_id = j.id
LEFT JOIN solid_queue_scheduled_executions s ON s.job_id = j.id
LEFT JOIN solid_queue_failed_executions f    ON f.job_id = j.id
GROUP BY j.queue_name ORDER BY 2 DESC;
```

Ojo con el prefijo: `config/initializers/active_job.rb` pone
`queue_name_prefix` en no-producción, por eso las colas se llaman
`development_outbox` y no `outbox`. Si tu alerta filtra por nombre exacto, en
staging no dispara nunca.

```sql
-- Workers vivos (base stock_development_queue). Salida real de este repo:
--  dispatcher-e747d24d…       | Dispatcher       | vm | 13662 | 00:00:59.19
--  scheduler-99e3de0f…        | Scheduler        | vm | 13678 | 00:00:58.77
--  supervisor(fork)-c05410e1… | Supervisor(fork) | vm | 13650 | 00:00:59.58
--  worker-d6f49733…           | Worker           | vm | 13669 | 00:00:58.99
--  worker-074a4979…           | Worker           | vm | 13674 | 00:00:58.96
--  worker-c0954d7a…           | Worker           | vm | 13666 | 00:00:58.94
SELECT name, kind, hostname, pid, now() - last_heartbeat_at AS antiguedad
FROM solid_queue_processes ORDER BY kind;
```

Seis filas y no dos: `config/queue.yml` declara tres grupos de workers
(`critical`, `outbox`, y `default,mailers,maintenance,*`), y el supervisor
forkea además un dispatcher y un scheduler.

⚠️ **No alertes con `antiguedad > 60 s`.** Solid Queue late cada
`SolidQueue.process_heartbeat_interval`, que **por defecto es 60 segundos**: un
worker perfectamente sano pasa la mayor parte del tiempo con un heartbeat de
entre 0 y 59 s, como se ve arriba. El umbral que usa la propia gema para dar un
proceso por muerto es `SolidQueue.process_alive_threshold`, **5 minutos**.
Alertá con ese, no con el intervalo del latido: es el error de configuración de
alertas más fácil de cometer y te llena la guardia de falsos positivos.

```ruby
# Pool de conexiones. Salida real en este repo (runner, sin carga):
# {:size=>5, :connections=>0, :busy=>0, :dead=>0, :idle=>0, :waiting=>0, :checkout_timeout=>5.0}
ActiveRecord::Base.connection_pool.stat
```

`waiting` es **la** métrica de saturación del pool. Si es > 0 de forma
sostenida, tus threads están haciendo cola por una conexión y el
`checkout_timeout: 5` de `config/database.yml:44` te va a empezar a tirar
`ActiveRecord::ConnectionTimeoutError`. La cuenta que hay que tener en la cabeza:

```
conexiones totales = WEB_CONCURRENCY × RAILS_MAX_THREADS × cantidad_de_bases
```

Este repo tiene **4 bases** (primary, cache, queue, cable). Con 3 workers × 5
threads son **60 conexiones por máquina**, contra un `max_connections` de
Postgres que acá vale 100 (verificado con `SHOW max_connections`). Dos máquinas
y ya estás afuera. Es el error de escalado número uno y está documentado en el
propio `config/database.yml`.

---

## 4. APM: qué hace y qué mirar primero

Un APM (New Relic, Datadog, Scout, AppSignal, Skylight) hace tres cosas:

1. **Instrumenta automáticamente** enganchándose a `ActiveSupport::Notifications`
   — exactamente el bus de §2. No hay magia: es un suscriptor grande.
2. **Muestrea trazas** (una request completa con su árbol de spans).
3. **Agrega** por endpoint y calcula percentiles.

**No hay ningún APM configurado en este repo.** El `Gemfile` no tiene ninguna de
esas gemas.

Qué mirar, y en este orden:

1. **Throughput × latencia media = tiempo total consumido.** Ordená los endpoints
   por *tiempo total*, no por latencia. Un endpoint de 3 s que se llama 5 veces
   por hora no te importa; uno de 80 ms llamado 500 veces por segundo sí.
2. **El desglose de la traza**: ¿DB, view, HTTP externo, o Ruby? Si es "Ruby",
   ahí recién sacás el profiler (§5).
3. **Las trazas del p99**, no las del promedio. Casi siempre son otra cosa: un
   cache miss, un lock, un GC mayor.
4. **Errores por tipo**, agrupados por fingerprint, no por mensaje.

Alternativas open source, sin vendor:

* **OpenTelemetry** (`opentelemetry-instrumentation-rails`): estándar de la CNCF,
  exporta a Jaeger/Tempo/Grafana. Es lo más parecido a lo que ya conocés de Java
  (Spring tiene el mismo agente). Lo que se rompe: en Java el agente se enchufa
  con `-javaagent` sin tocar el código; en Ruby es una gema que se carga en el
  boot.
* **Prometheus + `yabeda-rails`** para métricas RED, y `pgwatch`/`postgres_exporter`
  para USE de la base.
* **Sentry / GlitchTip** para errores (GlitchTip es el self-hosted compatible).
* Lo más barato de todo: el **suscriptor de §2.5** escupiendo JSON a stdout, y
  Loki/Grafana agregando. Sin trazas distribuidas, pero cubre el 80% por
  ~0 pesos.

---

## 5. Profiling en Ruby

### 5.1 Qué hay instalado (y qué no)

```bash
$ gem list | grep -E "rack-mini|stackprof|memory_profiler|derailed|benchmark"
benchmark (default: 0.3.0)
memory_profiler (1.1.0)
rack-mini-profiler (5.0.0)
stackprof (0.2.28)
```

Las tres primeras están en el grupo `:development` del `Gemfile` con
`require: false`. **`derailed_benchmarks` y `benchmark-ips` NO están
instaladas**; `benchmark` (stdlib) sí.

### 5.2 `rack-mini-profiler`: el badge

Es un middleware que pone un badge flotante en cada página con el desglose
SQL/render de esa request, con `?pp=` para modos extra (`?pp=help`,
`?pp=flamegraph`, `?pp=analyze-memory`).

**En este repo está declarado con `require: false`, así que NO está montado.**
Verificado:

```bash
$ bin/rails middleware | grep -i mini    # sin resultados
```

Para activarlo hay que requerirlo explícitamente en un initializer de
desarrollo (`require "rack-mini-profiler"`), porque su railtie es el que inserta
el middleware. Cargarlo con `RUBYOPT=-rrack-mini-profiler` **no alcanza**: se
carga antes de que exista `Rails`, el railtie no se registra y el middleware
nunca entra al stack (lo probé; el header `X-MiniProfiler-Ids` no aparece).

Dónde brilla: en la UI Hotwire, para ver de un vistazo cuántas queries dispara
una vista parcial. Dónde no sirve: en la API JSON, porque el badge se inyecta en
el HTML.

### 5.3 `stackprof`: sampling profiler

Es lo más parecido a async-profiler que hay en Ruby: interrumpe el proceso cada
N µs y anota el stack. Tres modos, y elegir mal es el error clásico:

| Modo | Reloj | Para qué | Trampa |
|---|---|---|---|
| `:cpu` | CPU time del proceso | Código Ruby que quema procesador | **No ve el I/O.** Una query de 2 s aparece como 0 muestras. |
| `:wall` | Reloj de pared | Latencia real, incluida la espera | El I/O aparece como "tiempo en `IO#wait`", que es correcto pero no es tu bug. |
| `:object` | Cada N asignaciones | Presión de GC, churn de objetos | No mide tiempo. Sirve para "por qué el GC corre tanto". |

Regla: **empezá siempre con `:wall`.** Te dice dónde se va el tiempo del
usuario. Si el top es I/O, el problema es la base y stackprof ya cumplió. Si el
top es tu código, cambiá a `:cpu` para afinar.

Corrida real sobre `StockMovements::Ledger` (200 iteraciones, `interval: 1000` µs):

```ruby
require "stackprof"
StockMovements::Ledger.new(limit: 50).call.to_a          # warmup: sacá el boot del perfil
StackProf.run(mode: :wall, out: "tmp/ledger.dump", interval: 1000, raw: true) do
  200.times { StockMovements::Ledger.new(limit: 50).call.to_a }
end
```

```
$ bundle exec stackprof tmp/ledger.dump --limit 12
  Mode: wall(1000)
  Samples: 1397 (0.00% miss rate)
  GC: 192 (13.74%)
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
       182  (13.0%)         182  (13.0%)     String#sub
       104   (7.4%)         104   (7.4%)     (sweeping)
        86   (6.2%)          86   (6.2%)     (marking)
        63   (4.5%)          63   (4.5%)     Thread::Backtrace::Location#to_s
        51   (3.7%)          51   (3.7%)     Regexp#match?
       391  (28.0%)          41   (2.9%)     ActiveSupport::BacktraceCleaner#clean_frame
       456  (32.6%)          29   (2.1%)     Thread.each_caller_location
        36   (2.6%)          27   (1.9%)     ActiveRecord::…::Preloader::Association#load_records
       148  (10.6%)          25   (1.8%)     Class#new
        72   (5.2%)          23   (1.6%)     Enumerable#group_by
      1120  (80.2%)          21   (1.5%)     Array#each
```

**Leelo así**: `SAMPLES` (o *self*) es el tiempo gastado **en esa función**;
`TOTAL` incluye a sus llamadas. Un frame con `TOTAL` alto y `SAMPLES` bajo es un
*orquestador* (`Array#each`, 80,2% total / 1,5% self): no es el culpable, es el
camino. El culpable es el que tiene **self alto**.

Y acá aparece el hallazgo: **el 32,6% del tiempo se lo lleva
`Thread.each_caller_location`, y adentro `BacktraceCleaner#clean_frame`** (que
es de donde salen el `String#sub` de 13% y el `Regexp#match?` de 3,7%). Nada de
eso es código del dominio: es
`config.active_record.verbose_query_logs = true`
(`config/environments/development.rb:55`) calculando, **para cada query**, la
línea de tu código que la disparó — lo que imprime las flechitas `↳` en el log.

Corriendo exactamente lo mismo con eso apagado
(`ActiveRecord.verbose_query_logs = false`, volcado a
`tmp/ledger_sin_verbose.dump`):

```
  Samples: 788 (0.00% miss rate)     # antes: 1397
  GC: 100 (12.69%)
        73   (9.3%)          73   (9.3%)     (marking)
        27   (3.4%)          27   (3.4%)     (sweeping)
       140  (17.8%)          23   (2.9%)     Class#new
        24   (3.0%)          17   (2.2%)     ActiveModel::LazyAttributeSet#fetch_value
        21   (2.7%)          15   (1.9%)     ActiveRecord::…::Preloader::Association#load_records
        17   (2.2%)          14   (1.8%)     ActiveRecord::…::Preloader::Association#loaded?
```

**El 44% del tiempo medido era instrumentación de desarrollo.** Moraleja: *no
profiles en el entorno de desarrollo con la configuración de desarrollo*. Andá a
`RAILS_ENV=production` (o apagá `verbose_query_logs`, `server_timing` y el
logger) antes de sacar conclusiones. Es el equivalente exacto a medir la JVM con
`-Xint` puesto.

**Zoom a un método** (real):

```
$ bundle exec stackprof tmp/ledger_sin_verbose.dump \
    --method 'ActiveRecord::Associations::Preloader::Branch#grouped_records'
  samples:    12 self (1.5%)  /     77 total (9.8%)
  callers:
      77  ( 100.0%)  ActiveRecord::Associations::Preloader::Branch#loaders
  code:
                                  |    80  |  def grouped_records
                                  |    82  |    polymorphic_parent = !root? && parent.polymorphic?
   77    (9.8%)                   |    83  |    source_records.each do |record|
    6    (0.8%) /     2   (0.3%)  |    84  |      reflection = record.class._reflect_on_association(association)
   58    (7.4%) /     2   (0.3%)  |    85  |      next if polymorphic_parent && !reflection || !record.association(association).klass
   10    (1.3%) /     7   (0.9%)  |    86  |      (h[reflection] ||= []) << record
```

Las dos columnas de cada línea son `total / self`: la línea 85 se lleva 7,4% del
perfil pero sólo 0,3% es la línea misma — el resto está adentro de
`record.association(...)`.

Te anota **línea por línea**. Esto es lo que en Java te da async-profiler con
`--lines`.

**Flamegraph**:

```bash
bundle exec stackprof tmp/ledger.dump --d3-flamegraph > tmp/flame.html   # genera un HTML autónomo
```

Cómo se lee, porque casi todo el mundo lo lee mal:

* **Eje X = porcentaje de muestras, NO tiempo.** Está ordenado
  alfabéticamente/por timeline, no por costo. Que una caja esté a la izquierda no
  significa que pasó primero ni que es peor.
* **Eje Y = profundidad del stack.** Abajo el `main`, arriba las hojas.
* **El ancho es todo lo que importa.** Buscá **mesetas anchas arriba**: una hoja
  ancha es tiempo real quemado ahí.
* Una torre alta y finita es recursión o middleware anidado: ruido.
* Un `(marking)` / `(sweeping)` ancho = tu problema es el GC, o sea **asignás
  demasiado**, y el que tenés que sacar es `memory_profiler` o `mode: :object`.

### 5.4 `memory_profiler`: quién asigna y quién retiene

Sampling no; **traza cada asignación**. Es lento (10-50x), así que se usa sobre
un bloque acotado, nunca en producción.

Corrida real, 10 iteraciones del ledger:

```ruby
require "memory_profiler"
report = MemoryProfiler.report { 10.times { StockMovements::Ledger.new(limit: 50).call.to_a } }
report.pretty_print(to_file: "tmp/mem.txt", scale_bytes: true)
```

```
Total allocated: 1.75 MB (15310 objects)
Total retained:  97.04 kB (574 objects)
```

**La distinción clave**: *allocated* es churn (presión de GC, latencia);
*retained* es lo que **sigue vivo** al terminar el bloque. Un `retained` que
crece corrida tras corrida es un **memory leak**; un `allocated` alto con
`retained` bajo es un problema de rendimiento, no de fuga. En Java es la misma
distinción entre allocation rate y live set, pero acá la tenés en una línea.

### 5.5 `derailed_benchmarks` y `benchmark-ips` (no instaladas)

* **`derailed_benchmarks`**: mide **memoria de boot por gema**
  (`bundle exec derailed bundle:mem`) y corre la app contra un endpoint buscando
  fugas (`derailed exec perf:mem_over_time`). Es la herramienta para responder
  "¿por qué mi proceso arranca en 300 MB?" — te lo desglosa gema por gema. Con
  este `Gemfile` (que trae Sidekiq **y** Solid Queue a propósito para poder
  comparar) sería la forma correcta de medir cuánto cuesta esa comodidad.
* **`benchmark-ips`**: itera hasta estabilizar y reporta **iteraciones por
  segundo con desvío**, más comparación estadística entre candidatos. Es lo que
  hay que usar para micro-benchmarks; `Benchmark.realtime` de la stdlib (lo que
  usé en este documento) no hace warmup ni te dice si la diferencia es
  significativa. Si vas a comparar dos implementaciones, `benchmark-ips`; si vas
  a medir "cuánto tarda esto una vez", `Benchmark.realtime` alcanza.

---

## 6. Memoria en Ruby: por qué tu proceso engorda y no adelgaza

### 6.1 El modelo

Ruby maneja objetos en **slots** agrupados en **páginas**
(`heap_allocated_pages`). Desde Ruby 3.2 los slots ya **no** son todos del mismo
tamaño: hay varios *size pools*, y un objeto cae en el que le entra. Medido acá:

```bash
$ bin/rails runner 'pp GC.stat_heap.transform_values { |h| h[:slot_size] }'
{0=>40, 1=>80, 2=>160, 3=>320, 4=>640}
```

Cinco pools, de 40 a 640 bytes (*Variable Width Allocation*). Importa porque un
`String` de 100 bytes ya no necesita un objeto extra en malloc: entra embebido
en el slot de 160. El GC es **generacional** (dos generaciones: joven y vieja) e
**incremental**, con *write barriers*. Un GC **menor** sólo recorre objetos
jóvenes; uno **mayor** recorre todo.

`GC.stat` en este repo, recién booteado:

```
RSS: 94 MB
count                        35        # GCs totales
minor_gc_count               27
major_gc_count                8
heap_allocated_pages        272
heap_live_slots          264287
heap_free_slots           25055
total_allocated_objects  660294
```

Diferencias con la JVM que un javero asume mal:

* **No hay `-Xmx`.** El heap crece según haga falta y **el proceso muere por OOM
  del kernel**, no con un `OutOfMemoryError` que podés capturar y loguear. Se
  ajusta con `RUBY_GC_HEAP_GROWTH_FACTOR`, `RUBY_GC_HEAP_INIT_SLOTS`, etc., pero
  son heurísticas, no un techo.
* **No hay compactación por defecto.** `GC.compact` existe (y
  `GC.auto_compact = true`), pero no se usa mucho: mueve objetos y eso invalida
  punteros en extensiones C mal escritas.
* **El GC de Ruby no devuelve memoria al SO.** Y esto es *el* punto.

### 6.2 El experimento que explica el "bloat de Puma"

Medido en este repo:

```ruby
snap("boot")                                # RSS=  94.3 MB  slots=263.394  paginas= 273
big = 300_000.times.map { "x" * 200 }
snap("300k strings de 200B")                # RSS= 193.9 MB  slots=630.460  paginas=1773
big = nil
4.times { GC.start(full_mark: true, immediate_sweep: true) }
snap("tras GC.start x4")                    # RSS= 190.1 MB  slots=246.752  paginas=1749
GC.compact
snap("tras GC.compact")                     # RSS= 190.2 MB  slots=246.777  paginas=1749
```

Liberé **todos** los objetos (los slots vivos volvieron a 246k, quedaron 359.933
slots libres) y **el RSS bajó 3,8 MB de 100**. Las páginas del heap siguen
reservadas: Ruby las guarda para la próxima vez.

Esa es la explicación completa del "mi worker de Puma arranca en 200 MB y a las
6 horas está en 900 MB". No es (casi nunca) un leak: es que **una sola request
patológica** —un endpoint que carga 50.000 filas, un CSV grande, un JSON
gigante— infla el heap, y el heap **no se desinfla**. El worker queda para
siempre del tamaño de su peor momento.

Qué hacer:

1. **Arreglar la request patológica.** `find_each`, `pluck`, paginación keyset
   (este repo ya usa keyset en `app/queries/stock_movements/ledger.rb`). Ver
   docs/04.
2. **Reciclar workers**: `puma_worker_killer`, o el `--max-requests` de otros
   servidores. Es un parche, no una cura, pero es un parche legítimo.
3. **jemalloc.**

### 6.3 jemalloc y `MALLOC_ARENA_MAX`

Además del heap de Ruby está el `malloc` del sistema, que sirve las asignaciones
grandes (strings largas, buffers). El `malloc` de glibc crea **arenas** por
thread (hasta `8 × núcleos`) para reducir contención, y cada arena se fragmenta
por su cuenta. Con Puma multi-thread eso se traduce en decenas de MB de
fragmentación por proceso.

Dos soluciones, y este repo eligió la buena. `Dockerfile`:

```dockerfile
# Dockerfile:19-28 (recortado)
RUN apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so
ENV LD_PRELOAD="/usr/local/lib/libjemalloc.so"
```

`LD_PRELOAD` reemplaza el `malloc` de glibc por jemalloc **sin recompilar Ruby**.
jemalloc fragmenta mucho menos y **sí devuelve páginas al SO**. Reducciones
típicas de RSS: 20-40%.

La alternativa pobre, si no podés instalar jemalloc:

```bash
MALLOC_ARENA_MAX=2
```

Limita las arenas de glibc a 2. Menos fragmentación, a cambio de algo de
contención entre threads. Es la solución de una línea; jemalloc es la buena.

Verificado en este entorno: **ninguna de las dos está activa en desarrollo**
(`ENV["MALLOC_ARENA_MAX"]` es `nil`, y `LD_PRELOAD` sólo se setea en la imagen
Docker).

### 6.4 Copy-on-write, `preload_app!` y por qué RSS te miente

Cuando un proceso hace `fork`, el hijo **comparte** las páginas del padre hasta
que escribe en ellas. `preload_app!` en Puma hace que la app se cargue **antes**
del fork, así todo el código y las constantes quedan compartidos.

⚠️ **`config/puma.rb` de este repo NO tiene `preload_app!`.** Con
`WEB_CONCURRENCY > 1` cada worker carga la app entera por su cuenta: sin
copy-on-write, la RAM crece linealmente con los workers. Es **la** línea que hay
que agregar antes de escalar:

```ruby
# config/puma.rb — lo que HABRÍA que agregar para multi-worker
preload_app!
```

Y nada más. La receta que vas a encontrar copiada en todos lados —

```ruby
before_fork { ActiveRecord::Base.connection_pool.disconnect! }   # ❌ innecesario
on_worker_boot { ActiveRecord::Base.establish_connection }       # ❌ y además roto
```

— es de la era de Rails 4. Desde Rails 6 Active Record se engancha al
`ForkTracker` de Active Support y descarta los pools heredados solo:

```ruby
# activerecord/lib/active_record/connection_adapters/pool_config.rb:83
ActiveSupport::ForkTracker.after_fork { ActiveRecord::ConnectionAdapters::PoolConfig.discard_pools! }
```

El hijo reconecta perezosamente en su primer checkout. Y en este repo el
`establish_connection` sería peor que inútil: sólo tocaría la base **primary**,
dejando `cache`, `queue` y `cable` sin atender. Lo que sí va en `on_worker_boot`
es todo lo que **no** es Active Record y no tiene su propio `ForkTracker`:
clientes de Redis, sockets abiertos a mano, threads propios.

Y acá viene lo que casi todo el mundo mide mal: **RSS cuenta las páginas
compartidas en cada proceso**. Medido en los 6 procesos de Solid Queue que corren
en este repo (que Solid Queue forkea de un supervisor):

```
PID     RSS       PSS       compartida   privada
13650   113 MB     81 MB      40 MB       73 MB   (supervisor)
13662    99 MB     70 MB      34 MB       65 MB   (dispatcher)
13666    99 MB     69 MB      35 MB       63 MB   (worker critical)
13669    97 MB     68 MB      35 MB       62 MB   (worker outbox)
13674   149 MB    126 MB      28 MB      121 MB   (worker default)
13678   108 MB     79 MB      36 MB       72 MB   (scheduler)
-------------------------------------------------
suma    665 MB    493 MB
```

**Suma de RSS: 665 MB. Suma de PSS: 493 MB.** 172 MB son páginas compartidas
contadas seis veces. Si dimensionás el contenedor con la suma de RSS, pedís 35%
más RAM de la que hace falta. **Para dimensionar usá PSS**
(`/proc/PID/smaps_rollup`), o mejor `memory.current` del cgroup, que es lo que
mira el OOM killer.

Ojo con la lectura fácil: acá el ahorro **no** viene de `preload_app!` (Puma no
lo tiene, §6.4), viene de que el supervisor de Solid Queue sí forkea. Fijate
que el worker `default` —el que efectivamente corrió jobs— tiene 121 MB privados
contra 62-73 MB de los demás: **lo compartido se va desgastando a medida que el
proceso trabaja y escribe en sus páginas**. El copy-on-write se paga de a poco.

### 6.5 Dimensionar workers vs threads con memoria real

La fórmula:

```
RAM = (RSS_primer_worker) + (workers - 1) × RSS_privada_por_worker + margen
```

Con los números de este repo (~100-150 MB por proceso, ~65-120 MB privados) y un
contenedor de 1 GB:

```
1 worker  :  ~150 MB   -> desperdiciás 850 MB
4 workers : 150 + 3×120 = 510 MB  -> entra cómodo
6 workers : 150 + 5×120 = 750 MB  -> entra, pero sin margen para un pico
```

Y ahora las restricciones que **no** son de memoria:

* **CPU**: por el GVL, un proceso Ruby usa **como máximo un núcleo** para
  ejecutar Ruby. `workers ≈ núcleos` (o `núcleos × 1.5` si la app espera mucho
  I/O). Poner 8 workers en 2 núcleos sólo agrega cambios de contexto.
* **Threads**: `RAILS_MAX_THREADS` (default 3 en `config/puma.rb`, 5 en
  `.env.example`). Más threads suben throughput **sólo mientras haya espera de
  I/O**; el GVL se libera durante las llamadas al driver de Postgres. Pasados
  ~5, la latencia empeora porque los threads se pelean por el GVL.
* **Conexiones**: `workers × threads × 4 bases` contra `max_connections = 100`.
  **En este repo esta suele ser la restricción que ata primero**, antes que la
  RAM y antes que la CPU.

Respuesta corta para la entrevista: *"Empiezo con workers = núcleos y threads =
5, mido RSS privado por worker y `pool.stat[:waiting]`, y ajusto. En Rails, con
4 bases, lo que se satura primero casi siempre es el pool de conexiones, no la
CPU ni la RAM."*

---

## 7. PostgreSQL: las queries que tenés que tener a mano

docs/04 §13 cubre `pg_stat_statements` y `auto_explain` para encontrar **la query
lenta**. Acá van las de **operación**: saturación, locks, vacuum y checkpoints.
Todas corridas contra `stock_development` de este repo.

### 7.1 Lo primero: `pg_stat_statements`

```sql
CREATE EXTENSION pg_stat_statements;  -- necesita shared_preload_libraries + reinicio

SELECT calls,
       round(total_exec_time::numeric, 1)                          AS total_ms,
       round(mean_exec_time::numeric, 2)                           AS media_ms,
       round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 1) AS pct,
       rows, query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

**En este entorno no se puede activar.** Verificado: la extensión está
*disponible* pero `shared_preload_libraries` está vacío, así que `CREATE
EXTENSION` funciona y después toda consulta a la vista falla con
`ERROR: pg_stat_statements must be loaded via shared_preload_libraries`. Cargarla
requiere reiniciar Postgres (en RDS/Cloud SQL, un parameter group). **Es lo
primero que hay que pedirle a infra en un proyecto nuevo.**

Ordená por `total_exec_time`, no por `mean_exec_time`. Una query de 5 ms
ejecutada 200.000 veces por hora pesa más que una de 3 s ejecutada tres veces, y
la primera es la que te está comiendo el servidor.

### 7.2 Qué está corriendo AHORA

```sql
SELECT pid, usename, application_name, state,
       now() - query_start        AS duracion,
       now() - xact_start         AS duracion_tx,
       wait_event_type, wait_event,
       left(query, 120)           AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY duracion DESC NULLS LAST;
```

Gracias a los **query log tags** (§1.4), en la columna `query` vas a ver
`/*action='index',application='Stock',controller='products'*/` y sabés de dónde
salió sin adivinar.

`state = 'idle in transaction'` con `duracion_tx` alto es **la** señal de
alarma: alguien abrió una transacción y se fue. Bloquea el vacuum, retiene
snapshots y acumula locks. Este repo se defiende con
`idle_in_transaction_session_timeout: 30000` en `config/database.yml:55`.

### 7.3 Quién bloquea a quién

Esta es la query que salva una guardia. `pg_blocking_pids()` (Postgres 9.6+) hace
todo el trabajo sucio de recorrer `pg_locks`:

```sql
SELECT bloqueada.pid                    AS pid_bloqueado,
       bloqueada.wait_event_type, bloqueada.wait_event,
       now() - bloqueada.query_start    AS esperando_hace,
       left(bloqueada.query, 60)        AS query_bloqueada,
       bloqueante.pid                   AS pid_bloqueante,
       bloqueante.state                 AS estado_bloqueante,
       left(bloqueante.query, 60)       AS query_bloqueante
FROM pg_stat_activity bloqueada
JOIN LATERAL unnest(pg_blocking_pids(bloqueada.pid)) AS bpid ON true
JOIN pg_stat_activity bloqueante ON bloqueante.pid = bpid
WHERE cardinality(pg_blocking_pids(bloqueada.pid)) > 0;
```

Salida real, provocando el bloqueo a mano con dos sesiones de `psql` haciendo
`SELECT … FROM stock_items WHERE id = 1 FOR UPDATE` (que es exactamente lo que
hace `app/services/stock/apply_movement.rb` en `lock_stock_item!`):

```
pid_bloqueado     | 25026
wait_event_type   | Lock
wait_event        | transactionid
esperando_hace    | 00:00:03.001413
query_bloqueada   | BEGIN; SELECT * FROM stock_items WHERE id = 1 FOR UPDATE; CO
pid_bloqueante    | 25021
estado_bloqueante | active
query_bloqueante  | BEGIN; SELECT * FROM stock_items WHERE id = 1 FOR UPDATE; SE
```

`wait_event_type = 'Lock'` con `wait_event = 'transactionid'` significa
literalmente "espero a que esa transacción termine". Para matar al bloqueante:
`SELECT pg_cancel_backend(25021)` (cancela la query) o
`pg_terminate_backend(25021)` (mata la conexión). Probá siempre `cancel` primero.

Este repo acota el daño por configuración: `lock_timeout: 10000` en
`config/database.yml:54` hace que nadie espere un lock más de 10 s, y
`ApplicationService#transactional` traduce el `ActiveRecord::LockWaitTimeout` a
un `Result.failure(:locked, …)` que el controller devuelve como 409. Ver docs/06.

### 7.4 Bloat, autovacuum e índices muertos

El repo ya trae dos rake tasks (`lib/tasks/stock.rake:105-151`):

```bash
bin/rails db:table_sizes      # filas vivas/muertas, tamaño, último autovacuum
bin/rails db:unused_indexes   # índices con idx_scan bajo o cero
```

La query cruda por si estás en `psql`:

```sql
SELECT relname AS tabla, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS pct_muertas,
       seq_scan, idx_scan,
       pg_size_pretty(pg_total_relation_size(relid)) AS total,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

Salida real (recortada) de este repo:

```
 tabla             | n_live_tup | n_dead_tup | seq_scan | idx_scan | total
 outbox_events     |        140 |         36 |       38 |      396 | 232 kB
 sequence_counters |          1 |         19 |       30 |        9 |  64 kB
 stock_items       |         48 |         19 |  1275635 |      898 | 112 kB
 api_tokens        |          8 |         16 |      564 |       75 | 160 kB
 products          |         15 |         15 |      635 |  1275641 | 176 kB
```

(`sequence_counters` es el caso extremo: **una** fila viva y 19 muertas. Es una
tabla de contadores que se actualiza sin parar; cada `UPDATE` deja una versión
muerta. Es el patrón que hace que un `SELECT` sobre una tabla de una fila
escanee decenas de páginas de basura si el autovacuum se queda atrás.)

Tres lecturas:

* **MVCC**: un `UPDATE` en Postgres **no** modifica la fila, escribe una versión
  nueva y marca la vieja como muerta. Si venís de Oracle/MySQL con undo log, esto
  es distinto: acá la basura queda **en la tabla** hasta que pase el vacuum. Por
  eso una tabla chica pero muy actualizada puede tener un `Seq Scan` lentísimo
  (docs/04 §17 tiene un caso medido: 24 ms para escanear 102 filas).
* **`outbox_events` es la tabla de riesgo de este repo**: es append-only y
  después se le hace `UPDATE` para setear `published_at`. Cada publicación genera
  una tupla muerta. `Cleanup::ExpiredRecordsJob` la poda, pero si el volumen sube
  hay que bajarle el umbral de autovacuum a esa tabla:

  ```sql
  ALTER TABLE outbox_events SET (autovacuum_vacuum_scale_factor = 0.02,
                                 autovacuum_vacuum_cost_delay = 2);
  ```

  El default es `0.2` (verificado con `SHOW autovacuum_vacuum_scale_factor`), o
  sea que espera a que el **20%** de la tabla esté muerta. En una tabla de 50
  millones de filas eso son 10 millones de tuplas muertas antes de mover un dedo.

* **`idx_scan` de `pg_stat_user_indexes` acumula desde el último
  `pg_stat_reset()`**. Un índice con `idx_scan = 0` puede ser un índice
  realmente inútil o puede que hayas reseteado las estadísticas ayer. El comentario
  de `lib/tasks/stock.rake:108-112` lo advierte, y está bien que lo advierta:
  borrar un índice único que sostiene una constraint por "no lo usa nadie" es un
  incidente.

### 7.5 Cache hit ratio

```sql
SELECT sum(heap_blks_read) AS disco, sum(heap_blks_hit) AS cache,
       round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) AS hit_ratio
FROM pg_statio_user_tables;
```

Real en este repo: `disco=76.656  cache=16.704.939  hit_ratio=99.54`.

Con `shared_buffers = 128 MB` (verificado) y una base de pocos MB, 99.5% es
esperable. Interpretación: **< 95% en producción = tu working set no entra en
RAM**. Las salidas son, en orden: (a) menos datos por query — índices, `pluck`,
paginación keyset; (b) más `shared_buffers`; (c) más RAM. Muchísima gente empieza
por (c), que es la cara y la que menos rinde.

### 7.6 Checkpoints

```sql
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_backend
FROM pg_stat_bgwriter;   -- en Postgres 17+ esto se movió a pg_stat_checkpointer
```

Real en este repo (son contadores acumulados desde el último
`pg_stat_reset_shared('bgwriter')`, así que sólo tienen sentido mirando el
**delta** entre dos lecturas):

```
checkpoints_timed | 63
checkpoints_req   | 51     <-- 45% de los checkpoints son FORZADOS
```

**Un `checkpoints_req` alto significa que Postgres se queda sin WAL antes de que
venza `checkpoint_timeout`** (5 min acá, verificado con `SHOW`) y tiene que
forzar un checkpoint. Un checkpoint forzado es una tormenta de I/O: escribe
todos los buffers sucios de golpe y ahí es donde aparecen esos picos de latencia
inexplicables en el p99.

Regla práctica: apuntá a que **más del 90% de los checkpoints sean `timed`**.
Acá son el 55%, o sea que esta base está muy por debajo de lo sano — cosa
esperable en una base de desarrollo que se cargó de golpe con seeds y
migraciones. El arreglo es subir `max_wal_size` (acá está en 1 GB).

`buffers_backend` alto (200.100 acá, contra 65.032 de `buffers_checkpoint`)
significa que los procesos de backend están escribiendo buffers ellos mismos
porque el bgwriter no da abasto — o sea, tus queries están pagando I/O que
debería hacer un proceso de fondo.

### 7.7 Los timeouts que este repo ya tiene puestos

`config/database.yml:52-55` — y esto es de lo mejor del repo, porque es lo
primero que falta en todas las apps:

```yaml
variables:
  statement_timeout: 15000                   # ms — matá cualquier query de más de 15 s
  lock_timeout: 10000                        # ms — no esperes locks eternamente
  idle_in_transaction_session_timeout: 30000 # ms — matá transacciones zombies
```

Sin `statement_timeout`, **una** query mala deja un thread de Puma colgado para
siempre; con 5 threads, cinco de esas y el proceso no atiende más. Es el
equivalente al `queryTimeout` del JDBC, pero del lado del **servidor**, que es el
lado que importa: si el cliente se muere, el servidor sigue ejecutando.

---

## 8. Health checks: `/up`, liveness y readiness

### 8.1 Qué hace `/up` realmente

`config/routes.rb:105` monta `get "up" => "rails/health#show"`. El controller es
`Rails::HealthController`, que vive en railties y hereda de
`ActionController::Base`. Todo lo que hace cabe en un párrafo: `show` responde
200 —`<body style="background-color: green">` para HTML,
`{"status":"up","timestamp":…}` para JSON— y un `rescue_from(Exception)` de
primera línea devuelve lo mismo en rojo con status 500 si algo explotó.

Verificado: `/up` **no toca la base**.

```
Started GET "/up" for 127.0.0.1
Processing by Rails::HealthController#show as */*
Completed 200 OK in 2ms (Views: 0.8ms | ActiveRecord: 0.0ms (0 queries, 0 cached))
```

O sea: `/up` responde "el proceso Ruby bootéo y puede servir HTTP". **Nada más.**
Y está bien que sea así.

### 8.2 Liveness vs readiness: la diferencia que tumba clusters

| | Liveness | Readiness |
|---|---|---|
| Pregunta | ¿El proceso está vivo? | ¿Puede atender tráfico **ahora**? |
| Si falla | El orquestador **REINICIA** el pod | El orquestador **SACA DE ROTACIÓN** el pod |
| Debe chequear | Sólo el proceso: `/up` tal cual | Dependencias **propias** e imprescindibles |
| Nunca debe chequear | Nada externo | Dependencias compartidas o de terceros |

⚠️ **El error que tumba el cluster entero**: poner un readiness que hace
`SELECT 1` a Postgres.

La base tiene un hipo de 10 segundos. Los 20 pods fallan el readiness **al mismo
tiempo**. El balanceador los saca **a todos** de rotación. Ahora no hay ninguna
instancia sirviendo: caída total del servicio, causada por una degradación
parcial de 10 segundos que la app podía haber absorbido reintentando.

Peor todavía si eso está en el **liveness**: los 20 pods se reinician a la vez,
todos vuelven a conectarse de golpe, y el thundering herd de conexiones tumba la
base de verdad. Convertiste un hipo en un incidente.

**Las reglas:**

1. **Liveness = `/up` puro.** Nunca toca la base, nunca toca Redis, nunca toca un
   tercero. Su única pregunta es "¿este proceso está trabado?".
2. **Readiness puede chequear la base, pero:** con timeout corto (< 1 s), con
   cache del resultado (2-5 s), y con **histéresis** (fallar N veces seguidas
   antes de declararse no-ready).
3. **Nunca chequees dependencias de terceros.** Si tu readiness pega a la API de
   un proveedor, ese proveedor puede tirarte el servicio.
4. **Nunca limites por rate el health check.** `config/initializers/rack_attack.rb`
   tiene un `safelist("permitir health checks")` justo para eso, y el comentario
   explica por qué: si lo limitás, el balanceador saca la instancia y **te caés
   solo**.
5. **Excluí `/up` del redirect a HTTPS y de la verificación de host**, porque el
   probe pega por IP y sin TLS. Las dos líneas están en
   `config/environments/production.rb`, **comentadas** (`config.ssl_options` en
   la 34, `config.host_authorization` en la 89): hay que descomentarlas el día
   que prendas `force_ssl` o `config.hosts`, no antes.

Un readiness razonable para este repo (no existe todavía):

```ruby
# app/controllers/health_controller.rb  (NO existe todavía en este repo)
class HealthController < ActionController::API
  def readiness
    checks = Rails.cache.fetch("health/readiness", expires_in: 3.seconds) do
      { db: db_ok?, queue: queue_ok? }
    end
    render json: checks, status: checks.values.all? ? :ok : :service_unavailable
  end

  private

  def db_ok?
    ActiveRecord::Base.connection.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = 500")
      ActiveRecord::Base.connection.select_value("SELECT 1")
    end == 1
  rescue StandardError
    false
  end

  # Un worker con heartbeat viejo significa cola parada, no que ESTA instancia
  # web esté rota: por eso esto va en un dashboard, NO en el readiness.
  def queue_ok? = true
end
```

El `SET LOCAL statement_timeout = 500` es el detalle, y va **dentro de una
transacción**: `LOCAL` sólo aplica ahí y se revierte solo al terminar (lo
verifiqué: después del bloque, `SHOW statement_timeout` vuelve a `15s`). Un
health check **sin timeout propio** hereda los 15 s de `config/database.yml` y se
convierte él mismo en el problema.

---

## 9. Alertas, SLO y error budget

### 9.1 SLI, SLO, SLA

* **SLI** (*indicator*): la medición. "Porcentaje de requests a `/api/v1/**` que
  responden < 300 ms y con status < 500."
* **SLO** (*objective*): el objetivo interno. "99,5% en ventana móvil de 28 días."
* **SLA** (*agreement*): el contrato con plata de por medio. El SLO **siempre**
  es más exigente que el SLA.
* **Error budget**: `100% − SLO`. Con 99,5% en 28 días tenés **3 h 21 min** de
  presupuesto de falla.

El error budget es lo que convierte la discusión "¿desplegamos o no?" en un
número: si te queda presupuesto, seguís desplegando; si lo quemaste, se congela y
se arreglan las causas. Esa es toda la idea, y es la respuesta que buscan en una
entrevista.

Un SLI para este repo tiene que ser **por clase de tráfico**, no global: la UI
Hotwire, la API de lectura, la API de escritura (que toma locks de fila) y los
reportes (que agregan) tienen perfiles de latencia incomparables. Un SLO único
para los cuatro no significa nada.

### 9.2 Qué alertar y qué no

| Alertar (con página) | Por qué |
|---|---|
| Error budget quemándose rápido (*burn rate*) | Es el único síntoma que siempre significa "los usuarios están sufriendo" |
| p99 de la API > 2× la línea base, 10 min sostenido | Degradación real |
| Tasa de 5xx > 1% durante 5 min | Ídem |
| **Latencia** de cola > 10 min | Los jobs no se están ejecutando |
| Lag del outbox > 5 min | Los otros sistemas están viendo datos viejos |
| `ReconcileBalancesJob` con `DRIFT_DETECTED` | **Siempre es un bug**: alguien escribió stock sin pasar por `ApplyMovement` |
| `security.authorization_missing` | Endpoint sin control de acceso (`base_controller.rb:127`) |
| `pool.stat[:waiting] > 0` sostenido | Saturación del pool: la próxima es `ConnectionTimeoutError` |
| `checkpoints_req` creciendo | Predice picos de latencia |

| Ruido (a un dashboard, no a un teléfono) | Por qué |
|---|---|
| CPU > 80% | Una app sana puede vivir al 85%. Alertá sobre el **efecto** (latencia), no sobre la causa |
| Un 500 aislado | Cualquier sistema tiene errores. Alertá sobre la **tasa** |
| Un 429 | Es el rate limiter **funcionando** |
| Uso de disco > 70% | Alertá sobre la **proyección** ("se llena en 4 h"), no sobre el nivel |
| Profundidad de cola sola | 10.000 jobs que se drenan en 3 s está bien. Alertá sobre la **latencia** |
| Un job fallado | Para eso están `retry_on` y la DLQ. Alertá sobre la tasa o sobre la DLQ creciendo |

**El principio**: alertá sobre **síntomas que el usuario percibe**, no sobre
causas. Una causa (CPU, memoria, disco) va a un dashboard para que la mires
*después* de que sonó la alerta de síntoma. Si alertás sobre causas, tenés 40
alertas por semana, la gente las silencia, y el día que importa nadie mira.

**Multi-window burn rate** (Google SRE): alertá con dos ventanas a la vez —
una corta (5 min) y una larga (1 h). La corta detecta rápido, la larga evita el
falso positivo de un pico de 30 segundos. Es la única receta de alertas de
latencia que no genera fatiga.

---

## 10. Runbook: "la app está lenta"

Paso a paso, con los comandos de **este** repo. La regla que ordena todo:
**bajá una capa por vez y medí antes de tocar nada.**

### Paso 0 — ¿Lenta para quién?

```bash
curl -s -D - -o /dev/null https://.../up               # ¿responde el proceso?
curl -s -D - -o /dev/null -H "Authorization: Bearer $TOK" https://.../api/v1/products
```

Mirá `x-runtime` (tiempo *dentro* de Rails). Si `x-runtime` es 20 ms pero el
usuario ve 4 s, **el problema no es Rails**: es la red, el balanceador, el TLS o
el cliente. Se acabó el diagnóstico del lado de la app.

### Paso 1 — ¿Está saturado?

```ruby
bin/rails runner 'pp ActiveRecord::Base.connection_pool.stat'
# {:size=>5, :connections=>0, :busy=>0, :dead=>0, :idle=>0, :waiting=>0, :checkout_timeout=>5.0}
```

`waiting > 0` ⇒ los threads hacen cola por conexiones. Es saturación, no
lentitud: no busques una query lenta, buscá **por qué las conexiones no se
liberan** (una query larga, una transacción abierta, o el pool mal dimensionado).

```bash
ps -eo pid,rss,args | grep puma     # ¿RSS creciendo sin techo? -> §6
```

### Paso 2 — ¿Es la base?

```sql
-- ¿qué corre ahora? (§7.2) — con los query log tags sabés qué controller es
SELECT pid, now() - query_start AS dur, state, wait_event_type, left(query,100)
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY dur DESC;

-- ¿alguien bloquea a alguien? (§7.3)
SELECT bloqueada.pid AS bloqueado, bloqueante.pid AS bloqueante,
       now() - bloqueada.query_start AS espera
FROM pg_stat_activity bloqueada
JOIN LATERAL unnest(pg_blocking_pids(bloqueada.pid)) AS b ON true
JOIN pg_stat_activity bloqueante ON bloqueante.pid = b;

-- ¿qué se lleva el tiempo total? (§7.1, si está la extensión)
SELECT calls, round(total_exec_time::numeric,1) AS total_ms, left(query,90)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
```

Si `db_runtime / duration` es > 60% en el evento `process_action`, la respuesta
está acá y seguís por docs/04 (`EXPLAIN ANALYZE`, índices, N+1).

### Paso 3 — ¿Es la cola?

```bash
bin/rails stock:outbox          # pendientes, trabados y lag del outbox
```

```sql
-- profundidad + espera (§3.3) y heartbeats de los workers
SELECT name, kind, now() - last_heartbeat_at AS antiguedad FROM solid_queue_processes;
```

Un worker con heartbeat de minutos = proceso muerto o colgado; el supervisor lo
debería reemplazar. Si la cola crece y los workers están vivos, o los jobs son
más lentos que antes o el volumen subió: mirá `job.finish` / `duration_ms` del
log estructurado de `app/jobs/application_job.rb:72`.

### Paso 4 — ¿Es Ruby?

Recién ahora sacás el profiler, y **con la configuración de producción** (§5.3):

```bash
RAILS_ENV=production bin/rails runner '
  require "stackprof"
  StackProf.run(mode: :wall, out: "tmp/p.dump", interval: 1000, raw: true) do
    200.times { StockMovements::Ledger.new(limit: 50).call.to_a }
  end'

bundle exec stackprof tmp/p.dump --limit 20
bundle exec stackprof tmp/p.dump --method "TuClase#metodo"
bundle exec stackprof tmp/p.dump --d3-flamegraph > tmp/flame.html
```

Si `(marking)` + `(sweeping)` se llevan más del 15%, el problema es asignación:
pasá a `memory_profiler` y buscá el `Total allocated` alto.

### Paso 5 — ¿Es el deploy?

```bash
git log --oneline -20
bin/rails middleware        # ¿alguien insertó un middleware caro?
bin/rails about             # versiones y schema version
```

El 80% de los "de golpe está lento" son un deploy: una migración que agregó un
índice mal, un `includes` que se sacó, un middleware nuevo, un feature flag.
**Mirá el diff antes de mirar el profiler.**

Un detalle de `bin/rails middleware` en este repo que asusta al principio:
**`Rack::Attack` aparece DOS veces**. Una la inserta `config/application.rb`
(`insert_after ActionDispatch::RemoteIp`) y la otra el railtie de la gema, que
hace `app.middleware.use(Rack::Attack)` sin condición. **No duplica los
contadores**: `Rack::Attack#call` arranca con
`return @app.call(env) if !self.class.enabled || env["rack.attack.called"]` y
setea esa clave en la línea siguiente, así que la segunda instancia es un no-op. Lo verifiqué con `curl`: con `logins/ip` en 5 por 20 s,
el 429 llega en el intento **6**, no en el 3. Contraste útil: el `rate_limit` de
controller **no** tiene esa protección — dos declaraciones sin `name:` distinto
sí comparten clave y cuentan doble, que es exactamente la trampa documentada en
`app/controllers/api/v1/base_controller.rb:59-74`.

---

## Errores que ves en producción

1. **Logs "estructurados" que ningún colector parsea.**
   *Síntoma*: en Loki/Datadog la línea entra como texto plano
   `{:event=>"job.start", :job=>"..."}` y no podés filtrar por campo.
   *Causa*: `Rails.logger.info(hash)` con el `SimpleFormatter` por defecto hace
   `Hash#inspect`, que no es JSON.
   *Arreglo*: un formatter JSON con
   `include ActiveSupport::TaggedLogging::Formatter` (§1.3). Sin ese `include`,
   `logger.tagged` explota en el boot.

2. **Un readiness que consulta la base saca todos los pods a la vez.**
   *Síntoma*: la base tiene un hipo de 10 s y el servicio se cae **entero**
   durante minutos.
   *Arreglo*: liveness = `/up` puro; readiness con timeout < 1 s, cacheado y con
   histéresis (§8.2).

3. **`ActiveRecord::ConnectionTimeoutError` al agregar instancias.**
   *Síntoma*: escalás de 2 a 4 máquinas y **empeora**.
   *Causa*: `workers × threads × 4 bases` supera `max_connections` (100).
   *Arreglo*: contar antes de escalar; PgBouncer en modo transaction pooling.

4. **El worker de Puma crece hasta que el kernel lo mata.**
   *Síntoma*: OOM kill periódico, sin `OutOfMemoryError` ni stacktrace.
   *Causa*: **no es un leak**: un endpoint cargó 50.000 filas una vez y el heap
   de Ruby no devuelve páginas al SO (medido en §6.2: liberé todo y el RSS bajó
   3,8 MB de 100).
   *Arreglo*: arreglar el endpoint (`find_each`, `pluck`, keyset), jemalloc vía
   `LD_PRELOAD` (ya está en el `Dockerfile`), y reciclar workers como parche.

5. **Dimensionar el contenedor con la suma de RSS.**
   *Síntoma*: pedís 40% más RAM de la necesaria y no entendés por qué el cgroup
   reporta menos.
   *Causa*: RSS cuenta las páginas compartidas en **cada** proceso forkeado.
   Medido acá: 665 MB de suma de RSS contra 493 MB de PSS.
   *Arreglo*: PSS (`/proc/PID/smaps_rollup`) o `memory.current` del cgroup.

6. **Profilar en desarrollo y optimizar lo que no existe en producción.**
   *Síntoma*: el profiler dice que el 32,6% se va en `Thread.each_caller_location`
   y `BacktraceCleaner`.
   *Causa*: `verbose_query_logs` + `server_timing` de
   `config/environments/development.rb`. Con eso apagado, el mismo trabajo pasó
   de 1397 a 788 muestras (§5.3).
   *Arreglo*: profilar con `RAILS_ENV=production`.

7. **Leer el comentario que trae el texto de `pg_stat_statements` como si fuera
   el de la ejecución lenta.**
   *Síntoma*: la fila más cara de `pg_stat_statements` dice
   `controller='reports'` y te pasás la tarde optimizando ese endpoint, cuando
   las 200.000 ejecuciones que agrupa vienen de cinco controllers distintos.
   *Causa*: el `queryid` se calcula sobre el árbol de parseo (los comentarios se
   descartan), pero el **texto** que se guarda es el de la **primera** ejecución
   que creó la entrada. Comprobado en §1.4 con `compute_query_id`.
   *Arreglo*: para saber quién dispara qué, mirá `pg_stat_activity` (que sí
   muestra la query en curso) o tu propio evento `process_action`; en
   `pg_stat_statements` mirá el plan, no el comentario.

8. **Alertar sobre causas en vez de síntomas.**
   *Síntoma*: 40 alertas por semana, todas silenciadas, y el incidente real pasa
   desapercibido.
   *Arreglo*: paginar sólo por burn rate del error budget, p99 y tasa de 5xx.
   CPU, memoria y disco van al dashboard.

9. **El health check limitado por el rate limiter.**
   *Síntoma*: bajo carga, el balanceador saca instancias sanas y el servicio se
   degrada solo.
   *Arreglo*: el `safelist("permitir health checks")` de
   `config/initializers/rack_attack.rb` — que este repo ya tiene, y que se
   olvida en el 90% de las apps.

10. **Un suscriptor de Notifications que hace I/O adentro de la request.**
    *Síntoma*: el p99 sube después de "agregar métricas".
    *Causa*: los suscriptores corren **síncronos, en el mismo thread**. Medido:
    un suscriptor de bloque lleva `instrument` de 0,5 µs a 4,4 µs (7,6 µs si el
    bloque recibe un `Event`); uno que escriba a un socket suma su latencia
    entera a la request.
    *Arreglo*: bufferear en memoria y flushear desde un thread aparte.

11. **`config.log_level = :debug` "por un ratito" en producción.**
    *Síntoma*: factura del colector por las nubes y latencia p99 peor.
    *Causa*: escribir a STDOUT es una syscall bloqueante, y con el GVL bloquea al
    proceso, no sólo al thread. Además `debug` loguea los binds de cada query.
    *Arreglo*: `RAILS_LOG_LEVEL` por instancia (ya está parametrizado en
    `config/environments/production.rb:41`) y volverlo atrás.

12. **Checkpoints forzados como picos "inexplicables" de p99.**
    *Síntoma*: la latencia se dispara cada pocos minutos sin correlación con el
    tráfico.
    *Causa*: `max_wal_size` chico fuerza checkpoints, que son tormentas de I/O.
    Medido acá: 51 forzados contra 63 programados, o sea 45% de forzados.
    *Arreglo*: subir `max_wal_size` hasta que > 90% sean `timed`.

13. **Alertar sobre el heartbeat de los workers con el umbral equivocado.**
    *Síntoma*: la guardia recibe "worker muerto" varias veces por hora y los
    workers están perfectamente vivos.
    *Causa*: `SolidQueue.process_heartbeat_interval` **es** 60 s, así que un
    worker sano pasa casi todo el tiempo con un `last_heartbeat_at` de entre 0 y
    59 segundos. Alertar con "> 60 s" es alertar sobre el latido normal.
    *Arreglo*: usar `SolidQueue.process_alive_threshold` (5 minutos), que es el
    umbral con el que la propia gema da un proceso por muerto.

---

## Cómo responder esto en una entrevista

**1. "¿Qué es `ActiveSupport::Notifications` y cómo lo usarías?"**
Es el bus de eventos pub/sub in-process de Rails. El framework instrumenta
queries, render, encolado de jobs y cache; los logs "bonitos" de Rails son
suscriptores de ese bus. Es el punto de enganche que usan todos los APM. Yo lo
usaría para emitir una línea estructurada por request desde
`process_action.action_controller`, que en Rails 8.1 ya trae `queries_count` —
alertar sobre eso es la detección de N+1 más barata que existe.
*Trade-off*: los suscriptores corren **síncronos en el mismo thread**, así que
uno que haga I/O suma su latencia a la request. Medido: `instrument` sin
suscriptores cuesta ~500 ns; con un suscriptor de bloque, ~4,4 µs (~7,6 µs si el
bloque pide el objeto `Event`, que mide CPU, allocations y GC). Instrumentar es
casi gratis; escuchar no.
*Dónde se rompe la analogía con Java*: no es Micrometer. Micrometer **es** un
registro de métricas con histogramas y exportadores; Notifications te da eventos
crudos y la agregación es tuya.

**2. "La app está lenta. ¿Qué hacés?"**
Bajo una capa por vez y mido antes de tocar. (a) `x-runtime` versus lo que ve el
usuario: si difieren mucho, no es Rails. (b) `connection_pool.stat` — si
`waiting > 0` es saturación, no lentitud. (c) `pg_stat_activity` +
`pg_blocking_pids` para queries largas y locks; con los query log tags de este
repo el comentario del SQL me dice qué controller la disparó. (d) Si
`db_runtime/duration > 60%`, el problema es la base y sigo con `EXPLAIN ANALYZE`.
(e) Recién ahí saco stackprof en modo `:wall`, y **con `RAILS_ENV=production`**.
(f) Y antes que todo eso, miro el último deploy: el 80% de los "de golpe está
lento" son un cambio.
*Trade-off*: el orden importa porque cada paso es más caro que el anterior. Sacar
el profiler primero es la forma más rápida de perder una hora optimizando algo
que no era.

**3. "Diferencia entre liveness y readiness, y por qué importa."**
Liveness responde "¿el proceso está trabado?" y si falla, el orquestador
**reinicia**. Readiness responde "¿puede atender ahora?" y si falla, lo **saca de
rotación**. La consecuencia práctica: un readiness que hace `SELECT 1` convierte
un hipo de 10 segundos de la base en una caída total, porque **los 20 pods fallan
a la vez** y no queda ninguno sirviendo. En liveness es peor todavía: se
reinician todos juntos y el thundering herd de reconexiones tumba la base de
verdad. El `/up` de Rails no toca la base a propósito — lo verifiqué, responde
con 0 queries — y eso es lo correcto para liveness.
*Trade-off*: un readiness que **sí** chequea la base detecta antes un pod
realmente roto; el precio es el riesgo de correlación. Se mitiga con timeout
corto, cache de 2-5 s e histéresis.

**4. "¿Por qué el proceso Ruby crece y no baja? ¿Es un memory leak?"**
Casi nunca. El GC de Ruby libera **slots**, pero **no devuelve páginas al SO**.
Lo medí en este repo: asigné 300k strings (RSS de 94 a 194 MB), las liberé todas
y forcé cuatro GC completos más `GC.compact` — los slots vivos volvieron a
246.752 y el RSS bajó a 190 MB. O sea: el worker queda del tamaño de su peor
momento. La causa habitual es una request patológica que cargó demasiadas filas.
Se ataca en tres frentes: arreglar la request (`find_each`, `pluck`, keyset),
jemalloc por `LD_PRELOAD` (que este repo ya tiene en el `Dockerfile`) o
`MALLOC_ARENA_MAX=2`, y reciclar workers como parche.
*Trade-off*: reciclar workers esconde el problema y te cuesta un cold start por
reciclo. Sirve como red, no como solución.

**5. "¿Cómo dimensionás workers y threads?"**
Workers ≈ núcleos, porque el GVL hace que un proceso use como máximo un núcleo
para Ruby; threads ~5, porque el GVL se libera durante el I/O pero pasado ese
punto la latencia empeora. La memoria se calcula con **PSS, no RSS**: en este
repo los 6 procesos de Solid Queue suman 665 MB de RSS pero 493 MB de PSS —
172 MB son páginas compartidas contadas seis veces. Y la restricción que ata
primero en una app Rails 8 no suele ser CPU ni RAM: es el **pool de conexiones**,
porque son `workers × threads × 4 bases` contra `max_connections`.
*Trade-off*: más workers = más throughput y más RAM; más threads = más
throughput con la misma RAM pero peor latencia. Si el cuello es el pool, subir
cualquiera de los dos empeora las cosas.

**6. "¿Qué alertas pondrías?"**
Sobre **síntomas que el usuario percibe**, no sobre causas: burn rate del error
budget con dos ventanas (5 min y 1 h), p99 y tasa de 5xx. CPU, memoria y disco
van al dashboard, no al teléfono — una app sana puede vivir al 85% de CPU. Para
este dominio agregaría tres específicas: **latencia** de cola (no profundidad;
10.000 jobs que se drenan en 3 s están bien y 3 jobs esperando 20 minutos no),
lag del outbox, y cualquier `DRIFT_DETECTED` de `ReconcileBalancesJob`, que
siempre significa que alguien escribió stock sin pasar por `ApplyMovement`.
*Trade-off*: alertar sobre causas detecta antes pero genera fatiga; alertar sólo
sobre síntomas es más limpio pero te enterás cuando el usuario ya sufrió. Por eso
existe el burn rate multi-ventana: es el punto medio.

**7. "¿Qué medirías del promedio de latencia?"**
Nada: el promedio miente siempre para el mismo lado. Con 99 requests de 10 ms y
una de 5 s, el promedio da 59,9 ms y suena bien, pero el peor 1% son 5 segundos
enteros. Y los
percentiles **no se promedian entre instancias**: necesitás histogramas
agregables. Además hay que separar latencia de éxitos y de errores, porque un 500
que responde en 3 ms te baja el p99 y te esconde que el servicio se cae.
*Trade-off*: p99 es sensible al ruido con poco tráfico; en endpoints de bajo
volumen conviene p95 más una alerta de conteo absoluto de errores.

---

## Para seguir

* **docs/04** — `EXPLAIN`, N+1, índices, `pg_stat_statements` y `auto_explain`.
* **docs/06** — locks, transacciones y el GVL en detalle.
* **docs/07** — Solid Queue por dentro, outbox y DLQ.
* **docs/08** — las dos capas de rate limiting y sus contadores.
* **docs/10** — el catálogo completo de errores de producción.
