# Colas, jobs y mensajería

Acá tenés cómo esta app saca trabajo del request: qué es Active Job y por qué es
una fachada y no una implementación, cómo funciona Solid Queue por dentro (las
tablas reales, el `FOR UPDATE SKIP LOCKED`, los semáforos, el scheduler), en qué
se diferencia de Sidekiq, y —el plato fuerte— el **transactional outbox**: el
problema del dual write, el relay, at-least-once, deduplicación y particionado.

Está escrito para vos que venís de Spring: Active Job es JMS, Solid Queue es
"Quartz con JDBCJobStore pero bien hecho", y el outbox es lo mismo que ya
conocés de Debezium/Kafka. Las analogías sirven hasta cierto punto; te marco
dónde se rompen, que es donde la gente se equivoca.

Todo lo que hay acá salió de correr el repo. Cuando digo "esto pasa", lo corrí.

---

## 1. Active Job: la fachada (la JMS de Rails)

`ActiveJob::Base` no ejecuta nada. Define un contrato —`perform_later`,
`perform_now`, `queue_as`, `retry_on`, serialización de argumentos— y delega en
un **adapter**. Es exactamente el rol de JMS en Java: la API es estándar, el
broker es intercambiable.

```ruby
# app/jobs/stock/expire_reservations_job.rb
module Stock
  class ExpireReservationsJob < ApplicationJob
    queue_as :maintenance

    def perform(limit: 5_000)
      result = ExpireReservations.call(limit:)
      Rails.logger.info(event: "reservations.expired", **result.value)
      result.value
    end
  end
end
```

Ese job corre igual sobre Postgres (Solid Queue) o sobre Redis (Sidekiq). No hay
una línea que mencione ninguno de los dos.

### Qué ganás y qué perdés

| | Con Active Job | Sin Active Job (`include Sidekiq::Job`) |
|---|---|---|
| Portabilidad de backend | ✅ una env var | ❌ reescribís los jobs |
| `retry_on` / `discard_on` declarativos | ✅ | ❌ (usás `sidekiq_options retry:`) |
| Serialización de modelos (GlobalID) | ✅ | ❌ (serializás vos) |
| `ActiveSupport::Notifications` uniformes | ✅ | parcial |
| Batches, unique jobs, rate limiting por cola | ❌ | ✅ (Sidekiq Pro/Enterprise) |
| Overhead de wrapping | ~1 capa de serialización extra | ninguno |

El costo real de la abstracción es **el mínimo común denominador**: Active Job
expone lo que todos los backends saben hacer. Si necesitás batches de Sidekiq
Pro o el rate limiter de Enterprise, tenés que heredar de `Sidekiq::Job` directo
y perder la portabilidad. Está documentado como trade-off consciente en
`app/jobs/application_job.rb`.

### El mapa mental desde Spring

| Java / Spring | Rails | Dónde se rompe la analogía |
|---|---|---|
| JMS (`@JmsListener`, `JmsTemplate`) | Active Job + adapter | En JMS el consumidor es una clase aparte del productor. En Active Job **la misma clase** es el mensaje y el handler. |
| `@Async` + `TaskExecutor` | adapter `async` | El de Rails vive en memoria del proceso web y **pierde los jobs** al reiniciar. |
| `@Scheduled` / Quartz | `config/recurring.yml` de Solid Queue | Quartz necesita `JDBCJobStore` + clustering para no correr N veces; Solid Queue lo resuelve con un índice único (§3.6). |
| `@Transactional` + `TransactionSynchronization.afterCommit` | `ActiveRecord.after_all_transactions_commit` | Ver §9: en Rails 8.1 la config global de esto **fue removida**. |
| Spring Batch | ninguno equivalente | Los jobs de Rails son unidades chicas; el "chunk processing" lo escribís vos con `in_batches`. |

---

## 2. Los adapters y cómo se elige en este repo

`config/initializers/active_job.rb` es todo el mecanismo:

```ruby
default_adapter = Rails.env.test? ? "test" : "solid_queue"
adapter = ENV.fetch("QUEUE_ADAPTER", default_adapter)

config.active_job.queue_adapter = adapter.to_sym
config.active_job.queue_name_prefix = Rails.env.production? ? nil : Rails.env
config.solid_queue.connects_to = { database: { writing: :queue } } if adapter == "solid_queue"
config.active_job.default_queue_name = "default"
```

```bash
QUEUE_ADAPTER=solid_queue bin/rails s   # Postgres, sin Redis (default)
QUEUE_ADAPTER=sidekiq     bin/rails s   # Redis
QUEUE_ADAPTER=async       bin/rails s   # in-process, PIERDE JOBS
QUEUE_ADAPTER=inline      bin/rails s   # ejecuta ya, en el mismo thread
```

La variable está documentada en `.env.example` (línea 38).

| Adapter | Dónde vive la cola | Durable | Latencia | Para qué sirve |
|---|---|---|---|---|
| `solid_queue` | Postgres (base `queue`) | ✅ ACID | 0,1–1 s (polling) | producción por defecto |
| `sidekiq` | Redis | depende de AOF/RDB | ~1 ms (BRPOP) | volumen alto / latencia baja |
| `async` | thread pool **en memoria** | ❌ | inmediata | jugar en dev, nada más |
| `inline` | no hay cola | n/a | 0 | debuggear un job sin worker |
| `test` | array en memoria | n/a | no ejecuta | specs (`have_enqueued_job`) |

### Por qué `async` pierde jobs

`AsyncAdapter` mete el job en un `Concurrent::ThreadPoolExecutor` del **proceso
web**. No hay ninguna escritura persistente. Si el proceso recibe un `SIGKILL`,
lo mata el OOM killer, o simplemente hacés un deploy, la cola pendiente se
evapora sin log, sin métrica y sin excepción. Es el default de desarrollo de
Rails y por eso es una trampa: en dev nunca lo notás porque todo es rápido.

En Java el equivalente es un `@Async` sobre un `ThreadPoolTaskExecutor` sin
persistencia: mismo problema, misma gente sorprendida en producción.

### El adapter `test` no ejecuta nada

Es deliberado: en test los jobs se acumulan en un array y los inspeccionás.

```ruby
# spec/jobs/outbox_publish_pending_job_spec.rb:69
expect { described_class.perform_now(batch_size: 3) }
  .to have_enqueued_job(described_class)
```

Si dejaras `solid_queue` en test, cada spec escribiría filas en la base de jobs,
los tests se volverían lentos y quedarían acoplados por estado compartido.

### ⚠️ El prefijo de cola por entorno cambia el nombre real

`queue_name_prefix = Rails.env` fuera de producción. Eso significa que **en
desarrollo las colas no se llaman como vos creés**:

```console
$ bin/rails runner 'puts Outbox::PublishPendingJob.new.queue_name'
development_outbox
$ bin/rails runner 'puts Stock::ExpireReservationsJob.new.queue_name'
development_maintenance
```

Y el selector de colas de Solid Queue hace **match exacto**:

```console
$ bin/rails runner 'puts SolidQueue::QueueSelector.new(["outbox"], SolidQueue::ReadyExecution).scoped_relations.map(&:to_sql)'
SELECT "solid_queue_ready_executions".* FROM "solid_queue_ready_executions"
  WHERE "solid_queue_ready_executions"."queue_name" = 'outbox'
```

O sea: en desarrollo el worker declarado como `queues: [ outbox ]` en
`config/queue.yml` **nunca toma un job**, porque los jobs caen en
`development_outbox`. Lo salva el tercer worker, que declara `"*"`. En
producción el prefijo es `nil` y todo coincide. Es un desajuste inofensivo acá,
pero si copiás este patrón a staging con workers dedicados sin `*`, la cola se
queda quieta y no hay ningún error: simplemente nadie la mira.

Ojo con el "arreglo" instintivo: `QueueSelector` soporta comodines, pero **sólo
como sufijo** (`prefixed_name?(queue) = queue.ends_with?("*")`). `staging_*`
funciona y toma todas las colas de staging; `*outbox` no matchea nada. Para
tener un worker dedicado a `outbox` en un entorno con prefijo hay que nombrar la
cola completa (`staging_outbox`) o no ponerle prefijo fuera de producción.

---

## 3. Solid Queue por dentro

Solid Queue no es "una tabla con jobs". Son 13 tablas más las dos de Rails. Esto
es lo que hay realmente en la base `stock_development_queue`:

```console
$ psql -d stock_development_queue -tAc \
    "SELECT tablename FROM pg_tables WHERE tablename LIKE 'solid_queue%' ORDER BY 1"
solid_queue_batch_executions
solid_queue_batches
solid_queue_blocked_executions
solid_queue_claimed_executions
solid_queue_failed_executions
solid_queue_jobs
solid_queue_pauses
solid_queue_processes
solid_queue_ready_executions
solid_queue_recurring_executions
solid_queue_recurring_tasks
solid_queue_scheduled_executions
solid_queue_semaphores
```

El esquema completo está versionado en `db/queue_schema.rb`.

### 3.1 El modelo de datos: un job, muchos estados

`solid_queue_jobs` es la fila canónica (clase, argumentos serializados, cola,
prioridad, `scheduled_at`, `finished_at`). El **estado** no es una columna: es
*en qué tabla de ejecución está la fila*.

```text
                      perform_later
                            │
              ┌─────────────┴──────────────┐
     scheduled_at futuro            scheduled_at <= now
              │                             │
   scheduled_executions ──dispatcher──> ready_executions
              │                             │
              │                        worker (SKIP LOCKED)
              │                             ▼
              │                     claimed_executions
              │                             │
              │              ┌──────────────┼──────────────┐
              │              ▼              ▼              ▼
              │           (borra)   failed_executions   retry_job
              │            OK           excepción       (vuelve a scheduled)
              │
        blocked_executions  <── si el job tiene límite de concurrencia
        (espera un semáforo)
```

Es una máquina de estados con **una tabla por estado**, no un `status` con
índice. La razón es de performance: la tabla `ready_executions` contiene sólo lo
pendiente de ejecutar —decenas o cientos de filas— y el índice de polling
(`index_solid_queue_poll_by_queue` sobre `queue_name, priority, job_id`) siempre
es un covering index chiquito, aunque `solid_queue_jobs` tenga 200 millones de
filas históricas. Un `WHERE status = 'ready'` sobre una tabla gigante no te da
eso.

Para un javero: es lo contrario de lo que hace Quartz con `QRTZ_TRIGGERS` y su
columna `TRIGGER_STATE`. El diseño de Solid Queue paga con joins lo que ahorra
en tamaño de índice.

### 3.2 Los procesos: supervisor, dispatcher, workers, scheduler

`bin/jobs` levanta un supervisor que forkea los demás. Esto es lo que se ve
corriendo de verdad con la config de este repo:

```console
$ ps aux | grep solid-queue
solid-queue-fork-supervisor(1.7.0): supervising 13662, 13666, 13669, 13674, 13678
solid-queue-dispatcher(1.7.0): dispatching every 1 seconds
solid-queue-worker(1.7.0): waiting for jobs in critical
solid-queue-worker(1.7.0): waiting for jobs in outbox
solid-queue-worker(1.7.0): waiting for jobs in default,mailers,maintenance,*
solid-queue-scheduler(1.7.0): scheduling expire_reservations,publish_outbox,low_stock_scan,reconcile_balances,cleanup
```

Y se registran en `solid_queue_processes` con heartbeat:

```console
$ psql -d stock_development_queue -c "SELECT kind, pid, supervisor_id, last_heartbeat_at FROM solid_queue_processes"
       kind       |  pid  | supervisor_id |       last_heartbeat_at
------------------+-------+---------------+-------------------------------
 Supervisor(fork) | 13650 |               | 2026-08-30 17:48:42.118095+00
 Dispatcher       | 13662 |             1 | 2026-08-30 17:48:42.748163+00
 Worker           | 13666 |             1 | 2026-08-30 17:48:43.007582+00
 Worker           | 13669 |             1 | 2026-08-30 17:48:43.036636+00
 Worker           | 13674 |             1 | 2026-08-30 17:48:43.034280+00
 Scheduler        | 13678 |             1 | 2026-08-30 17:48:43.076611+00
```

Qué hace cada uno:

- **Dispatcher**: mueve `scheduled_executions` vencidas a `ready_executions`, en
  lotes de `batch_size`. También corre el mantenimiento de concurrencia.
- **Worker**: hace polling sobre `ready_executions`, reclama y ejecuta.
- **Scheduler**: encola los recurring tasks.
- **Supervisor**: forkea, vigila heartbeats, maneja señales de shutdown.

#### Qué pasa con los jobs de un worker que se muere

Ese heartbeat es lo que permite **no perder los jobs de un worker muerto**, y acá
hay que ser preciso porque casi todo el mundo lo cuenta mal. Hay dos caminos y
**no terminan en el mismo lugar**:

- **Baja ordenada** (`SIGTERM`, el proceso se deregistra solo): al destruirse la
  fila de `solid_queue_processes` corre `after_destroy :release_all_claimed_executions`,
  que hace `job.dispatch_bypassing_concurrency_limits` — o sea, los jobs
  **vuelven a `ready_executions`** y otro worker los toma. Reintento automático.
- **Muerte abrupta** (`SIGKILL`, OOM, se cae la instancia): el supervisor poda el
  proceso cuando se le vence el heartbeat —late cada
  `process_heartbeat_interval` (60 s) y se lo da por muerto pasado
  `process_alive_threshold` (5 min)— y sus `claimed_executions` van a
  **`failed_executions`**, no a `ready`:

  ```ruby
  # solid_queue-1.7.0/app/models/solid_queue/process/prunable.rb:24
  def prune
    error = Processes::ProcessPrunedError.new(last_heartbeat_at)
    fail_all_claimed_executions_with(error)
    deregister(pruned: true)
  end
  ```

  Lo mismo si el supervisor reapea un fork que murió (`ProcessExitError`) o si al
  arrancar encuentra `claimed_executions` sin proceso dueño (`ProcessMissingError`,
  `ClaimedExecution.orphaned`).

La diferencia importa en producción: **un `SIGKILL` con jobs en vuelo no los
pierde, pero tampoco los reintenta solo.** Quedan en `failed_executions` con el
error `ProcessPrunedError` y los reintentás vos desde Mission Control (o con
`SolidQueue::FailedExecution#retry`). Eso es a propósito: la gema no sabe si el
job es idempotente, así que te obliga a decidir. Sidekiq OSS, en cambio, en ese
mismo escenario **pierde el job y no queda rastro** (§4.3).

Corolario operativo: alertá sobre `solid_queue_failed_executions`. Después de un
OOM kill, ahí están los jobs que no corrieron y nadie los va a levantar por vos.

#### La baja ordenada tiene reloj: `shutdown_timeout`

El camino bueno —el `SIGTERM` que devuelve los jobs a `ready`— sólo llega hasta
donde llega el reloj. Ante un `SIGTERM`, Solid Queue deja de tomar jobs nuevos y
espera `shutdown_timeout` a que terminen los que están en vuelo; pasado ese
tiempo, los mata. El default de la gema son **5 segundos**
(`solid_queue-1.7.0/lib/solid_queue.rb:35`: `mattr_accessor :shutdown_timeout,
default: 5.seconds`), que no alcanza para casi ningún job real: con eso, cada
deploy corta jobs a la mitad. Este repo lo sube en
`config/initializers/solid_queue.rb`:

```ruby
config.solid_queue.shutdown_timeout = ENV.fetch("SOLID_QUEUE_SHUTDOWN_TIMEOUT", 25).to_i.seconds
```

```console
$ bin/rails runner 'puts SolidQueue.shutdown_timeout.inspect'
25 seconds
```

La regla para elegir el número: tiene que quedar **por debajo** del grace period
del orquestador (`terminationGracePeriodSeconds` en Kubernetes, el drain del
proxy en Kamal). Si es mayor, el `SIGKILL` llega antes de que Solid Queue
termine su apagado ordenado y volvés al caso feo de arriba —jobs en
`failed_executions`— justo en cada deploy.

### 3.3 `FOR UPDATE SKIP LOCKED`: la primitiva

Esta cláusula (Postgres 9.5+) es la razón por la que se puede hacer una cola
seria en SQL. Vale la pena entenderla bien porque es *la* pregunta técnica de
esta sección.

```sql
SELECT job_id
FROM solid_queue_ready_executions
WHERE queue_name = 'critical'
ORDER BY priority ASC, job_id ASC
LIMIT 5
FOR UPDATE SKIP LOCKED;
```

Dos piezas:

- `FOR UPDATE` toma un **lock exclusivo de fila** sobre lo que devuelve el
  `SELECT`. El lock dura hasta el `COMMIT`/`ROLLBACK`.
- `SKIP LOCKED` cambia el comportamiento por defecto: en vez de **esperar** a que
  se libere una fila bloqueada por otra transacción, la **saltea** y sigue
  buscando hasta completar el `LIMIT`.

El efecto: N workers pueden correr esta misma query al mismo tiempo y cada uno
se lleva un conjunto **disjunto** de filas. Sin coordinación externa, sin
Zookeeper, sin Redis, sin deadlocks, sin que ninguno espere.

Sin `SKIP LOCKED` tenés dos opciones, las dos malas:

- `FOR UPDATE` solo: el worker 2 se bloquea esperando al worker 1. La cola se
  serializa y agregar workers no aumenta el throughput.
- `UPDATE ... WHERE id IN (SELECT ...)` sin lock: dos workers seleccionan las
  mismas filas y las ejecutan las dos veces (o una pisa a la otra y perdés
  trabajo).

Comparado con Java: es lo mismo que buscabas con un `SELECT ... FOR UPDATE` +
`PESSIMISTIC_WRITE` en JPA, pero `SKIP LOCKED` no tiene equivalente en JPA
estándar; en Hibernate tenés que bajar a `@QueryHints` con
`javax.persistence.lock.timeout = -2` (`SKIP_LOCKED`) y depende del dialecto.

Dónde está en el código de Solid Queue:

```ruby
# solid_queue-1.7.0/app/models/solid_queue/record.rb:13
def non_blocking_lock
  if SolidQueue.use_skip_locked
    lock(Arel.sql("FOR UPDATE SKIP LOCKED"))
  else
    lock
  end
end
```

El `if` es una válvula de escape para backends sin `SKIP LOCKED` (MySQL < 8).
`SolidQueue.use_skip_locked` es un `mattr_accessor` con default `true`
(`solid_queue-1.7.0/lib/solid_queue.rb:29`), verificado en este repo:

```console
$ bin/rails runner 'puts SolidQueue.use_skip_locked.inspect'
true
```

Y en este repo lo usamos igual para el outbox:

```ruby
# app/models/outbox_event.rb:27
def self.claim_batch(limit: 500)
  pending
    .where(attempts: ...MAX_ATTEMPTS)
    .order(:id)
    .limit(limit)
    .lock("FOR UPDATE SKIP LOCKED")
end
```

```console
$ bin/rails runner 'puts OutboxEvent.claim_batch(limit: 200).to_sql'
SELECT "outbox_events".* FROM "outbox_events"
WHERE "outbox_events"."published_at" IS NULL AND "outbox_events"."attempts" < 10
ORDER BY "outbox_events"."id" ASC LIMIT 200 FOR UPDATE SKIP LOCKED
```

**Detalle que se pasa por alto**: el lock vive mientras dure la transacción. Si
tu lote tarda 30 segundos, esas filas están bloqueadas 30 segundos y además
tenés una transacción larga que frena el `VACUUM`. Por eso el relay usa lotes
chicos (§8.4). Solid Queue va más lejos: reclama en una transacción cortita que
sólo *mueve* la fila a `claimed_executions`, y recién después ejecuta el job
fuera de la transacción.

### 3.4 Polling: el trade-off central

```yaml
# config/queue.yml
workers:
  - queues: [ critical ]
    threads: 3
    polling_interval: 0.1
    processes: 1
```

Cada worker duerme `polling_interval` entre queries (con `interruptible_sleep`,
así que un shutdown no espera). Bajarlo reduce la latencia y sube la carga sobre
Postgres, linealmente:

```text
queries por segundo = procesos × (1 / polling_interval)
```

Con la config de producción de este repo: `critical` son 2 procesos × 10/s = 20
QPS de polling, `outbox` 2 × 2 = 4 QPS, el resto 3 × 1 = 3 QPS. Total ~27 QPS
de queries que casi siempre devuelven 0 filas. Es barato porque el índice es
chico y las filas están en shared buffers, pero **no es gratis**: si ponés
`polling_interval: 0.01` con 20 procesos son 2000 QPS de puro ruido.

Detalle de implementación: `polling_interval` es el techo, no el ritmo fijo, y
**dispatcher y worker lo aplican distinto**.

El dispatcher, si el lote trajo trabajo, no duerme nada:

```ruby
# solid_queue-1.7.0/lib/solid_queue/dispatcher.rb:36
def poll
  batch = dispatch_next_batch
  batch.zero? ? polling_interval : 0.seconds
end
```

El worker hace algo más astuto: duerme `polling_interval` sólo si su pool de
threads está ocioso; si está saturado se duerme **10 minutos**, porque no tiene
sentido reclamar jobs que no puede ejecutar. Lo despierta el propio pool cuando
se libera un thread (`on_idle: -> { wake_up }`, y el sleep es
`interruptible_sleep`):

```ruby
# solid_queue-1.7.0/lib/solid_queue/worker.rb:35
def poll
  claim_executions.then do |executions|
    executions.each { |execution| pool.post(execution) }
    pool.idle? ? polling_interval : 10.minutes
  end
end
```

O sea que bajo carga el worker no hace polling ciego: se maneja por eventos del
pool. El `polling_interval` sólo gobierna el caso "no hay nada que hacer", que
es justamente el que define la latencia de arranque de un job.

Sidekiq no tiene este trade-off porque `BRPOP` es *bloqueante*: el worker se
duerme en Redis y Redis lo despierta. Esa es la diferencia arquitectónica de
fondo entre los dos (§4.1).

### 3.5 Semáforos: concurrencia limitada

`solid_queue_semaphores` implementa "no más de N de este job a la vez", que es lo
que en Java resolvés con un `Semaphore` o con `@ConcurrencyLimit`. Se declara
por job; ninguno de este repo lo usa todavía, así se declararía:

```ruby
class SyncSupplierCatalogJob < ApplicationJob   # ejemplo, no está en el repo
  # No más de 2 sincronizaciones simultáneas POR PROVEEDOR.
  limits_concurrency to: 2, key: ->(supplier_id) { supplier_id }, duration: 5.minutes

  def perform(supplier_id) = ...
end
```

La firma real es
`limits_concurrency(key:, to: 1, group:, duration:, on_conflict: :block)`
(`solid_queue-1.7.0/lib/active_job/concurrency_controls.rb:20`). `on_conflict:`
acepta `:block` (default, encola bloqueado) o `:discard` (tira el job).

El mecanismo, leído del código de la gema — y ojo con el orden, porque no es el
que uno supone: **el semáforo se toma al DESPACHAR, no al ejecutar**. Para un
`perform_later` normal eso es el momento del encolado; para un job programado,
el momento en que el dispatcher lo vence (`Job#dispatch`,
`app/models/solid_queue/job/executable.rb:71`).

1. `Semaphore.wait` primero hace `Semaphore.lock.find_by(key:)` — que es un
   `SELECT ... FOR UPDATE` de verdad, **con lock explícito**. Si la fila existe
   y `value > 0`, decrementa (`UPDATE ... SET value = value - 1 WHERE value > 0`).
   Si no existe, va por `INSERT ... ON CONFLICT DO NOTHING` con
   `value: limit - 1`, y si el insert lo gana otro, reintenta el decremento.
2. Si consigue cupo, el job va directo a `ready_executions`. Si no, va a
   `blocked_executions` con un `expires_at`.
3. Al terminar el job (bien o mal), `ClaimedExecution` llama
   `job.unblock_next_blocked_job`: incrementa el semáforo y mueve **un**
   bloqueado de `blocked` a `ready`
   (`app/models/solid_queue/claimed_execution.rb:116`).
4. El `concurrency_maintenance_interval` del dispatcher (600 s en
   `config/queue.yml`) barre semáforos vencidos y libera jobs que quedaron
   bloqueados porque el que tenía el cupo murió sin hacer `signal`.

⚠️ Consecuencia del punto 3 que el README de la gema marca explícitamente: los
bloqueados se liberan **por prioridad, ignorando el orden de colas del worker**.
Si mezclás un grupo de concurrencia entre varias colas, el orden que declaraste
en `config/queue.yml` no manda en el desbloqueo.

**El `duration` importa**: si un worker muere sin hacer `signal`, el cupo queda
tomado hasta que expire. Ese barrido es la red de seguridad, no un detalle.

⚠️ Esto NO es un "unique job". `limits_concurrency` limita cuántos corren a la
vez; no impide que encoles el mismo job 500 veces. Para deduplicar en el
*encolado* necesitás algo como el SETNX del §8.5.

### 3.6 Recurring tasks: por qué corren en UNA instancia

```yaml
# config/recurring.yml
expire_reservations:
  class: Stock::ExpireReservationsJob
  schedule: every minute

publish_outbox:
  class: Outbox::PublishPendingJob
  schedule: every minute

reconcile_balances:
  class: Stock::ReconcileBalancesJob
  schedule: every day at 3am
```

Corriendo de verdad:

```console
$ psql -d stock_development_queue -c "SELECT task_key, run_at, job_id FROM solid_queue_recurring_executions ORDER BY run_at DESC LIMIT 4"
      task_key       |         run_at         | job_id
---------------------+------------------------+--------
 publish_outbox      | 2026-08-30 17:49:00+00 |     58
 expire_reservations | 2026-08-30 17:49:00+00 |     59
 expire_reservations | 2026-08-30 17:48:00+00 |     56
 publish_outbox      | 2026-08-30 17:48:00+00 |     57
```

**El mecanismo no es una elección de líder.** Ese es el error conceptual más
común acá (y lo dice mal más de un blog). Lo que hay es un **índice único sobre
`(task_key, run_at)`**:

```ruby
# db/queue_schema.rb
t.index ["task_key", "run_at"],
        name: "index_solid_queue_recurring_executions_on_task_key_and_run_at",
        unique: true
```

Todos los schedulers de todas las instancias intentan encolar la corrida de las
17:49. El primero que llega inserta; los demás reciben una violación de unicidad
que la gema traduce a `RecurringExecution::AlreadyRecorded` y descartan
silenciosamente:

```ruby
# solid_queue-1.7.0/app/models/solid_queue/recurring_task.rb:98
rescue RecurringExecution::AlreadyRecorded
  payload[:skipped] = true
  false
```

Es mejor que un líder: no hay lease que renovar, no hay split-brain, no hay
ventana en la que nadie es líder. La base decide, y decide una sola vez.

Un detalle de este repo, porque es el mismo error contado desde adentro:
`config/recurring.yml` decía "Solid Queue usa un lock para elegir el líder".
Era falso y estaba en un comentario que la gente lee como documentación. Hoy el
archivo explica el índice único sobre `(task_key, run_at)` y la
`RecurringExecution::AlreadyRecorded`. Un comentario equivocado envejece peor
que código equivocado: nadie lo testea.

Comparalo con `crontab` en 10 máquinas: el job corre 10 veces. Es el bug de
producción clásico y carísimo ("mandamos el mail 10 veces", "cobramos 10
veces"). En Java lo resolvés con Quartz + `JDBCJobStore` + `isClustered=true`,
que **sí** usa locks de fila y un `SCHED_NAME` compartido — más piezas, mismo
resultado.

Dos cosas más que hay que saber:

- **Zona horaria**: `every day at 3am` se interpreta en `Time.zone` de la app.
  Si la app está en UTC y el negocio en Buenos Aires, "3am" es medianoche allá.
- **Si el scheduler estuvo caído**, la corrida se pierde: no hay catch-up. Solid
  Queue no reproduce ticks perdidos. Si necesitás garantía de "corrió al menos
  una vez por día", el job tiene que ser capaz de detectar y cubrir el hueco
  (mirando la última corrida), no confiar en el scheduler.

### 3.7 Prioridad de colas — y el gotcha del `*`

En Solid Queue hay **dos** mecanismos de prioridad y no se llevan bien:

1. **Orden de la lista de colas**: `queues: [critical, default]` vacía `critical`
   entera antes de mirar `default`. Prioridad estricta.
2. **`priority` numérica del job**: dentro de una cola, menor número = más
   prioridad (al revés que Sidekiq). Default 0.

La documentación de la gema recomienda usar uno u otro, no los dos.

Ahora el detalle que muerde. `config/queue.yml` declara:

```yaml
- queues: [ default, mailers, maintenance, "*" ]
```

Cuando `*` está en la lista y no hay colas pausadas, el selector colapsa todo a
**una sola query sin filtro**:

```console
$ bin/rails runner 'puts SolidQueue::QueueSelector.new(["default","mailers","maintenance","*"], SolidQueue::ReadyExecution).scoped_relations.map(&:to_sql)'
SELECT "solid_queue_ready_executions".* FROM "solid_queue_ready_executions"
```

Es decir: **el orden `default, mailers, maintenance` no hace nada**. Se ordena
sólo por `priority ASC, job_id ASC`. Si querés prioridad real entre esas colas,
sacá el `*` y listá las colas explícitamente (asumiendo el riesgo de que una
cola nueva no la atienda nadie), o usá `priority` numérica.

El comentario de `config/queue.yml` afirmaba lo contrario —"el orden del array
ES la prioridad: primero default, después mailers, después maintenance"— hasta
que se verificó con el `QueueSelector` de arriba. Ahora el mismo comentario
marca la excepción del comodín, que es la que aplica en esta config.

Y ojo con el peor caso combinado: si alguien pausa una cola desde Mission
Control, `all?` deja de ser verdadero, el selector cae al camino de
`all_queues` (un `SELECT DISTINCT queue_name`) y el comportamiento de orden
cambia sin que hayas tocado nada.

---

## 4. Sidekiq

La gema está en el `Gemfile` (`sidekiq ~> 8.0`, resuelta a 8.1.7) a propósito:
para poder correr **los mismos jobs** sobre el otro backend cambiando una env
var. Va declarada con `require: false`, así que no se carga en los procesos que
no la usan —web, workers de Solid Queue, consola, rake—; el `require "sidekiq"`
lo hace el initializer y sólo si `QUEUE_ADAPTER=sidekiq`
(`config/initializers/sidekiq.rb:35`). Tener la gema cargada en todos lados
"por las dudas" es RAM y tiempo de boot regalados en cada proceso.

### 4.1 BRPOP: por qué la latencia es otra liga

Sidekiq guarda cada cola como una **lista de Redis** (`queue:critical`) y el
worker se bloquea sobre ella:

```ruby
# sidekiq-8.1.7/lib/sidekiq/fetch.rb:48
queue, job = redis { |conn| conn.blocking_call(TIMEOUT, "brpop", *qs, TIMEOUT) }
```

`BRPOP` es *blocking right pop*: el cliente queda esperando dentro de Redis y
Redis lo despierta apenas hay un elemento. No hay polling, no hay intervalo. La
latencia de encolado a ejecución es la de un round trip de red: ~1 ms. El
`TIMEOUT = 2` no es polling, es sólo para que el thread pueda chequear si el
proceso está haciendo shutdown.

Ese es el argumento fuerte de Sidekiq y no lo podés replicar en Postgres:
`LISTEN/NOTIFY` se le acerca (es lo que usa GoodJob), pero `NOTIFY` no es
durable ni se entrega a un cliente que estaba desconectado, así que igual
necesitás polling de respaldo.

### 4.2 Pesos de cola: prioridad sin starvation

```yaml
# config/sidekiq.yml
:queues:
  - [ critical, 6 ]
  - [ outbox, 4 ]
  - [ default, 2 ]
  - [ mailers, 2 ]
  - [ maintenance, 1 ]
```

La implementación es sorprendentemente simple: el nombre de la cola se repite
`weight` veces en un array, y antes de **cada** `BRPOP` el array se mezcla y se
deduplica:

```ruby
# sidekiq-8.1.7/lib/sidekiq/capsule.rb:67
[weight.to_i, 1].max.times do
  memo << name
end

# sidekiq-8.1.7/lib/sidekiq/fetch.rb:79
def queues_cmd
  if @strictly_ordered_queues
    @queues
  else
    permute = @queues.shuffle
    permute.uniq!
    permute
  end
end
```

`BRPOP` con varias claves devuelve la primera que tenga datos, así que el orden
del array tras el shuffle es la prioridad de ese poll. Con peso 6 vs 1,
`critical` tiene 6 veces más chances de quedar primera — pero `maintenance`
**siempre** tiene una chance no nula. Eso es prioridad ponderada y evita el
starvation.

Si en vez de pares ponés nombres pelados (`- critical` / `- default`), el modo
pasa a `:strict` y Sidekiq vacía `critical` entera antes de mirar `default`.
Prioridad estricta = starvation garantizada si `critical` se llena.

### 4.3 Durabilidad: la parte incómoda

Dos capas de riesgo, y hay que separarlas.

**Capa 1 — Redis.** Con la config por defecto, Redis persiste con RDB
(snapshots periódicos): si el proceso muere, perdés todo lo escrito desde el
último snapshot. Con `appendonly yes` + `appendfsync everysec` perdés como
máximo 1 segundo; con `appendfsync always` no perdés nada pero el throughput de
escritura se desploma. Postgres te da la durabilidad de `appendfsync always`
por default. **Si comparás "Sidekiq vs Solid Queue" en durabilidad sin
mencionar la config de AOF, la comparación no significa nada.**

**Capa 2 — el fetch.** Esta es la que casi nadie menciona y es peor:

```ruby
# sidekiq-8.1.7/lib/sidekiq/fetch.rb
UnitOfWork = Struct.new(:queue, :job, :config) {
  def acknowledge
    # nothing to do
  end
```

`BRPOP` **saca** el job de la lista. El `acknowledge` de `BasicFetch` (el fetch
de Sidekiq OSS) es un no-op: no hay ack. Si el proceso muere de golpe
(`SIGKILL`, OOM killer, se cae la instancia) mientras un job está corriendo,
ese job **no está en ningún lado**: se perdió. `bulk_requeue` sólo cubre el
shutdown **ordenado** (`SIGTERM` con timeout).

Sidekiq Pro resuelve esto con `super_fetch` (usa `RPOPLPUSH` a una lista
privada por proceso y la recupera al arrancar). Solid Queue lo resuelve gratis y
sin ack explícito: el job sigue siendo una fila en `claimed_executions` con su
`process_id`, así que **existe en la base pase lo que pase**. Cuando se vence el
heartbeat, el supervisor lo pasa a `failed_executions` con `ProcessPrunedError`
(§3.2). No es reintento automático —eso sólo pasa en una baja ordenada— pero es
la diferencia entre "está acá, decidí qué hacer" y "no está en ningún lado".

### 4.4 Reintentos y Dead set

Sidekiq tiene su propio motor de reintentos, **independiente** del de Active
Job. Con `QUEUE_ADAPTER=sidekiq` tenés las dos capas apiladas:

```text
excepción en perform
   │
   ├── ¿hay retry_on para esa clase? → Active Job re-encola un job NUEVO
   │                                    (backoff de Rails, §7)
   └── si no la maneja, la excepción sube a Sidekiq
                                      → Sidekiq re-encola el MISMO job
                                        (backoff de Sidekiq, hasta :max_retries)
```

El backoff de Sidekiq 8:

```ruby
# sidekiq-8.1.7/lib/sidekiq/job_retry.rb:238  (delay_for)
delay = (count**4) + 15

# sidekiq-8.1.7/lib/sidekiq/job_retry.rb:202  (attempt_retry)
jitter = rand(10 * (count + 1))
retry_at = Time.now.to_f + delay + jitter
```

`count` arranca en **0** para el primer reintento (`msg["retry_count"] = 0`), así
que la primera espera es `0⁴ + 15` = 15 s, no 16.

Sumando las esperas: con `:max_retries: 10` (nuestro `config/sidekiq.yml`) los
10 reintentos son `15 + 16 + 31 + 96 + 271 + 640 + 1311 + 2416 + 4111 + 6576`
= **15.483 s ≈ 4,3 horas** desde el primer fallo hasta el último reintento (más
el jitter, ~275 s promedio). Con el default de 25 la ventana total es de
**~20 días** (1.763.395 s).

Agotados los reintentos, el job va al **Dead set**: un sorted set de Redis con
capacidad acotada (`dead_max_jobs: 10_000` y
`dead_timeout_in_seconds: 180 * 24 * 60 * 60`, o sea 180 días, en
`sidekiq-8.1.7/lib/sidekiq/config.rb:35`). Es la dead letter queue: lo
inspeccionás y lo reintentás a mano
desde el dashboard. Nuestro `death_handler` deja el registro estructurado:

```ruby
# config/initializers/sidekiq.rb:52
config.death_handlers << lambda do |job, exception|
  Rails.logger.error(event: "job.dead", job: job["class"], jid: job["jid"],
                     error: exception.message, args: job["args"])
end
```

⚠️ El Dead set **se poda**: pasados los 10.000 jobs o los 180 días, los más
viejos se borran. No es un archivo permanente. Si un job muerto representa
dinero, el `death_handler` tiene que persistirlo en tu base, no confiar en
Redis.

El equivalente en Solid Queue es `solid_queue_failed_executions`, que **no se
poda sola**: crece hasta que la vacíes desde Mission Control o con una tarea de
limpieza. Trade-off invertido.

### 4.5 Threads, GVL y el pool de conexiones

```yaml
# config/sidekiq.yml
:concurrency: 5
```

Vale lo mismo para los `threads:` de `config/queue.yml`. Dos límites duros:

- **Cada thread necesita su propia conexión a Postgres.** `max_connections` del
  pool tiene que ser >= threads del worker, o vas a ver
  `ActiveRecord::ConnectionTimeoutError`. Y con multi-database (§9) son **4
  pools por proceso**, no uno. Ver `config/database.yml` y
  `docs/03-base-de-datos-y-activerecord.md`.
- **La GVL**: dos threads de Ruby no ejecutan bytecode Ruby en paralelo. Se
  solapan durante I/O (base, red, disco). Para jobs CPU-bound subir `threads`
  no acelera nada: necesitás `processes`. Esto no aplica en Java, donde los
  threads sí corren en paralelo real — es la diferencia que más desorienta a un
  javero dimensionando workers de Ruby. Desarrollado en
  `docs/06-concurrencia-transacciones-y-locking.md` §10.

---

## 5. Comparativa de backends

| | **Solid Queue** | **Sidekiq** (OSS) | **GoodJob** | **Que** | **SQS** |
|---|---|---|---|---|---|
| Store | Postgres (base aparte) | Redis | Postgres | Postgres | servicio AWS |
| Primitiva | polling + `SKIP LOCKED` | `BRPOP` | `LISTEN/NOTIFY` + polling + advisory locks | advisory locks de Postgres | long polling HTTP |
| Latencia típica | 0,1–1 s | ~1 ms | ~10 ms | ~10 ms | 10–100 ms |
| Throughput | miles/s | decenas de miles/s | miles/s | miles/s | ~ilimitado (con costo) |
| Durabilidad | ACID | según AOF/RDB + fetch sin ack | ACID | ACID | replicada, gestionada |
| Encolar dentro de tu transacción | sólo si comparte base (§9) | ❌ | ✅ | ✅ | ❌ |
| Recuperación de worker muerto | ✅ heartbeat, pero a `failed_executions` (§3.2) | ❌ (Pro sí) | ✅ | ✅ | ✅ (visibility timeout) |
| Cron integrado | ✅ `recurring.yml` | ❌ (Enterprise sí) | ✅ | ❌ | ✅ EventBridge |
| Concurrencia limitada | ✅ semáforos | ❌ (Enterprise sí) | ✅ | ❌ | ❌ |
| Dashboard | Mission Control | Sidekiq Web | propio | — | consola AWS |
| Infra extra | ninguna | Redis | ninguna | ninguna | cuenta AWS + IAM |
| Ordenamiento | por prioridad | por prioridad/peso | por prioridad | por prioridad | FIFO sólo en colas FIFO |

### Cómo decidir, concretamente

- **< ~10k jobs/min, latencia de segundos aceptable, no querés mantener Redis**
  → Solid Queue. Es el default de Rails 8 y el de este repo, y es la respuesta
  correcta para el 90% de las apps. Un job que "tarda hasta 1 segundo en
  arrancar" no le importa a nadie.
- **Latencia sub-100 ms percibida por el usuario, o > 50k jobs/min** → Sidekiq.
  Pagás Redis (otra pieza que monitorear, otro punto de falla) y configurás AOF.
  Si el trabajo es crítico, Sidekiq Pro por `super_fetch`.
- **Querés Postgres pero necesitás latencia baja** → GoodJob. El
  `LISTEN/NOTIFY` te saca el polling del camino feliz sin dejar de ser durable.
- **Postgres, mínimo overhead, cola simple** → Que. Advisory locks, muy chico,
  pero sin cron ni concurrencia limitada.
- **Fan-out entre servicios, retención larga, el consumidor NO es tu app**
  → SQS/SNS o Kafka. Acá ya no estás eligiendo un backend de Active Job: estás
  eligiendo un bus de mensajería, y ahí entra el outbox (§8).

Regla que sirve en entrevista: **si el productor y el consumidor son el mismo
deploy, querés una cola de jobs. Si son deploys distintos, querés un broker —
y para llegar al broker con garantías, un outbox.**

---

## 6. Las reglas de oro de los jobs

### 6.1 Pasá IDs, no objetos

```ruby
MiJob.perform_later(product)      # ❌
MiJob.perform_later(product.id)   # ✅
```

Active Job sabe serializar un modelo: lo convierte a un **GlobalID**
(`gid://stock/Product/42`) y al ejecutar hace el `find`. Suena cómodo y es una
trampa por tres razones:

1. **Estado viejo**: si mandás el objeto entero (con un serializer custom) el
   worker ve el estado del momento del encolado, no el actual.
2. **`ActiveJob::DeserializationError`**: si el registro se borró entre el
   encolado y la ejecución, el `find` falla **antes** de entrar a tu `perform`.
   No podés manejarlo adentro del job: la excepción ocurre en la deserialización
   de argumentos.
3. **Payload grande**: más bytes en la cola, más red, más base.

Con el id releés el estado actual y **vos** decidís qué hacer si no existe (que
casi siempre es "no hacer nada y salir bien", no "explotar").

Por eso `ApplicationJob` descarta explícitamente ese error:

```ruby
# app/jobs/application_job.rb:92
discard_on ActiveJob::DeserializationError do |job, error|
  Rails.logger.warn(event: "job.discarded", job: job.class.name,
                    reason: "registro inexistente", error: error.message)
end
```

Reintentar un `RecordNotFound` 25 veces no lo va a hacer aparecer.

En Java el problema es idéntico mandando entidades JPA por JMS: serializás un
grafo *detached*, el consumidor lo recibe desactualizado y encima arrastra
colecciones lazy que explotan con `LazyInitializationException`. Misma
conclusión, distinto síntoma.

### 6.2 Todo job es idempotente, sin excepción

Las colas garantizan **at-least-once**. Nunca exactly-once. El caso canónico:

```text
worker: ejecuta el job (manda el mail / descuenta stock)  ✅
worker: muere antes de marcar el job como terminado       💥
      · baja ordenada (SIGTERM) → el job vuelve a ready
      · SIGKILL/OOM             → el job va a failed_executions (§3.2)
alguien (otro worker, o vos desde Mission Control) lo corre de nuevo
                                                           ← mail duplicado
```

El camino cambia según cómo murió, pero **el resultado posible es el mismo**: la
segunda ejecución existe. Con Sidekiq es más directo todavía, porque el
reintento es automático siempre.

No hay forma de eliminar esa ventana sin una transacción distribuida entre tu
worker y el efecto externo. Lo que sí podés es hacer que la segunda ejecución
**no haga daño**. Las tres técnicas que usa este repo:

| Técnica | Dónde | Cómo |
|---|---|---|
| Índice único parcial sobre una clave de negocio | `stock_movements.idempotency_key` | el segundo `INSERT` viola el índice y devolvés el resultado original |
| SETNX con TTL como ventana de silencio | `app/jobs/stock/low_stock_alert_job.rb:22` | `Rails.cache.write(key, ..., unless_exist: true)` devuelve `false` si ya existía |
| Marca de estado en la fila | `OutboxEvent#published_at` | el `scope :pending` ya no la ve |

```ruby
# app/jobs/stock/low_stock_alert_job.rb:22
next unless Rails.cache.write(key, Time.current.to_i,
                              expires_in: SILENCE_WINDOW, unless_exist: true)
```

Ese `unless_exist: true` es un `SETNX`: un deduplicador atómico de una línea.
Y tiene su test:

```ruby
# spec/jobs/stock_jobs_spec.rb:73
it "DEDUPLICA: no vuelve a alertar del mismo item dentro de la ventana" do
  described_class.perform_now
  expect { described_class.perform_now }.not_to change(OutboxEvent, :count)
end
```

### 6.3 Payload chico y jobs cortos

- **Payload**: los argumentos van serializados en la cola. Mandar un CSV de 5 MB
  como argumento significa 5 MB en `solid_queue_jobs.arguments` (o en Redis),
  reescritos en cada reintento. Subí el archivo a storage y mandá la clave.
  Active Job además sólo serializa tipos soportados (numéricos, `String`,
  `Symbol`, `Date`/`Time`, `Hash`, `Array`, GlobalID); pasarle un objeto
  cualquiera tira `SerializationError` **al encolar**, que al menos falla
  temprano.
- **Duración**: un job de 40 minutos ocupa un thread 40 minutos, no se puede
  deployar sin cortarlo (el `SIGTERM` tiene timeout: `shutdown_timeout`, 25 s en
  este repo — §3.2) y si falla al minuto 39 repetís todo. Partilo: un job
  coordinador que encola N jobs chicos, o el patrón de auto-reencolado que usa
  el relay (§8.4).
- **`statement_timeout`**: este repo mata cualquier query de más de 15 s
  (`config/database.yml:53`). Un job que hace un `UPDATE` masivo se va a comer
  ese timeout. Es a propósito: te obliga a lotear.

---

## 7. Reintentos, backoff, jitter y poison messages

### 7.1 `retry_on` vs `discard_on`

```ruby
# app/jobs/application_job.rb:81
retry_on ActiveRecord::Deadlocked,               wait: :polynomially_longer, attempts: 5
retry_on ActiveRecord::LockWaitTimeout,          wait: :polynomially_longer, attempts: 5
retry_on ActiveRecord::ConnectionNotEstablished, wait: :polynomially_longer, attempts: 5

# ...y en :92
discard_on ActiveJob::DeserializationError do |job, error|
  Rails.logger.warn(event: "job.discarded", job: job.class.name,
                    reason: "registro inexistente", error: error.message)
end
```

La regla es simple de decir y difícil de aplicar: **`retry_on` para errores
transitorios, `discard_on` para errores permanentes.** Un deadlock, un timeout
de lock, una conexión caída: reintentar tiene sentido. Un `RecordNotFound`, un
`ArgumentError`, un JSON malformado: reintentar es tirar recursos y —peor—
llenar la cola de basura que desplaza al trabajo bueno.

Dos detalles finos:

- `attempts` **incluye la ejecución original**. `attempts: 5` = 1 intento + 4
  reintentos.
- El contador es **por llamada a `retry_on`**, no global. Los tres `retry_on` de
  arriba tienen contadores independientes: 5 deadlocks + 5 lock waits + 5
  connection errors. Si listás varias excepciones en **una** llamada
  (`retry_on A, B, attempts: 5`), comparten el contador.
- Si se agotan los `attempts` y no pasaste un bloque, la excepción **vuelve a
  subir** al adapter, que aplica *su* política (Dead set en Sidekiq,
  `failed_executions` en Solid Queue).

### 7.2 `:polynomially_longer` no es exponencial

Esto lo dice mal medio internet, y lo decía mal un comentario de este repo:
`app/jobs/application_job.rb` afirmaba "hace backoff exponencial". Hoy dice
"backoff POLINÓMICO, no exponencial" y trae la fórmula, que es la real de
Rails 8.1:

```ruby
# activejob-8.1.3.1/lib/active_job/exceptions.rb:177
delay = executions**4
delay_jitter = determine_jitter_for_delay(delay, jitter)   # Kernel.rand * delay * jitter
delay + delay_jitter + 2
```

Es **polinómica** (grado 4), no exponencial — Rails renombró la opción
justamente por eso (antes se llamaba `:exponentially_longer`). El comentario del
repo arrastraba el nombre viejo; ahora explica la fórmula, que es lo único que
no envejece.

| Intento | Base `n⁴ + 2` | Con jitter 15% |
|---|---|---|
| 1 | 3 s | 3,0 – 3,2 s |
| 2 | 18 s | 18 – 20,4 s |
| 3 | 83 s | 83 – 95 s |
| 4 | 258 s (4,3 min) | 258 – 296 s |
| 5 | 627 s (10,5 min) | 627 – 721 s |

Verificado:

```console
$ bin/rails runner 'puts ActiveJob::Base.retry_jitter'
0.15
```

### 7.3 Jitter y el thundering herd

Sin jitter, 1000 jobs que fallan por la misma caída reintentan **exactamente**
en el mismo milisegundo. El servicio se levanta, recibe 1000 requests
simultáneos y se cae de nuevo. Y otra vez. Es un ciclo que se auto-sostiene:
el *thundering herd*.

El jitter rompe la sincronización distribuyendo los reintentos en una ventana.
Rails aplica 15% del delay como **cota superior** (`Kernel.rand * delay *
jitter`, o sea entre 0 y 15%). Para un servicio externo frágil, 15% es poco:
subilo por job con `retry_on Net::ReadTimeout, jitter: 0.5, wait: 30.seconds`.

Nota práctica: el jitter no te salva si el problema es que 1000 jobs entraron
en la cola simultáneamente (un import). Ahí lo que necesitás es rate limiting o
`limits_concurrency` (§3.5), no backoff.

### 7.4 Cuántos reintentos

No hay número mágico, hay una pregunta: **¿cuánto tiempo tolera el negocio que
esto no pase?** De ahí sale el número.

- Un webhook a un socio que puede estar caído medio día → reintentos que sumen
  ~12–24 h. Con `:polynomially_longer` eso es `attempts: 13` a `14`, no 8: el
  polinomio arranca lentísimo y la ventana total se estira recién al final.
  Sumando `n⁴ + 2`:

  | `attempts` | Reintentos | Ventana total |
  |---|---|---|
  | 5 (nuestro default) | 4 | 6 min |
  | 8 | 7 | 1,3 h |
  | 10 | 9 | 4,3 h |
  | 12 | 11 | 11,1 h |
  | 14 | 13 | 24,8 h |
- Un job que toca la base propia → 3–5. Si a los 5 intentos tu propia base
  sigue mal, el problema no lo arregla la cola.
- Algo que el usuario está esperando → 1 o 2 y un mensaje de error. Reintentar
  10 minutos un pedido que el usuario abandonó es peor que fallar.

Y siempre: **cortá en algún lado**. `attempts: :unlimited` sobre un error
permanente es una bomba de tiempo.

### 7.5 Poison messages

Un *poison message* es un mensaje que hace fallar al consumidor **siempre**. Si
tu loop es "tomo el primero, si falla lo devuelvo a la cola", ese mensaje se
procesa infinitamente y **tapa la cola**: los buenos nunca se atienden.

El relay del outbox tiene las dos defensas necesarias. Primera, un `rescue` por
evento adentro del loop:

```ruby
# app/jobs/outbox/publish_pending_job.rb:44
events.each do |event|
  publisher.publish(event.to_message)
  event.mark_published!
  published += 1
rescue StandardError => e
  event.mark_failed!(e)
  failed += 1
  Rails.logger.error(event: "outbox.publish_failed", outbox_id: event.id,
                     event_type: event.event_type, error: e.message)
end
```

Un evento roto no frena a los demás del lote. Segunda, un techo de intentos que
lo saca del scope de trabajo:

```ruby
# app/models/outbox_event.rb
MAX_ATTEMPTS = 10
scope :stuck, -> { pending.where(attempts: MAX_ATTEMPTS..) }

def self.claim_batch(limit: 500)
  pending.where(attempts: ...MAX_ATTEMPTS)...
end
```

Pasados 10 intentos el evento deja de ser candidato. Queda `pending` para que lo
veas —de eso se trata `scope :stuck`— pero ya no consume ciclos. Es una dead
letter queue implementada con una columna. Los dos comportamientos tienen test:

```ruby
# spec/jobs/outbox_publish_pending_job_spec.rb:41 y :57
it "un evento que falla NO frena a los demás"
it "deja de intentar después de MAX_ATTEMPTS (no tapa la cola para siempre)"
```

**La alerta que importa** no es "hay eventos fallando", es `OutboxEvent.stuck.any?`.
Un evento stuck es trabajo perdido en silencio.

---

## 8. Transactional outbox

Este es el patrón central del proyecto y el que más rinde en una entrevista,
porque toca transacciones, sistemas distribuidos y diseño de datos a la vez.

### 8.1 El problema: dual write

Querés hacer dos cosas que tienen que pasar juntas: cambiar el estado en tu base
y contarle al mundo que cambió. No hay transacción distribuida entre Postgres y
un broker (XA existe, nadie lo usa, y Kafka no lo soporta).

```ruby
ActiveRecord::Base.transaction do
  stock_item.update!(quantity_on_hand: 40)
  Kafka.publish("stock.changed", ...)   # ❌ dual write
end
```

El timeline de fallas, que conviene saber recitar:

```text
t0  BEGIN
t1  UPDATE stock_items ...
t2  Kafka.publish(...)  ──┐
t3  COMMIT               │
                          │
   ¿Qué puede salir mal?  │
   ─────────────────────  │
   A) publish falla en t2 → hacés ROLLBACK. Pero el broker PUEDE haber
      recibido el mensaje y haberse caído antes de responder. No podés
      "des-publicar". → evento fantasma: avisaste algo que no pasó.
   B) COMMIT falla en t3 → ya publicaste. Mismo evento fantasma.
   C) el proceso muere entre t3 y t2 (si invertís el orden) → commiteaste
      el cambio y NUNCA publicaste. → evento perdido, y nadie se entera.
   D) el consumidor lee el evento en t2.5 y hace SELECT sobre tu base
      → todavía no commiteaste: lee el estado VIEJO. Race condition
      clásica y difícil de reproducir.
```

No hay orden de las dos operaciones que elimine todos los casos. Ese es el
punto: **el dual write no tiene solución dentro del dual write**.

### 8.2 La solución

Escribís el evento en una tabla **de tu propia base**, en la **misma
transacción** que el cambio de negocio. Commit atómico: o pasan las dos cosas o
ninguna. Después, un proceso aparte lee las filas sin publicar y las manda al
broker.

```text
  ┌─────────────── UNA transacción de Postgres ───────────────┐
  │  UPDATE stock_items SET quantity_on_hand = 40             │
  │  INSERT INTO stock_movements (...)                        │
  │  INSERT INTO outbox_events (event_id, payload, ...)       │
  └──────────────────────── COMMIT ───────────────────────────┘
                              │
                              │  (asincrónico, otro proceso)
                              ▼
              Outbox::PublishPendingJob (el "relay")
              SELECT ... WHERE published_at IS NULL
                   ORDER BY id LIMIT 200
                   FOR UPDATE SKIP LOCKED
                              │
                              ├── publisher.publish(event.to_message)
                              └── UPDATE outbox_events SET published_at = now()
                                            │
                                            ▼
                                  broker / webhook / log
```

En este repo la escritura está en `app/services/outbox/recorder.rb` y se invoca
**desde adentro** de la transacción del service:

```ruby
# app/services/stock/apply_movement.rb:61
def call
  transactional do
    ...
    item = lock_stock_item!
    movement = write_ledger_entry(item)
    publish_event(item, movement)     # <- Outbox::Recorder#record
    ...
  end
end
```

Y `transactional` es simplemente `ApplicationRecord.transaction { yield }`
(`app/services/application_service.rb:68`). No hay magia: el `INSERT` del evento
está en la misma transacción que el `UPDATE` del stock.

### 8.3 El esquema

```ruby
# db/migrate/20260830161100_create_outbox_events.rb
create_table :outbox_events do |t|
  t.uuid    :event_id, null: false, default: -> { "gen_random_uuid()" }
  t.string  :aggregate_type, null: false      # "StockItem"
  t.bigint  :aggregate_id,   null: false
  t.string  :event_type,     null: false      # "stock.receipt"
  t.integer :event_version,  null: false, default: 1
  t.jsonb   :payload,  null: false, default: {}
  t.jsonb   :metadata, null: false, default: {}
  t.datetime :occurred_at, null: false
  t.datetime :published_at
  t.integer  :attempts, null: false, default: 0
  t.text     :last_error
  t.datetime :created_at, null: false
end

add_index :outbox_events, :event_id, unique: true
add_index :outbox_events, :id, where: "published_at IS NULL",
          name: "index_outbox_events_unpublished"
add_index :outbox_events, [ :aggregate_type, :aggregate_id, :id ]
add_index :outbox_events, [ :event_type, :occurred_at ]
```

Cuatro decisiones que hay que poder justificar:

- **`event_id` UUID único**: es la clave de deduplicación del consumidor (§8.6).
  Lo genera Postgres con `gen_random_uuid()` (nativo desde PG 13, sin
  `pgcrypto`).
- **Índice parcial `WHERE published_at IS NULL`**: la cola de trabajo pendiente
  son decenas de filas aunque la tabla tenga 500 millones de eventos
  históricos. Es lo que hace que el relay sea O(pendientes) y no O(tabla).
  Medido en la base de desarrollo:

  ```
  $ psql -d stock_development -c "EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM outbox_events
      WHERE published_at IS NULL AND attempts < 10 ORDER BY id LIMIT 200 FOR UPDATE SKIP LOCKED"

   Limit  (cost=0.12..4.48 rows=1) (actual time=0.016..0.016 rows=0 loops=1)
     Buffers: shared hit=1
     ->  LockRows  (cost=0.12..4.48 rows=1) (actual time=0.015..0.015 rows=0 loops=1)
           ->  Index Scan using index_outbox_events_unpublished on outbox_events
                 Filter: ((published_at IS NULL) AND (attempts < 10))
                 Buffers: shared hit=1
   Execution Time: 0.062 ms
  ```

  Un `Index Scan` con **1 buffer** sobre una tabla con 126 eventos (todos
  publicados, así que el índice parcial está vacío), y sigue siendo 1 buffer con
  126 millones: el índice sólo contiene lo pendiente.
- **`(aggregate_type, aggregate_id, id)`**: reconstruir el stream de un agregado
  (debugging, event sourcing liviano, "¿qué le pasó a este item?").
- **`created_at` sin `updated_at`**: es un log. Lo único que se actualiza es
  `published_at`/`attempts`, y para eso no hace falta el timestamp genérico.

### 8.4 El relay

```ruby
# app/jobs/outbox/publish_pending_job.rb
class PublishPendingJob < ApplicationJob
  queue_as :outbox
  BATCH_SIZE = 200

  def perform(batch_size: BATCH_SIZE)
    published = 0; failed = 0

    OutboxEvent.transaction do
      events = OutboxEvent.claim_batch(limit: batch_size).to_a
      next if events.empty?
      events.each do |event|
        publisher.publish(event.to_message)
        event.mark_published!
        published += 1
      rescue StandardError => e
        event.mark_failed!(e)
        failed += 1
      end
    end

    self.class.perform_later(batch_size:) if published + failed >= batch_size
    { published:, failed: }
  end
end
```

**Backpressure y tamaño de lote.** El `LIMIT 200` no es una optimización, es
una defensa. Sin él, un pico de 2 millones de eventos intenta procesarse en una
pasada: se come la memoria del worker, mantiene una transacción abierta minutos
(bloqueando el `VACUUM` y con 2M de filas lockeadas) y si falla al final perdés
todo el trabajo. Con lotes chicos, cada transacción dura milisegundos.

Y como el lote es chico, hace falta un mecanismo para drenar rápido después de
un pico: si el lote se llenó, **el job se re-encola a sí mismo** en vez de
esperar al próximo tick del scheduler. Es un bucle con freno: procesa mientras
haya trabajo, y se apaga solo cuando el lote deja de llenarse. Testeado en los
dos sentidos (`spec/jobs/outbox_publish_pending_job_spec.rb:69` y `:76`).

**Cómo elegir `BATCH_SIZE`**: `tiempo_del_lote = batch_size × latencia_del_publish`.
Con un webhook de 50 ms y lote de 200, cada lote son 10 segundos — demasiado
para tener una transacción abierta. Con lotes de 20, 1 segundo. Con el
`LogAdapter` (default de este repo) el publish es microsegundos y 200 está
sobrado. **Dimensioná el lote por el tiempo de la transacción, no por la
cantidad de filas.**

### 8.5 El "empujoncito": bajar la latencia sin romper nada

El recurring task corre cada minuto. Un minuto de latencia para un evento de
stock es mucho, así que `Recorder` además encola el relay:

```ruby
# app/services/outbox/recorder.rb:46
def schedule_publish
  ActiveRecord.after_all_transactions_commit do
    next unless Rails.cache.write("outbox/publish_scheduled", 1,
                                  expires_in: 2.seconds, unless_exist: true)
    Outbox::PublishPendingJob.perform_later
  rescue StandardError => e
    Rails.logger.warn(event: "outbox.nudge_failed", error: e.message)
  end
end
```

Tres decisiones densas en cuatro líneas:

1. **`ActiveRecord.after_all_transactions_commit`** (Rails 7.2+) corre cuando
   commitea la transacción **más externa**. Un `after_commit` de modelo dentro
   de una transacción anidada se dispararía antes de que la de afuera termine, y
   encolarías un job para datos que todavía pueden hacer rollback. Es el
   equivalente exacto de `TransactionSynchronizationManager` +
   `afterCommit` en Spring, pero sin registrar nada a mano.
2. **El SETNX debouncea**: un import que escribe 500 eventos encola **un** job,
   no 500. Sin esto la cola se ahoga sola.
3. **El `rescue` se traga el error a propósito.** Si el encolado falla, no
   importa: el evento ya está commiteado en la base y el recurring task lo va a
   levantar en el próximo minuto. **Esa es la propiedad que define al outbox**:
   el estado durable ya está, todo lo demás es optimización de latencia.

### 8.6 At-least-once, exactly-once y deduplicación

**Exactly-once *delivery* no existe.** No es una limitación de implementación,
es un resultado teórico: con canales que pueden perder mensajes no podés
garantizar acuerdo (el problema de los dos generales). Cualquier producto que
diga "exactly-once" está haciendo una de dos cosas: at-least-once + dedup del
lado del consumidor, o transacciones dentro de su propio sistema (Kafka
transactions: exactly-once *processing* Kafka→Kafka, no hacia el mundo).

Dónde está la ventana en nuestro relay:

```text
publisher.publish(message)   ← el broker YA lo recibió
   ⚡ el proceso muere acá
event.mark_published!        ← nunca corrió
```

El evento sigue `pending`. El próximo relay lo publica de nuevo. **Salió dos
veces.** Es inevitable sin transacción distribuida, y por eso cada mensaje lleva
`event_id`:

```ruby
# app/models/outbox_event.rb:44
def to_message
  { event_id:, event_type:, event_version:,
    aggregate: { type: aggregate_type, id: aggregate_id },
    occurred_at: occurred_at.iso8601(3), data: payload, metadata: }
end
```

Corriendo de verdad:

```console
$ bin/rails runner 'ev = OutboxEvent.order(:id).last; puts ev.to_message.slice(:event_id, :event_type, :aggregate).inspect'
{:event_id=>"8933d61e-c304-45a2-a46a-c17de0ba7392", :event_type=>"stock.receipt", :aggregate=>{:type=>"StockItem", :id=>1}}
```

El contrato con el consumidor es: **guardá los `event_id` procesados y descartá
los repetidos.** Del lado de una app Rails, eso es una tabla
`processed_events(event_id uuid primary key, processed_at)` y un `INSERT` que,
si viola la PK, significa "ya lo vi". Del lado nuestro, es lo mismo que hacemos
para las requests HTTP con `idempotency_keys` (§11).

La frase para la entrevista: **"at-least-once delivery + idempotent processing"**.
Eso es lo que la gente quiere decir cuando dice exactly-once, y decirlo así
demuestra que entendés dónde está el límite.

### 8.7 Orden y particionado por `aggregate_id`

El relay hace `ORDER BY id`, así que dentro de un lote el orden de escritura se
respeta. **Pero con varios workers y `SKIP LOCKED` el orden global no está
garantizado**: el worker A puede tomar los eventos 1–200 y el worker B los
201–400, y B terminar antes. El consumidor puede ver el evento 250 antes que el
5.

¿Importa? Depende del evento. Para "stock bajo" no. Para
`stock.receipt` / `stock.issue` sobre **el mismo `stock_item`**, sí: si llegan
al revés, el consumidor reconstruye un saldo equivocado.

La solución es la misma que en Kafka: **particionar por clave**. Mismo
agregado → mismo worker → orden garantizado dentro del agregado.
`aggregate_id` es exactamente la *partition key*.

Cómo se implementa sobre SQL, sin cambiar el esquema:

```ruby
# Cada worker toma una partición fija: WORKER_INDEX de 0 a WORKERS-1.
def claim_partition(partition:, of:, limit: 200)
  OutboxEvent.pending
             .where(attempts: ...OutboxEvent::MAX_ATTEMPTS)
             .where("mod(aggregate_id, ?) = ?", of, partition)
             .order(:id)
             .limit(limit)
             .lock("FOR UPDATE SKIP LOCKED")
end
```

Con `of: 4` y cuatro workers (`partition: 0..3`), todos los eventos de un mismo
`aggregate_id` caen siempre en el mismo worker. Se procesan en orden de `id`, o
sea en orden de escritura. Trade-offs, que son los mismos que en Kafka:

- El paralelismo queda topeado por la cantidad de particiones.
- Un agregado muy caliente hace *hot partition*: una partición con todo el
  trabajo y tres ociosas.
- Cambiar la cantidad de particiones re-mapea todo y puede reordenar eventos en
  vuelo. Hay que drenar antes de reparticionar.

Cuándo **no** hacerlo: si tus eventos llevan estado completo en vez de deltas
(`quantity_on_hand: 40` en vez de `+10`), el consumidor puede quedarse con el
de `occurred_at` más reciente y descartar los viejos. Eso se llama
*last-write-wins* y te ahorra el particionado entero. Nuestro payload lleva las
dos cosas (`quantity` y `quantity_on_hand`), así que un consumidor puede elegir.

### 8.8 Outbox vs CDC (Debezium) vs saga

| | **Outbox (este repo)** | **CDC / Debezium** | **Saga** |
|---|---|---|---|
| Qué hace | vos escribís el evento explícitamente | lee el WAL de Postgres y emite los cambios de fila | coordina una transacción de negocio en N servicios con compensaciones |
| Acoplamiento al esquema | ninguno: el evento es un contrato aparte | total: si renombrás una columna, rompés a los consumidores | n/a |
| Semántica | evento de **dominio** (`stock.receipt`) | evento de **fila** (`UPDATE stock_items`) | comandos + eventos |
| Infra | una tabla + un job | Kafka Connect + slot de replicación + Zookeeper/KRaft | orquestador o coreografía |
| Resuelve el dual write | ✅ | ✅ | ❌ (asume que cada paso ya es atómico) |
| Costo operativo | bajo | alto | alto (código de compensación) |

La combinación **outbox + CDC** también existe y es lo mejor de los dos: escribís
la tabla outbox, y Debezium lee el WAL de *esa tabla* en vez de las de negocio.
Te da eventos de dominio sin necesidad de un relay que hace polling, y sin
acoplar el esquema. Es lo que recomienda el propio Debezium
(*Outbox Event Router*). Lo que ganás es latencia (~ms) y sacar carga de
lectura; lo que pagás es Kafka Connect.

**Saga es otra cosa y se confunde seguido.** El outbox resuelve "publicar un
hecho de forma confiable". La saga resuelve "hacer una operación que abarca
varios servicios sin transacción distribuida", partiéndola en pasos locales con
**compensaciones** (si el paso 3 falla, corrés el deshacer del 2 y el 1). Son
complementarios: cada paso de una saga típicamente publica su evento **con un
outbox**. En nuestro dominio, una transferencia entre depósitos que cruzara dos
servicios sería una saga; acá es una sola transacción local
(`app/services/stock/transfers/dispatch.rb`) y no hace falta.

---

## 9. Cuándo NO necesitás outbox

El outbox no es gratis: una tabla más, un job más, limpieza periódica, y todos
los consumidores obligados a deduplicar. Para "mandale un mail de bienvenida al
usuario" es sobreingeniería.

Para el 90% de los casos alcanza con **encolar después del commit**:

```ruby
class ApplicationJob < ActiveJob::Base
  self.enqueue_after_transaction_commit = true
end
```

Con eso, `perform_later` dentro de una transacción no encola hasta que el
`COMMIT` sea exitoso. Elimina los dos bugs más comunes de jobs: el job que
procesa datos que hicieron rollback, y el worker que levanta el job antes de que
Postgres commitee y no encuentra la fila.

**No reemplaza al outbox.** Si el proceso muere entre el `COMMIT` y el `enqueue`
—una ventana de microsegundos, pero real— el job se pierde y nadie se entera.
La línea es:

| Necesidad | Herramienta |
|---|---|
| "si se pierde, se pierde" (mail de bienvenida, cache warming) | `perform_later` a secas |
| "no puede correr sobre datos que hicieron rollback" | `enqueue_after_transaction_commit = true` |
| "no se puede perder nunca, y hay otro sistema esperándolo" | outbox |

### ⚠️ Dos trampas reales de este repo, y cómo se arreglaron

Las dos las encontró la verificación de esta misma documentación, con la app
corriendo. Estuvieron vivas acá y hoy están corregidas: lo que sigue es cómo se
veían, cómo se detectaron y dónde quedó el arreglo. El diff final es chico —una
línea que se borró y una que se agregó—; el procedimiento para llegar hasta
ellas es lo que hay que llevarse.

**(1) `config.active_job.enqueue_after_transaction_commit` fue REMOVIDA en
Rails 8.1.** `config/initializers/sidekiq.rb` tenía, al final del archivo:

```ruby
# ❌ como estaba: un no-op silencioso en Rails 8.1
Rails.application.config.active_job.enqueue_after_transaction_commit = :always
```

Eso funcionaba en Rails 7.2/8.0. En 8.1 no hace nada — y no avisa. Así se
detectó, leyendo el **valor efectivo** en vez del initializer:

```console
$ bin/rails runner 'puts ActiveJob::Base.enqueue_after_transaction_commit.inspect'
false
$ bin/rails runner 'puts ActiveJob.respond_to?(:enqueue_after_transaction_commit=)'
false
```

Del CHANGELOG de `activejob-8.1.3.1`:

> Remove support to set `ActiveJob::Base.enqueue_after_transaction_commit` to
> `:never`, `:always` and `:default`.
> Remove deprecated `Rails.application.config.active_job.enqueue_after_transaction_commit`.

Ahora es un `class_attribute` booleano **por job**, con default `false`
(`activejob-8.1.3.1/lib/active_job/enqueuing.rb:53`), así que se configura en
`ApplicationJob`, no en un initializer.

Y el no-op es deliberado, no un olvido. El railtie que copia `config.active_job.*`
a los accessors **excluye esta clave a propósito**:

```ruby
# activejob-8.1.3.1/lib/active_job/railtie.rb:60
options = options.except(
  :log_query_tags_around_perform,
  :custom_serializers,
  # This config can't be applied globally, so we need to remove otherwise
  # it will be applied to `ActiveJob::Base`.
  :enqueue_after_transaction_commit
)
```

Y el otro camino (`config.after_initialize`) sólo aplica la opción
`if ActiveJob.respond_to?(k)`, que acá da `false`. Por los dos lados la línea
del initializer se descartaba en silencio.

**El arreglo**: se borró la línea de `config/initializers/sidekiq.rb` y la
configuración pasó a la clase base de los jobs, que es el único lugar donde
Rails 8.1 la lee:

```ruby
# app/jobs/application_job.rb:65
self.enqueue_after_transaction_commit = true
```

Hoy el valor efectivo es el que corresponde: el global sigue en `false` —porque
esta opción no se puede aplicar globalmente— y el que manda es el de la clase:

```console
$ bin/rails runner 'puts ActiveJob::Base.enqueue_after_transaction_commit.inspect'
false
$ bin/rails runner 'puts ApplicationJob.enqueue_after_transaction_commit.inspect'
true
```

El comentario que quedó arriba de esa línea en `app/jobs/application_job.rb`
cuenta la trampa completa, para que a nadie se le ocurra volver a moverla a un
initializer. La lección general, que sobrevive al arreglo:
**una opción de configuración que "no toma" casi siempre es un problema de orden
de boot o de una API removida; verificalo leyendo el valor efectivo, no el
initializer.**

**(2) Con Solid Queue en una base separada, el enqueue NO es transaccional.**
Esta es la que más engaña, porque el argumento de venta de Solid Queue es
justamente "el `INSERT` del job va en tu transacción". Es cierto **sólo si
comparte base con tus datos**. Acá no:

```ruby
# config/initializers/active_job.rb:38
config.solid_queue.connects_to = { database: { writing: :queue } }
```

`stock_development_queue` es otra base, otra conexión, otra transacción. Y como
la trampa (1) dejaba el `enqueue_after_transaction_commit` en `false`, el
resultado era este. Se reproduce hoy poniendo el flag en `false` a mano, que es
exactamente cómo estaba el repo:

```console
$ bin/rails runner '
  ApplicationJob.enqueue_after_transaction_commit = false   # así estaba el repo
  before = SolidQueue::Job.count
  begin
    ActiveRecord::Base.transaction do
      Product.first.touch
      Outbox::PublishPendingJob.perform_later
      raise "boom"
    end
  rescue => e; puts "rollback por: #{e.message}"; end
  puts "antes=#{before} despues=#{SolidQueue::Job.count}"'

rollback por: boom
antes=670 despues=671    ← el job quedó encolado PESE al rollback
```

Con el repo como está hoy —sin tocar el flag, porque `ApplicationJob` ya lo trae
en `true`— el mismo script no encola nada:

```console
$ bin/rails runner '
  before = SolidQueue::Job.count
  begin
    ActiveRecord::Base.transaction do
      Product.first.touch
      Outbox::PublishPendingJob.perform_later
      raise "boom"
    end
  rescue => e; puts "rollback por: #{e.message}"; end
  puts "antes=#{before} despues=#{SolidQueue::Job.count}"'

rollback por: boom
antes=668 despues=668    ← el enqueue esperó al COMMIT, que nunca llegó
```

(Los absolutos varían con lo que haya en la base y con el worker corriendo; lo
que importa es el delta.) La corrección fue una línea en
`app/jobs/application_job.rb`; el diagnóstico —un script de 8 líneas que compara
el conteo antes y después de un rollback— es lo que vale, y es el que tenés que
saber escribir en una entrevista.

Moraleja: **"Solid Queue es transaccional" es cierto sólo con base compartida.**
Si separás bases (que es el default de Rails 8 y lo correcto para no
contaminar el `VACUUM` de la base de negocio), volvés a tener el mismo problema
que con Sidekiq, y `enqueue_after_transaction_commit` deja de ser opcional. Acá
dejó de serlo: lo activa `ApplicationJob` para todos los jobs del proyecto.

---

## 10. Priorización, starvation y pesos

Tres mecanismos, tres semánticas:

| Mecanismo | Backend | Semántica | Riesgo |
|---|---|---|---|
| Orden de la lista de colas | Solid Queue, Sidekiq `:strict` | estricta: vacía la primera antes de mirar la segunda | **starvation**: una cola cargada mata de hambre al resto |
| Pesos `[cola, N]` | Sidekiq | probabilística | ninguno grave; menos predecible |
| `priority` numérica del job | Solid Queue (menor = antes), Sidekiq (mayor = antes) | ordena dentro de la cola | invertida entre los dos backends: cuidado al migrar |

Lo que hace este repo: colas separadas por **latencia tolerable**, no por
importancia moral. `critical` con `polling_interval: 0.1` y proceso dedicado;
`outbox` con 0.5; el resto con 1 segundo. Eso es mejor que una sola cola con 5
niveles de prioridad, porque **el aislamiento de recursos es más fuerte que
cualquier orden**: un job de mantenimiento que tarda 10 minutos no puede ocupar
el thread de `critical` si no comparten proceso.

La regla: **una cola nueva se justifica por un SLA distinto o por aislamiento de
fallas, no por "es más importante".**

---

## 11. Idempotencia del consumidor

Ya vimos que del lado del productor la garantía es at-least-once. Del lado del
consumidor hay tres niveles, y este repo usa los tres:

**Nivel 1 — HTTP.** `idempotency_keys` cachea la **respuesta completa** de un
`POST`. El cliente manda `Idempotency-Key: abc`; el `INSERT` con
`UNIQUE (user_id, key)` decide: si ya está `completed`, devolvemos la respuesta
guardada sin reejecutar; si está `processing`, 409. El
`request_fingerprint` (SHA-256 del body) impide reusar la misma clave con otro
body. Ver `db/migrate/20260830161200_create_idempotency_keys.rb`.

**Nivel 2 — dominio.** `stock_movements.idempotency_key` con índice único
**parcial**:

```ruby
add_index :stock_movements, :idempotency_key,
          unique: true, where: "idempotency_key IS NOT NULL"
```

Parcial porque los movimientos internos no llevan clave y no tienen por qué
competir por el índice ni hacerlo crecer. Si el mismo movimiento entra dos
veces, el segundo `INSERT` viola el índice y el service devuelve el original
(`app/services/stock/apply_movement.rb`, `replayed_movement`).

**Nivel 3 — eventos.** `event_id` UUID único por evento (§8.6). Es el que
tienen que usar los consumidores externos.

Los tres comparten el mismo principio, que es el que hay que saber decir:
**la idempotencia se implementa con una restricción de unicidad en la base, no
con un `if ya_existe?`.** El `if` tiene una race condition entre el `SELECT` y
el `INSERT`; el índice único no la tiene, porque el que arbitra es Postgres.

---

## 12. Observabilidad de colas

Las dos métricas que hay que separar y que la gente mezcla:

- **Latencia de cola** (*queue latency*): `now - enqueued_at` del job más viejo
  esperando. Mide si tenés **suficientes workers**.
- **Latencia de ejecución** (*execution time*): cuánto tarda el `perform`. Mide
  si tus **jobs son lentos**.

Un p99 de ejecución de 3 s no es problema. Una latencia de cola de 3 s en
`critical` sí. Y al revés: si la latencia de cola crece pero la de ejecución
está igual, no optimices el job — agregá workers.

| Señal | Query / fuente | Alerta que sirve |
|---|---|---|
| Latencia de cola | `min(created_at)` de `solid_queue_ready_executions` | > 10× `polling_interval` de esa cola, 5 min sostenido |
| Profundidad | `count(*)` de `ready_executions` por cola | **la derivada**, no el valor: creciendo 5 min seguidos |
| Jobs fallados | `solid_queue_failed_executions` | cualquier fila nueva en `critical` u `outbox` |
| Workers vivos | `solid_queue_processes.last_heartbeat_at` | ninguno late hace > 2 min (el latido es cada 60 s: `process_heartbeat_interval`) |
| Jobs huérfanos por muerte abrupta | `failed_executions` con `ProcessPrunedError` | cualquier fila: son jobs que **nadie va a reintentar solo** (§3.2) |
| **Outbox atrasado** | `OutboxEvent.pending.count` | > 1000, o el más viejo con > 5 min |
| **Outbox stuck** | `OutboxEvent.stuck.count` | **> 0 siempre**: es trabajo perdido |
| Recurring tasks | `solid_queue_recurring_executions` | no hay fila para el último tick esperado |

Dos consejos que valen más que las métricas:

- **Alertá sobre la profundidad creciente, no sobre un umbral.** "Más de 1000
  jobs" es normal durante un import y catastrófico un martes a las 3 AM. La
  derivada distingue las dos cosas; el umbral no.
- **Loggeá estructurado y con duración.** `ApplicationJob` ya lo hace en un
  `around_perform` (`app/jobs/application_job.rb:97`): emite `job.start` y
  `job.finish` con `duration_ms`, `jid` y `queue`. Con eso armás los percentiles
  por clase de job sin instrumentar nada más. El mismo bloque hace
  `Current.reset` en el `ensure`: los jobs corren en threads reutilizados y sin
  eso el job siguiente hereda el contexto del anterior — el mismo bug que un
  `ThreadLocal` sin limpiar en un pool de Tomcat, salvo que acá el executor de
  Rails ya lo garantiza.

---

## 13. Correrlo localmente

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"

bin/dev          # foreman: web + tailwind + jobs (ver Procfile.dev)
bin/jobs         # sólo el worker de Solid Queue
```

`Procfile.dev`:

```text
web: bin/rails server
css: bin/rails tailwindcss:watch
jobs: bin/jobs
```

`bin/jobs` es cuatro líneas que cargan el entorno y arrancan
`SolidQueue::Cli`. Levanta supervisor + dispatcher + workers + scheduler según
`config/queue.yml` y `config/recurring.yml`.

Inspeccionar sin dashboard:

```bash
psql -d stock_development_queue -c \
  "SELECT kind, pid, last_heartbeat_at FROM solid_queue_processes"

psql -d stock_development_queue -c \
  "SELECT id, class_name, queue_name, scheduled_at, finished_at
     FROM solid_queue_jobs ORDER BY id DESC LIMIT 10"

psql -d stock_development_queue -c \
  "SELECT (SELECT count(*) FROM solid_queue_ready_executions)  AS ready,
          (SELECT count(*) FROM solid_queue_claimed_executions) AS claimed,
          (SELECT count(*) FROM solid_queue_failed_executions)  AS failed"
```

Forzar un job sin worker:

```bash
bin/rails runner 'puts Outbox::PublishPendingJob.perform_now.inspect'
# => {:published=>0, :failed=>0}
```

Ver el outbox de punta a punta:

```bash
bin/rails runner '
  item = StockItem.first
  Stock::Receive.call(product: item.product, warehouse: item.warehouse,
                      quantity: 3, user: User.first, unit_cost_cents: 1000)
  puts "pendientes=#{OutboxEvent.pending.count}"
  puts OutboxEvent.order(:id).last.to_message.inspect'
```

**El dashboard** está en `/jobs` (Mission Control). No es público: lo protege un
`constraints` con lambda que exige sesión de un usuario `admin?`
(`config/routes.rb:110`). El HTTP Basic que trae la gema está desactivado en
`config/initializers/mission_control.rb` **porque hay algo mejor arriba**; los
dos cambios van siempre juntos. Un `/jobs` o `/sidekiq` abierto expone
argumentos de jobs (ids, emails, montos) y permite re-ejecutar jobs a voluntad:
está en el top de hallazgos de bug bounty.

Probar el otro backend con el mismo código:

```bash
QUEUE_ADAPTER=sidekiq bin/rails s -p 3001
QUEUE_ADAPTER=sidekiq bundle exec sidekiq -C config/sidekiq.yml
```

Los specs de jobs:

```console
$ bundle exec rspec spec/jobs
18 examples, 0 failures
```

---

## Errores que ves en producción

**1. Jobs perdidos en silencio después de un deploy.**
*Síntoma*: nadie recibe los mails de ayer a la tarde; no hay ningún error en
ningún lado. *Causa*: `QUEUE_ADAPTER=async` (o la env var sin definir en una
máquina). El thread pool vive en memoria del proceso web. *Arreglo*: fijar
`QUEUE_ADAPTER` explícitamente en todos los entornos y alertar si
`ActiveJob::Base.queue_adapter` no es el esperado al bootear.

**2. `ActiveJob::DeserializationError` en ráfagas.**
*Síntoma*: pico de jobs descartados después de una limpieza de datos.
*Causa*: `perform_later(objeto)` en vez de `perform_later(objeto.id)`; el
registro se borró entre el encolado y la ejecución. *Arreglo*: pasar ids
siempre; el `discard_on` de `app/jobs/application_job.rb:92` evita que se
reintenten 25 veces, pero el bug es el argumento.

**3. El job corre sobre datos que hicieron rollback.**
*Síntoma*: "no encuentro la orden 1234" en el worker, o un mail que anuncia algo
que no pasó. *Causa*: `perform_later` dentro de una transacción, con el enqueue
yendo a Redis (Sidekiq) o a **otra base** (Solid Queue con base `queue`
separada — §9). *Arreglo*: `self.enqueue_after_transaction_commit = true` en
`ApplicationJob`. Y si el evento no se puede perder, outbox. **Este repo lo
tuvo**: la config estaba en un initializer, donde en Rails 8.1 es un no-op; hoy
está en `app/jobs/application_job.rb:65` y el rollback ya no deja jobs
encolados (§9).

**4. Una opción de config que "no toma".**
*Síntoma*: pusiste la línea en un initializer, el comportamiento no cambia y no
hay error. *Causa*: o corre después del `before_initialize` del engine (caso
Mission Control, ver `config/initializers/mission_control.rb`), o la opción fue
removida (caso `config.active_job.enqueue_after_transaction_commit` en Rails
8.1). *Arreglo*: leer el **valor efectivo** con `bin/rails runner`, no el
initializer. Y `bin/rails initializers` para ver el orden real. Los dos casos
son de este repo, y el segundo estuvo vivo: se encontró leyendo el valor
efectivo y se arregló moviendo la config a `ApplicationJob` (§9).

**5. La cola tapada por un poison message.**
*Síntoma*: la profundidad de la cola sube, el throughput es cero, el mismo
`job_id` aparece una y otra vez en los logs. *Causa*: un mensaje que falla
siempre y se reintenta sin techo. *Arreglo*: `rescue` por ítem dentro del lote +
contador de intentos con corte (`OutboxEvent::MAX_ATTEMPTS`), y alerta sobre
`OutboxEvent.stuck`.

**6. Thundering herd al recuperarse un servicio.**
*Síntoma*: el servicio externo se levanta, aguanta 3 segundos y se vuelve a
caer, en loop. *Causa*: backoff sin jitter: los N jobs reintentan en el mismo
instante. *Arreglo*: `wait: :polynomially_longer` (Rails ya mete 15% de jitter),
subir `jitter:` para servicios frágiles, y `limits_concurrency` para topear los
concurrentes.

**7. `PG::ConnectionBad: sorry, too many clients already` al escalar workers.**
*Síntoma*: aparece cuando agregás workers, no cuando agregás tráfico web.
*Causa*: cada proceso abre **un pool por base**. Con 4 bases (primary, cache,
queue, cable) × 5 threads × 3 procesos son 60 conexiones desde una sola máquina.
*Arreglo*: contar `procesos × threads × bases × máquinas` contra
`max_connections` de Postgres; PgBouncer en transaction pooling si no alcanza.
Ver `config/database.yml` y `docs/03-base-de-datos-y-activerecord.md`.

**8. El recurring task corre N veces.**
*Síntoma*: el reporte diario sale duplicado desde que escalaste a 3 instancias.
*Causa*: `crontab` en N máquinas, o un scheduler propio sin coordinación.
*Arreglo*: `config/recurring.yml` de Solid Queue, que lo resuelve con el índice
único `(task_key, run_at)`. Si tenés que quedarte con cron, el job mismo tiene
que ser idempotente por ventana temporal.

**9. La cola dedicada no procesa nada y no hay error.**
*Síntoma*: `queues: [ outbox ]` y la cola `outbox` no baja. *Causa*: el nombre
real de la cola tiene el prefijo de entorno (`development_outbox`,
`staging_outbox`) y el selector hace match exacto. *Arreglo*: revisar
`config.active_job.queue_name_prefix` y el `queue_name` efectivo con
`bin/rails runner 'puts MiJob.new.queue_name'`.

**10. La prioridad entre colas no se respeta.**
*Síntoma*: `mailers` se atiende antes que `default` pese al orden declarado.
*Causa*: hay un `"*"` en la lista, y eso colapsa todo a una query sin filtro
ordenada sólo por `priority, job_id`. *Arreglo*: o listás las colas sin `*` (y
aceptás que una cola nueva no la atienda nadie), o usás `priority` numérica.

**11. La tabla de jobs / outbox crece sin techo y las queries se degradan.**
*Síntoma*: el dashboard tarda, el `VACUUM` no da abasto, la tabla ocupa más que
los datos de negocio. *Causa*: nadie borra los jobs terminados ni los eventos
publicados. *Arreglo*: `Cleanup::ExpiredRecordsJob` borra en lotes de 5.000 con
`in_batches` + `delete_all` (transacciones cortas, el autovacuum al día). A
escala real: particionar por fecha y hacer `DROP PARTITION`, que es instantáneo
y no genera tuplas muertas.

**12. Un job de 40 minutos que nunca termina de deployar.**
*Síntoma*: los deploys tardan o matan trabajo a la mitad. *Causa*: jobs largos +
timeout de `SIGTERM` (`shutdown_timeout`, 5 s por default en Solid Queue).
*Arreglo*: partir en lotes con auto-reencolado, como `Outbox::PublishPendingJob`
cuando llena el lote, y subir `shutdown_timeout` —acá 25 s en
`config/initializers/solid_queue.rb`— a un valor menor que el grace period del
orquestador (§3.2).

---

## Cómo responder esto en una entrevista

**"¿Qué es Active Job y qué diferencia hay con Sidekiq?"**
Active Job es una fachada —una SPI, el equivalente de JMS— que define el
contrato (`perform_later`, `retry_on`, serialización) y delega en un adapter.
Sidekiq es una implementación concreta sobre Redis. Escribís el job una vez y
cambiás el backend con una variable de entorno. *El trade-off*: Active Job
expone el mínimo común denominador, así que features propias de Sidekiq
(batches, unique jobs, rate limiting) no están; para usarlas heredás de
`Sidekiq::Job` y perdés la portabilidad.

**"Solid Queue vs Sidekiq: ¿cuál elegís?"**
Por defecto Solid Queue: los jobs son filas en Postgres, tenés durabilidad ACID
sin infraestructura extra, dashboard, cron y concurrencia limitada incluidos.
Sidekiq si necesitás latencia de milisegundos (usa `BRPOP` bloqueante contra el
polling de Solid Queue) o decenas de miles de jobs por segundo. *El trade-off*:
Sidekiq te suma Redis —otra pieza que monitorear, y por default no es durable—
y en la versión OSS el fetch no tiene ack, así que un `SIGKILL` con un job en
vuelo lo pierde y no queda rastro. En Solid Queue ese job es una fila en
`claimed_executions`: cuando se vence el heartbeat el supervisor la mueve a
`failed_executions` con `ProcessPrunedError`. Es el matiz que separa una
respuesta buena de una repetida de memoria: **no es reintento automático, es
"no se pierde y lo ves"** — el reintento automático sólo ocurre en la baja
ordenada. Umbral práctico: por debajo de ~10k jobs/min, Solid Queue y te
ahorrás medio stack.

**"Explicame `FOR UPDATE SKIP LOCKED`."**
`FOR UPDATE` toma lock exclusivo de las filas que devuelve el `SELECT`;
`SKIP LOCKED` hace que, en vez de esperar una fila ya bloqueada, la saltee. El
resultado es que N workers corren la misma query en paralelo y cada uno se lleva
un conjunto disjunto, sin coordinación externa, sin deadlocks y sin esperas. Es
la primitiva sobre la que están hechos Solid Queue, GoodJob y Que, y es la que
usamos en `OutboxEvent.claim_batch`. *El trade-off*: el lock dura toda la
transacción, así que los lotes tienen que ser chicos o bloqueás filas y frenás
el `VACUUM`.

**"¿Cómo garantizás que un evento no se pierda entre tu base y Kafka?"**
Con un transactional outbox. El problema es el dual write: no hay transacción
distribuida entre Postgres y el broker, así que cualquier orden de "commit y
publicar" tiene una ventana donde publicás algo que hizo rollback o commiteás
algo que nunca publicaste. La solución es escribir el evento en una tabla de mi
propia base, **en la misma transacción** que el cambio de negocio, y que un
relay aparte lea lo no publicado y lo mande. *El trade-off*: la garantía es
at-least-once —si el relay muere entre publicar y marcar, el evento sale dos
veces— así que cada evento lleva un `event_id` UUID y el consumidor **tiene**
que deduplicar. Y agregás latencia (lo que tarde el relay) y una tabla que hay
que limpiar.

**"¿Existe exactly-once?"**
Exactly-once *delivery* no existe: es el problema de los dos generales. Lo que
existe y es lo que la gente quiere decir es **at-least-once delivery +
idempotent processing**: entregás al menos una vez y el consumidor descarta lo
repetido por una clave estable. Kafka ofrece exactly-once *processing* dentro de
Kafka (transacciones consumer→producer), no hacia sistemas externos. En la
práctica: dedup por `event_id` con una restricción de unicidad en la base, no
con un `if ya_existe?`, que tiene race condition.

**"¿Y si necesitás que los eventos lleguen en orden?"**
Con varios workers y `SKIP LOCKED` no hay orden global. Lo que sí podés
garantizar es orden **por agregado**, particionando: `mod(aggregate_id, N)` y un
worker fijo por partición. `aggregate_id` cumple el rol de la partition key de
Kafka. *El trade-off*: el paralelismo queda topeado por la cantidad de
particiones, un agregado caliente genera hot partition, y reparticionar exige
drenar primero. Alternativa que evita todo esto: mandar estado completo en vez
de deltas y que el consumidor haga last-write-wins por `occurred_at`.

**"¿Cuándo NO usarías outbox?"**
Cuando el evento se puede perder. Para "mandale un mail de bienvenida" alcanza
con `enqueue_after_transaction_commit = true`, que difiere el encolado hasta
después del `COMMIT` y elimina el caso "el job procesa datos que hicieron
rollback". Lo que no cubre es la muerte del proceso entre el commit y el
enqueue: microsegundos, pero existen. Saber dónde está esa línea es la respuesta
madura. Y un detalle que sorprende: si Solid Queue vive en una base separada
—el default de Rails 8— el enqueue **tampoco** es transaccional, así que
`enqueue_after_transaction_commit` deja de ser opcional también ahí.

**"¿Cómo evitás que un job roto tape la cola?"**
Tres cosas. `discard_on` para los errores permanentes (un `RecordNotFound` no se
arregla reintentando). Un techo de intentos con corte explícito: en nuestro
outbox, `attempts < MAX_ATTEMPTS` saca el evento del scope de trabajo y lo deja
visible en `scope :stuck`. Y un `rescue` **por ítem** dentro del lote, para que
un mensaje envenenado no arrastre a los otros 199. Sobre eso, la alerta correcta
no es "hay errores" sino "hay eventos stuck", que es trabajo perdido en
silencio.

**"¿Qué métricas mirás de una cola?"**
Latencia de cola y latencia de ejecución, separadas: la primera te dice si te
faltan workers, la segunda si tus jobs son lentos. Profundidad, pero alertando
sobre **la derivada** y no sobre un umbral fijo (mil jobs es normal en un import
y catastrófico un martes a las 3 AM). Heartbeat de los workers. Y, en un
sistema con outbox, el lag del outbox y la cantidad de eventos stuck.

---

## Para seguir

- `docs/01-arquitectura.md` — el flujo de una request y dónde encaja el
  `Recorder` en la transacción del service.
- `docs/06-concurrencia-transacciones-y-locking.md` — aislamiento, deadlocks,
  advisory locks, transacciones largas y el modelo de concurrencia de Ruby (la
  GVL, y por qué `threads:` no es lo mismo que `processes:`).
- `docs/03-base-de-datos-y-activerecord.md` — índices parciales, pool de
  conexiones y multi-database.
- `docs/05-solid-y-patrones.md` — por qué `Outbox::Publisher` y
  `Outbox::NullRecorder` son el ejemplo de DIP del proyecto.
- Los comentarios de `app/jobs/application_job.rb`,
  `app/services/outbox/recorder.rb`, `config/queue.yml`, `config/recurring.yml`,
  `config/initializers/solid_queue.rb` y
  `db/migrate/20260830161100_create_outbox_events.rb`: son la fuente de verdad,
  y este documento los amplía. Los de `application_job.rb`, `queue.yml` y
  `recurring.yml` documentan además las tres trampas que este repo tuvo vivas:
  la config global que no toma (§9), el `"*"` que anula el orden de colas (§3.7)
  y el "líder" que no existe (§3.6).
