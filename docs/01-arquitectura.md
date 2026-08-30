# Arquitectura del proyecto

Acá tenés el mapa mental completo: por dónde pasa una request desde el socket
hasta Postgres y de vuelta, qué hace cada carpeta de `app/` y por qué existe,
cómo está modelado el dominio de stock y con qué justificación, el patrón
proyección + ledger que sostiene todo, el contrato `Result` que reemplaza a las
excepciones, y una receta paso a paso para agregar una operación nueva.

Está escrito para vos, que venís de Spring + JPA/Hibernate. Cada vez que hay un
equivalente en Java lo marco y —más importante— marco **dónde la analogía se
rompe**, que es exactamente donde se equivoca la gente que llega desde Java.

Todo el código citado sale del repositorio real y todos los números que aparecen
se midieron corriendo la app. Si algo no te cierra, abrí el archivo: los
comentarios del código son la fuente de verdad y este documento los amplía.

---

## 1. El stack

| Pieza | Acá | Tu equivalente en Java |
|---|---|---|
| Lenguaje | Ruby 3.3.6 (`.ruby-version`) | Java 17/21 |
| Framework | Rails 8.1.3.1 (`Gemfile.lock`), `load_defaults 8.1` | Spring Boot |
| Servidor | Puma multi-thread (`config/puma.rb`: 3 threads, sin `workers`) | Tomcat / Undertow |
| ORM | Active Record | Hibernate / JPA |
| Base | PostgreSQL 16 | PostgreSQL |
| Dependencias | Bundler + `Gemfile.lock` | Maven + `pom.xml` |
| Colas | Active Job sobre Solid Queue (o Sidekiq) | JMS sobre ActiveMQ / Quartz |
| Autorización | Pundit (`app/policies/`) | Spring Security `@PreAuthorize` |
| Serialización | POROs (`app/serializers/`) | Jackson + DTOs |
| Rate limiting | Rack::Attack + `rate_limit` de Rails 8 | Bucket4j / filtro propio |
| Análisis estático | RuboCop + Brakeman | Checkstyle + SpotBugs |

---

## 2. El flujo de una request (síncrono)

```
   POST /api/v1/stock/issue
   Authorization: Bearer stk_…      Idempotency-Key: 5f3a…
                    │
                    v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ PUMA — pool de threads. NO es un thread por core como en la JVM: el GVL  │
 │ deja correr UN thread de Ruby por vez, pero lo LIBERA durante el I/O     │
 │ (SQL, red). Por eso multi-thread sirve igual en una app así.             │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ STACK RACK (= FilterChain de Spring Security, pero es TU código y lo     │
 │ podés reordenar). Extracto real de `bin/rails middleware` en dev:        │
 │                                                                          │
 │   ActionDispatch::HostAuthorization      <- anti DNS-rebinding           │
 │   ActionDispatch::Executor               <- abre/cierra el scope de app  │
 │   ActionDispatch::RequestId              <- X-Request-Id                 │
 │   ActionDispatch::RemoteIp               <- resuelve X-Forwarded-For     │
 │ ► Rack::Attack                           <- ACÁ SE CORTA EL ABUSO        │
 │   Rails::Rack::Logger / ShowExceptions / Reloader                        │
 │   ActionDispatch::Cookies                                                │
 │   ActionDispatch::Session::CookieStore                                   │
 │   ActionDispatch::Flash / ContentSecurityPolicy                          │
 │   Rack::Head / ConditionalGet / ETag / TempfileReaper                    │
 │   Rack::Attack        (otra vez — ver §2.2)                              │
 │   Bullet::Rack        (sólo dev/test: caza N+1)                          │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ ROUTER (config/routes.rb) — UN archivo declarativo, no anotaciones       │
 │ repartidas por 40 controllers -> Api::V1::StockOperationsController#issue│
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ CONTROLLER — Api::V1::StockOperationsController < BaseController         │
 │   before_action  authenticate_api_token! ; set_current_context (Current) │
 │                  require_scope!("stock:write")                           │
 │   rate_limit     capa 2: 600/min global + 120/min escrituras, por TOKEN  │
 │   around_action  with_idempotency                                        │
 │                    └─ ¿replay? devuelve la respuesta guardada y CORTA    │
 │   acción         authorize item, :issue?   -> Pundit                     │
 │                  Stock::Issue.call(...)    -> service                    │
 │   after_action   verify_pundit_usage       -> red de seguridad           │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ SERVICE — Stock::Issue -> Stock::ApplyMovement (el único que mueve stock)│
 │   BEGIN                                                                  │
 │    1. ¿idempotency_key ya usada? -> devuelve el movimiento original      │
 │    2. SELECT … FROM stock_items WHERE id = ? FOR UPDATE  (lock de FILA)  │
 │    3. valida invariantes contra el estado YA BLOQUEADO                   │
 │    4. UPDATE stock_items      (la PROYECCIÓN)                            │
 │    5. INSERT stock_movements  (el LEDGER, inmutable)                     │
 │    6. INSERT outbox_events    (el evento, MISMA transacción)             │
 │   COMMIT                                                                 │
 │   -> Result.success(movement) | Result.failure(:insufficient_stock, …)   │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ POSTGRES — última red: CHECK constraints, índices únicos parciales,      │
 │ columna generada `quantity_available`, FKs con ON DELETE RESTRICT.       │
 └──────────────────────────────┬───────────────────────────────────────────┘
                                v
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ VUELTA: render_result(result, serializer: StockMovementSerializer)       │
 │   ok?   -> { data: {...} }   201                                         │
 │   error -> ErrorSerializer,  status según el mapa STATUS_FOR             │
 │ (En la UI HTML el MISMO Result se traduce a redirect + flash: método     │
 │  `handle` en app/controllers/stock_items_controller.rb)                  │
 └──────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Dónde se rompe la analogía con Spring

| Vos esperás (Spring) | Lo que pasa acá |
|---|---|
| `@RequestMapping` en cada controller | Rutas centralizadas en `config/routes.rb`. Ventaja: `bin/rails routes` te da el contrato completo de un saque. |
| `FilterChain` armada por el framework | El stack Rack es **tuyo**: `config.middleware.insert_after` lo reordena (`config/application.rb:52`). |
| `DispatcherServlet` + `HandlerAdapter` | El router llama a `controller.dispatch(name, request, response)`. Por eso `dispatch` es un **nombre prohibido** para una acción: si definís `def dispatch`, pisás el motor y revientan *todas* las acciones del controller. Ver cómo se resuelve con `post :dispatch, action: :dispatch_transfer` en `config/routes.rb`. |
| DI por container (`@Autowired`) | No hay container. Las dependencias entran por argumentos con nombre y default: `event_recorder: Outbox::Recorder.new, clock: Time`. En los tests inyectás `Outbox::NullRecorder`. Es DIP sin framework. |
| `@ControllerAdvice` + `@ExceptionHandler` | `rescue_from` en `app/controllers/concerns/api/error_handling.rb`. **Trampa**: se evalúan en orden **inverso** al de declaración, así que `StandardError` va primero. |
| `RequestContextHolder` / `ThreadLocal` | `Current` (`app/models/current.rb`). La diferencia clave: Rails **garantiza el reset** al final de cada request y de cada job. Un `ThreadLocal` sucio en un pool de threads es una fuga de datos entre usuarios. |

### 2.2 El detalle raro: `Rack::Attack` aparece DOS veces

Corré `bin/rails middleware` y vas a ver `use Rack::Attack` dos veces. No es un
error tuyo:

1. `config/application.rb:52` lo inserta a propósito **después** de
   `ActionDispatch::RemoteIp`, para que `request.remote_ip` sea la IP real del
   cliente y no la del balanceador.
2. La gema lo registra sola: en su código (no en el repo,
   `$(bundle show rack-attack)/lib/rack/attack/railtie.rb`) hay un `initializer`
   que hace `app.middleware.use(Rack::Attack)` sin condición, y eso lo agrega al
   final del stack.

**No duplica los contadores.** `Rack::Attack#call` arranca con:

```ruby
return @app.call(env) if !self.class.enabled || env["rack.attack.called"]
env["rack.attack.called"] = true
```

La instancia de arriba marca el flag y la de abajo queda como un no-op. Lo que
**sí** ganás con el `insert_after` explícito es cortar el tráfico abusivo antes
de `Rails::Rack::Logger`, `Cookies`, `Session::CookieStore` y `Flash`. Si te
quedaras sólo con la que registra la gema, cada request bloqueada ya habría
pagado la decodificación de la cookie de sesión.

> Si tocás el orden, verificalo con `bin/rails middleware`. Es el único chequeo
> que vale: el stack se arma en boot y depende de cuándo corre cada initializer.

---

## 3. El flujo asincrónico: outbox → job → publisher

### 3.1 El problema (dual write)

Querés guardar en la base **y** publicar un evento, y no hay transacción
distribuida entre Postgres y el broker. Esto está mal y no tiene arreglo:

```ruby
ApplicationRecord.transaction do
  stock_item.update!(quantity_on_hand: 40)
  Kafka.publish("stock.changed", ...)   # ❌ dual write
end
```

Si el publish falla ya hiciste rollback, pero el broker quizá recibió el mensaje.
Si el commit falla después de publicar, publicaste un hecho que no pasó. Si el
proceso muere en el medio, perdiste el evento sin dejar rastro.

**Un `after_commit` de Active Record NO resuelve esto**: si el proceso muere
entre el COMMIT de Postgres y la ejecución del callback en Ruby, el callback
nunca corre. Lo mismo vale para `@TransactionalEventListener(AFTER_COMMIT)` de
Spring — la ventana existe igual. La diferencia entre los dos mundos es
cosmética.

### 3.2 El diagrama

```
 ── request síncrona ────────────────────────────────────────────────────
  Stock::ApplyMovement
    BEGIN
      UPDATE stock_items ; INSERT stock_movements
      INSERT outbox_events        <-- Outbox::Recorder#record, MISMA tx
    COMMIT                        <-- atómico: o van los tres o ninguno
       │
       │ ActiveRecord.after_all_transactions_commit   (Rails 7.2+)
       │   -> corre al commitear la transacción MÁS EXTERNA
       │   -> Rails.cache.write("outbox/publish_scheduled", unless_exist: true)
       │      = SETNX con TTL 2 s = DEBOUNCE
       │      500 eventos en un lote encolan UN job, no 500
       v
  Outbox::PublishPendingJob.perform_later          ("empujoncito")

 ── worker aparte ───────────────────────────────────────────────────────
  Outbox::PublishPendingJob       + cron cada minuto (config/recurring.yml)
    BEGIN
      SELECT … FROM outbox_events
        WHERE published_at IS NULL AND attempts < 10
        ORDER BY id LIMIT 200
        FOR UPDATE SKIP LOCKED    <-- N workers, lotes DISTINTOS, sin esperar
      por evento:  publish -> mark_published!
                   rescue  -> mark_failed! (attempts += 1) y SIGUE con el resto
    COMMIT
    si llenó el lote -> se re-encola solo (drena rápido tras un pico)

 ── salida: Outbox::Publisher.build   (lee ENV["OUTBOX_ADAPTER"]) ───────
   "log" (default) | "noop" (tests) | "webhook" (HMAC-SHA256 + timestamp)
```

Archivos: `app/services/outbox/recorder.rb:17` (escritura) y `:47` (el debounce),
`app/models/outbox_event.rb:27` (`claim_batch`),
`app/jobs/outbox/publish_pending_job.rb` (el relay),
`app/services/outbox/publisher.rb` (los adapters).

### 3.3 Lo que tenés que poder defender

- **`FOR UPDATE SKIP LOCKED` es LA primitiva de colas en SQL.** `FOR UPDATE`
  bloquea las filas elegidas; `SKIP LOCKED` hace que los otros workers, en vez de
  esperar, se salteen esas filas. Sin él la cola se serializa y agregar workers
  no escala nada. Es lo que usan Solid Queue, GoodJob y Que por debajo.
- **La garantía es at-least-once, no exactly-once.** Si el worker muere después
  de publicar y antes de `mark_published!`, el evento sale dos veces. Por eso cada
  evento lleva `event_id` (UUID) y el consumidor **tiene** que deduplicar.
  "Exactly-once delivery" no existe; lo que existe es *at-least-once delivery +
  idempotent processing*.
- **El orden global no está garantizado con varios workers.** Procesamos
  `ORDER BY id`, pero con `SKIP LOCKED` el worker A puede terminar el evento 5
  después que B el 6. Si necesitás orden *por agregado*, hay que particionar por
  `aggregate_id` — mismo rol que la partition key de Kafka.
- **Un mensaje envenenado no puede tapar la cola.** El `rescue` está *dentro* del
  `each`: un payload roto suma `attempts` y el lote sigue. `OutboxEvent.stuck` te
  lista los que llegaron a `MAX_ATTEMPTS = 10`.

### 3.4 Los jobs recurrentes

Declarados en `config/recurring.yml` — el "cron" que vive en la app y corre en
**una sola** instancia aunque tengas 10 servidores. Con `crontab` en 10 máquinas
el job corre 10 veces, y ése es un bug de producción carísimo.

| Job | Cuándo | Qué hace |
|---|---|---|
| `Stock::ExpireReservationsJob` | cada minuto | Libera reservas vencidas. Sin él, un carrito abandonado inmoviliza stock para siempre. |
| `Outbox::PublishPendingJob` | cada minuto | El relay del outbox. |
| `Stock::LowStockAlertJob` | cada hora | Alerta bajo punto de reorden, con dedup por cache (SETNX, ventana de 12 h) contra el *alert fatigue*. |
| `Stock::ReconcileBalancesJob` | 3 AM | Compara proyección vs ledger. **No corrige por defecto**: si hay drift hay un bug, y auto-corregirlo lo escondería. |
| `Cleanup::ExpiredRecordsJob` | 4 AM | Borra en lotes chicos claves de idempotencia, sesiones y eventos publicados. |

Las dos reglas de `app/jobs/application_job.rb` que van de memoria: **pasá IDs,
no objetos** (el job corre minutos después; el objeto serializado trae estado
viejo y si el registro se borró la deserialización explota *antes* de tu código —
el mismo problema que mandar entidades JPA por JMS) y **todo job tiene que ser
idempotente**, porque la entrega es at-least-once.

---

## 4. Qué hace cada carpeta de `app/` y por qué existe

| Carpeta | Responsabilidad | Devuelve | Análogo Java |
|---|---|---|---|
| `models/` | Persistencia + invariantes simples + lecturas del agregado | self / valores | `@Entity` |
| `services/` | **Casos de uso.** Una clase, un `call` | `Result` | `@Service` (Command) |
| `queries/` | Lecturas complejas y reportes | `ActiveRecord::Relation` | Repository con `@Query` |
| `policies/` | Autorización por recurso | booleano / `Scope` | `@PreAuthorize` |
| `serializers/` | Dominio → JSON | `Hash` | DTO + Jackson |
| `forms/` | Entrada compleja validada | `Result` | `@Valid` RequestDTO |
| `jobs/` | Trabajo diferido y reintentable | lo que quieras | `@JmsListener` / Quartz |
| `lib/` (`app/lib`) | Tipos base sin dependencias del framework | — | `common/` |
| `controllers/concerns/` | Comportamiento transversal de HTTP | — | `HandlerInterceptor` |

`app/lib` **es** un autoload path (aparece en
`ActiveSupport::Dependencies.autoload_paths`), igual que `app/services`,
`app/queries`, `app/policies`, `app/serializers`, `app/forms` y `app/jobs`. Los
subdirectorios de `app/` son raíces de autoload por convención —todos menos
`assets`, `javascript` y `views`, que Rails excluye—, así que no hay que declarar
nada. El `lib/` de la raíz también, vía
`config.autoload_lib(ignore: %w[assets tasks])`.

> `app/events/`, `app/services/catalog/` y `app/serializers/api/v1/` existen pero
> están **vacías**. Son andamios para crecer, no capas activas.

### 4.1 `models/` — flacos a propósito

Un modelo acá hace cuatro cosas: asociaciones, validaciones, scopes y lecturas
derivadas. **No** ejecuta casos de uso.

`app/models/stock_item.rb` es el ejemplo canónico: expone `available`,
`can_fulfil?`, `below_reorder_point?`, y dos escrituras deliberadamente tontas
(`apply_delta!`, `apply_reservation_delta!`) que no validan reglas de negocio ni
escriben el ledger. Eso lo hace el service, que además garantiza el lock.

**La diferencia grande con JPA, y es la que más confunde:** Active Record
implementa el patrón *Active Record* (el objeto sabe persistirse); JPA/Hibernate
implementa *Data Mapper* (un `EntityManager` separado gestiona la persistencia).

| En Hibernate asumís | Acá la realidad es |
|---|---|
| Hay una sesión de persistencia con entidades *managed* | **No existe.** Ni sesión, ni entidades detached, ni `merge()`. |
| Dirty checking diferido: el `flush` al final de la transacción arma el UPDATE | **No.** `save!` es un INSERT/UPDATE **inmediato**. Tres `save!` son tres UPDATE. |
| Lazy loading transparente dentro de la sesión | Tocar `product.category` dispara **una query en ese instante**. Por eso el N+1 es tan fácil de crear acá y por eso existen los scopes `with_associations`. |
| `LazyInitializationException` fuera de la sesión | No existe: la asociación se carga igual, aunque estés en una vista y sea carísimo. Es *peor*, porque se degrada en silencio en vez de romper. |
| El cache de primer nivel te ahorra queries repetidas | Hay un **query cache por request** con una trampa mortal (`app/models/sequence_counter.rb`): un `INSERT … RETURNING` ejecutado con `select_value` cuenta como SELECT y se **cachea**, así que `next_value` devuelve dos veces el mismo número. Por eso ahí hay un `connection.uncached { … }` explícito. |

Modelos que vale la pena leer enteros: `stock_movement.rb:47`
(`def readonly? = persisted?` — verificado: `update!` levanta
`ActiveRecord::ReadOnlyRecord`); `warehouse.rb:27` (`TRANSIT_CODE`);
`user.rb` (enum con backing de **string**, no de entero: con ordinales, reordenar
las claves cambia el significado de los datos históricos en silencio);
`concerns/discardable.rb` (soft delete **sin** `default_scope`, y el comentario
explica por qué); y `value_objects/money.rb` y `quantity.rb` (Value Objects con
`Data.define`, que es el `record` de Java 16+: inmutables, comparados por valor,
`==`/`hash` gratis; `Money` se niega a sumar USD con EUR y nunca usa `Float`).

### 4.2 `services/` — donde vive la lógica

Contrato (`app/services/application_service.rb`): `.call(...)` es la única
entrada pública, devuelve **siempre** un `Result`, y todo lo que escribe va
dentro de **una** transacción (`transactional`, línea 68).

```
Stock::Receive ────┐
Stock::Issue ──────┤
Stock::Adjust ─────┼──> Stock::ApplyMovement ──> UPDATE stock_items  (proyección)
Stock::CommitReservation ─┤                  ├─> INSERT stock_movements (ledger)
Purchasing::ReceiveOrder ─┤                  └─> Outbox::Recorder   (evento)
Stock::Transfers::Dispatch ┤
Stock::Transfers::Receive ─┘

Stock::Reserve            -> StockReservation + quantity_reserved
Stock::ReleaseReservation -> lo revierte (idempotente por diseño)
Stock::ExpireReservations -> N x ReleaseReservation, una tx POR reserva
```

`Stock::ApplyMovement` es **el único lugar del sistema que cambia una cantidad de
stock**. Eso es SRP en serio: una regla que aplique a toda operación de stock se
agrega en un archivo y la heredan todas.

Fijate lo finito que queda cada service específico: `app/services/stock/issue.rb`
son ~40 líneas y lo único propio que hace es validar que la cantidad sea positiva
y **poner el signo** (`quantity: -@quantity`). El cliente no debería tener que
pensar en signos: el signo es una decisión del dominio.

### 4.3 `queries/` — lecturas que no son del modelo

Un scope está bien para un filtro chico y reutilizable (`Product.active`). Una
consulta con 6 filtros opcionales, joins y agregaciones **no** va en el modelo:
lo infla, mezcla "qué es un producto" con "cómo busca productos la pantalla X" y
no se puede testear sin instanciar el modelo entero.

**Regla del contrato** (`app/queries/application_query.rb`): devolver `Relation`,
no `Array`. Un `to_a` fuerza la ejecución y mata la paginación y toda
optimización posterior. La cumplen `LowStock`, `Ledger` y `Search`. Las tres de
agregación (`Availability`, `Valuation`, `Reconciliation`) devuelven Hash o Array
a propósito: un `GROUP BY` + `pluck` ya colapsó las filas, no queda Relation que
encadenar. Si rompés la regla, que sea por eso y esté escrito.

| Query object | Para qué | El truco que enseña |
|---|---|---|
| `StockItems::Availability` | Disponible agregado por producto | Arregla un N+1 de **agregación** con `GROUP BY` + `pluck`. `includes` no lo arregla: evita el N+1 de carga, no el de `sum`. |
| `StockItems::LowStock` | Items bajo punto de reorden | El `WHERE` está escrito **idéntico** al predicado del índice parcial `index_stock_items_needing_reorder`, condición necesaria para que Postgres lo use. |
| `StockItems::Valuation` | Plata parada en el depósito | Cantidad × costo **en la base**, casteando a `NUMERIC` para no desbordar `int8`. Mismo razonamiento que `long` vs `BigDecimal`. |
| `StockItems::Reconciliation` | Proyección vs ledger | `LEFT JOIN` + `HAVING`. Active Record no tiene `right_joins`: se da vuelta la relación. |
| `StockMovements::Ledger` | El libro mayor filtrado | Paginación **keyset** con comparación de tuplas `(occurred_at, id) < (?, ?)` y cursor opaco en Base64. |
| `Products::Search` | Búsqueda con filtros | `sanitize_sql_like` (un `%` del usuario es un DoS barato), índice GIN trigram para el `ILIKE '%x%'`, y desempate por `id` en el `ORDER BY`. |

Sobre lo último, porque es el bug de paginación más común y el más difícil de
creer cuando lo reportan: si ordenás sólo por `name` y hay dos filas con el mismo
`name`, el orden entre ellas **no es estable** entre páginas. Ves un producto dos
veces o nunca. El desempate por PK lo arregla.

### 4.4 `policies/` — Pundit

Una clase por recurso, un método por acción: patrón Strategy. El controller no
sabe *cómo* se decide, sólo pregunta `authorize @stock_item`.

`app/policies/application_policy.rb` falla **cerrado**: `viewer?` es
`user&.active? && user.at_least?("viewer")`, así que sin usuario da `nil` → falsy
→ denegado. Y `Scope#resolve` devuelve `scope.none` por defecto: si te olvidás de
definir `resolve` en una policy concreta, no se filtra información de más.

La red de seguridad contra el agujero clásico ("agregué un endpoint y me olvidé
el chequeo de permisos") está en `app/controllers/api/v1/base_controller.rb:117`
(método `verify_pundit_usage`):

```ruby
after_action :verify_pundit_usage

def verify_pundit_usage
  action_name == "index" ? verify_policy_scoped : verify_authorized
rescue Pundit::AuthorizationNotPerformedError, Pundit::PolicyScopingNotPerformedError => e
  raise e if Rails.env.local?          # dev/test: explota, arreglalo ya
  Rails.logger.error(event: "security.authorization_missing", ...)
end
```

El comentario de arriba documenta por qué **no** se usa `only: %i[index]`: desde
Rails 7.1, un callback con `only:`/`except:` apuntando a una acción que no existe
en ese controller levanta `AbstractController::ActionNotFound`. Como
`StockOperationsController` y `ReportsController` heredan de esta base y no tienen
`index`, un `only: %i[index]` acá rompería **todas** sus acciones.

Precisión que conviene tener a mano: eso lo gobierna
`config.action_controller.raise_on_missing_callback_actions`, que el generador
pone en `true` en dev y test (`config/environments/development.rb:79` y
`test.rb:64`) pero cuyo default de la gema es `false`. O sea: en producción no
explota, el callback simplemente no matchea. Lo vas a ver en tu máquina y en CI,
que es donde querés verlo.

### 4.5 `serializers/` — el contrato de la API es código

`render json: product` serializa **todas** las columnas. El día que agregás
`internal_cost_notes`, se filtra sola: es una fuga de datos por omisión.

Los serializers son POROs: `.new(objeto).as_json → Hash`,
`.collection(array) → Array<Hash>`. Cero magia, y son la clase más fácil de
testear que existe. `app/serializers/error_serializer.rb` centraliza el formato de
error, que junto con `STATUS_FOR` **es** el contrato de errores de la API.

### 4.6 `forms/` — el DTO validado

Va cuando la entrada **no** se corresponde 1:1 con un modelo: varios modelos,
campos virtuales, un wizard. `app/forms/stock_transfer_form.rb` recibe
`source_warehouse_code`, `destination_warehouse_code` y un `sku` por línea
(claves naturales, lo que el cliente realmente tiene a mano) y arma la
transferencia con sus líneas. Dos detalles que valen la entrevista:

- `products_by_sku` hace **una** query para todos los SKUs. Buscarlos de a uno
  dentro del loop de validación es un N+1 dentro de un `valid?` — el N+1 más
  invisible que existe, porque nadie mira las queries de una validación.
- `persist!` usa `StockTransferLine.insert_all!`: un solo INSERT multi-fila. No
  corre validaciones ni callbacks, y por eso se valida a mano antes. Trade-off
  consciente, no atajo.

`ActiveModel::Model` hace que el form funcione con `form_with` igual que un
modelo, sin tener tabla. Duck typing puro.

### 4.7 `controllers/concerns/`

- **`Api::TokenAuthentication`** — Bearer token, sin cookies. Sin cookies **no hay
  CSRF**: el ataque funciona porque el browser adjunta la cookie sola, y un header
  `Authorization` no se adjunta solo. El token se busca por índice sobre el
  **digest** SHA-256, así que nunca se compara un secreto en Ruby y no hay timing
  attack posible.
- **`Api::Idempotency`** — idempotencia HTTP estilo Stripe (ver §10, fila 9).
- **`Api::ErrorHandling`** — `rescue_from` + el mapa `STATUS_FOR`
  (`app/controllers/concerns/api/error_handling.rb:38`) que traduce un
  `Result.error.code` a un status HTTP. Nunca devuelve `e.message` crudo de una
  excepción inesperada: los mensajes de Postgres filtran nombres de tablas y a
  veces datos.
- **`Authentication`** — sesión con cookie firmada para la UI HTML.

---

## 5. El modelo de dominio

```
   users ──< sessions
     │   ──< api_tokens (token_digest, scopes[])
     └──< stock_movements (user_id, ON DELETE SET NULL)

  categories ──< products ──< product_suppliers >── suppliers
    (árbol, path                │                        │
     materializado)             │                        v
                                │           purchase_orders ──< purchase_order_lines
                     ┌──────────┘             (reference PO-2026-000045)
                     v
   warehouses ──> stock_items ──< stock_movements    <-- LEDGER, append-only
    (code,          ▲          └─< stock_reservations   (held/committed/
     virtual)       │                                    released/expired)
   stock_transfers ─┘  (source → IN-TRANSIT → destination)
        └──< stock_transfer_lines

  ── infraestructura ──────────────────────────────────────────────
   outbox_events      (event_id UUID; published_at NULL = pendiente)
   idempotency_keys   (user_id + key UNIQUE; fingerprint del body)
   sequence_counters  (key PK string, value bigint) -> referencias correlativas
```

Estado de la base de desarrollo al momento de escribir esto, medido con
`bin/rails runner`: 15 productos, 4 depósitos (1 virtual: `IN-TRANSIT`),
48 `stock_items`, 106 movimientos, 126 eventos en el outbox. Los dos últimos
suben con cada corrida; los primeros salen del seed.

### 5.1 Qué es cada tabla

| Tabla | Qué es | Detalle que importa |
|---|---|---|
| `products` | El catálogo. SKU como clave natural | `citext` para el SKU (case-insensitive en la base, no en Ruby). Índice GIN trigram sobre `name`. `lock_version` → optimistic locking. |
| `warehouses` | Depósitos, `code` natural ("BA-01") | La bandera `virtual` es la que habilita el depósito de tránsito. |
| `stock_items` | **El agregado.** Un renglón por (producto, depósito) | `quantity_available` es columna **generada** (`quantity_on_hand - quantity_reserved`, `STORED`). Único sobre `(product_id, warehouse_id)`. Cinco CHECK constraints, entre ellos `quantity_on_hand >= 0` y `quantity_reserved <= quantity_on_hand`. |
| `stock_movements` | **El ledger.** Append-only, inmutable | `quantity` con **signo**. Sólo `created_at`, sin `updated_at`. Único **parcial** sobre `idempotency_key WHERE NOT NULL`. |
| `stock_reservations` | Stock apartado, con TTL | Toda reserva nace con `expires_at`. Índice parcial sobre `expires_at WHERE status = 'held'`. |
| `stock_transfers` (+ `_lines`) | Movimiento entre depósitos, en dos pasos | `transit_warehouse_id`; máquina de estados `draft → in_transit → received`, con `cancelled` como salida desde `draft`. |
| `purchase_orders` (+ `_lines`) | Compras a proveedor | La columna generada es `purchase_order_lines.subtotal_cents` (`quantity_ordered * unit_cost_cents`); el total de la cabecera lo recalcula un callback de la línea. Recepción parcial soportada. |
| `outbox_events` | Eventos pendientes de publicar | Índice parcial sobre `id WHERE published_at IS NULL`: la cola pendiente es chica aunque la tabla tenga 500 M de filas. |
| `idempotency_keys` | Deduplicación de POST | Único sobre `(user_id, key)`. Guarda `response_body` y un fingerprint del request. |
| `sequence_counters` | Referencias correlativas sin huecos | PK de tipo string. UPSERT con `RETURNING`. |
| `api_tokens` | Credenciales de la API | Sólo el digest SHA-256. Scopes en array con índice GIN. |
| `users` / `sessions` | Auth web | `role` como string + CHECK constraint. |

### 5.2 Las decisiones de modelado, con su justificación

**Por qué la cantidad no vive en `products`.** Porque no existe "la cantidad de un
producto": existe la cantidad **en un depósito**. Si ponés
`products.quantity_on_hand` (a) no podés responder "¿cuánto hay en Córdoba?", que
es la pregunta que hace el negocio todos los días; (b) convertís esa fila en un
**punto de contención global**, donde cada movimiento en cualquier depósito
bloquea la misma fila y toda la operación se serializa; y (c) no podés tener punto
de reorden, `bin_location` ni `last_counted_at` por depósito, que son datos
por-depósito por naturaleza.

**Por qué existe `stock_items`.** Es el **agregado** en el sentido de DDD: la
unidad de consistencia transaccional. Toda operación que cambia stock bloquea
**exactamente una** fila de esta tabla
(`app/services/stock/apply_movement.rb:102`). Eso te da las dos cosas a la vez:
serialización de las operaciones sobre el mismo par (producto, depósito) y
**paralelismo total** entre pares distintos — Postgres bloquea la fila y punto, no
hay *lock escalation* a nivel tabla como en SQL Server. El índice único
`(product_id, warehouse_id)` es la clave natural: sin él, dos POST concurrentes
crean dos `stock_items` para el mismo par y el stock queda partido en dos para
siempre.

**Por qué el ledger es inmutable.** Porque un ledger que se puede editar no es un
ledger. La idea viene de la contabilidad de partida doble:

```
stock_items.quantity_on_hand  = una PROYECCIÓN (un cache)
stock_movements               = la VERDAD (el hecho histórico)
```

Un ajuste de inventario **no** sobreescribe `quantity_on_hand`: registra un
movimiento `count_correction` con el delta (`app/services/stock/adjust.rb`). La
diferencia entre "setear un valor" y "registrar un hecho" es todo el punto: la
diferencia (merma, robo, error de picking) es justamente el dato que le interesa
al negocio, y sobreescribiendo lo perdés. Tres barreras en profundidad creciente:
`def readonly? = persisted?` en el modelo, la tabla sin `updated_at`, y los CHECK
constraints en la base que valen aunque entres por `psql`. La barrera definitiva
en producción sería revocarle el UPDATE al rol de la app.

**Por qué hay un depósito virtual `IN-TRANSIT`.** Porque una transferencia **no**
es "restar acá y sumar allá". La mercadería viaja: durante horas o días no está ni
en el origen ni en el destino. Si la modelás como un movimiento atómico, el
inventario físico nunca coincide con el sistema.

```
dispatch:  BA-01       --transfer_out(-10)-->  IN-TRANSIT
           IN-TRANSIT  --transfer_in (+10)-->                (queda 10)
receive:   IN-TRANSIT  --transfer_out(-9) -->  CB-01
           CB-01       --transfer_in (+9) -->                (llegaron 9)
           IN-TRANSIT  --scrap      (-1) -->                 (faltante imputado)
```

Cada par `transfer_out`/`transfer_in` suma cero, así que **mover** mercadería no
altera el `SUM(quantity)` global del ledger: lo único que lo baja es el `scrap`, y
ése es exactamente el asiento donde queda imputado el faltante (*shrinkage*), con
fecha, depósito y motivo. Sin el depósito intermedio esas unidades desaparecen sin
asiento y quedan como fantasmas para siempre. Es el modelo que usa cualquier WMS
serio; está en `app/services/stock/transfers/dispatch.rb` y `receive.rb`.

**Otras decisiones deliberadas.** *Desnormalización* de `product_id` y
`warehouse_id` en `stock_movements`: son derivables de `stock_item_id`, pero
copiarlos evita un JOIN en **todos** los reportes históricos, que son la lectura
más frecuente y pesada; el costo es mantenerlos consistentes, y lo hace
`denormalize_from_stock_item` (`app/models/stock_movement.rb:68`). *Asociación
polimórfica sin FK* (`reference_type` / `reference_id`): es la limitación
inherente del polimorfismo en SQL, no podés tener una FK a N tablas. *`ON DELETE
RESTRICT` en todo lo que es historia o catálogo (stock, movimientos, productos,
depósitos), `SET NULL` en `stock_movements.user_id` y
`stock_reservations.user_id`, y `CASCADE` sólo en lo accesorio que no tiene
sentido sin su padre (sesiones, `api_tokens`, `idempotency_keys`, las líneas de
orden y de transferencia)*: nunca borres historia contable en cascada. *Enums como string*: con enteros, reordenar las claves cambia el
significado de los datos históricos en silencio. *Columna generada en vez de
calcular en Ruby*: no se puede desincronizar, se puede **indexar**, y la ven todos
los clientes de la base. Es la `@Formula` de Hibernate, pero materializada.

---

## 6. El patrón proyección + ledger (CQRS pragmático)

### 6.1 La invariante

```
Para todo stock_item:
  stock_items.quantity_on_hand == COALESCE(SUM(stock_movements.quantity), 0)
```

Si se rompe, **hay un bug**: alguien escribió una cantidad sin pasar por
`Stock::ApplyMovement`.

¿Por qué no borrar la columna y hacer `SUM()` cada vez? Porque con millones de
movimientos el `SUM` se vuelve carísimo. Guardamos la proyección para leer O(1) y
el ledger para auditar y reconstruir. Es el trade-off de CQRS / event sourcing en
su versión pragmática: **un solo store, dos representaciones**, sin proyecciones
asincrónicas ni eventual consistency. La proyección se actualiza en la **misma
transacción** que el asiento, así que nunca hay ventana de inconsistencia.

### 6.2 Cómo se verifica

`app/queries/stock_items/reconciliation.rb:25` (método `call`):

```ruby
StockItem.left_joins(:stock_movements)
         .group("stock_items.id", "stock_items.quantity_on_hand")
         .having("stock_items.quantity_on_hand <> COALESCE(SUM(stock_movements.quantity), 0)")
```

El `LEFT JOIN` es deliberado: un `stock_item` **sin** movimientos aparece con
`SUM = NULL`, el `COALESCE` lo pasa a 0, y ése es justo el caso que más querés
detectar (una fila con cantidad y cero movimientos que la respalden).

Corrido contra la base de desarrollo ahora mismo:

```bash
$ bin/rails runner 'd = StockItems::Reconciliation.call; puts "drifts: #{d.size}"'
drifts: 0
```

```sql
SELECT (SELECT SUM(quantity)         FROM stock_movements) AS ledger_total,
       (SELECT SUM(quantity_on_hand) FROM stock_items)     AS proyeccion_total;

 ledger_total | proyeccion_total
--------------+------------------
         2295 |             2295
```

`Stock::ReconcileBalancesJob` corre esto a las 3 AM y **alerta sin corregir**.
`autofix: true` existe sólo para una corrida manual y deliberada, y deja su propio
movimiento `count_correction` en el ledger.

### 6.3 La trampa de la columna generada

Esto no lo sabe casi nadie y lo verifiqué contra la base:

```ruby
StockItem.readonly_attributes   # => []   ← ¡está VACÍO!

item = StockItem.find(1)
item.quantity_available = 12345   # se acepta en memoria, sin quejarse
item.save!
```

El SQL que sale es:

```sql
UPDATE "stock_items" SET "updated_at" = '…', "lock_version" = 11
WHERE "stock_items"."id" = 1 AND "stock_items"."lock_version" = 10
```

La columna generada **no aparece en el UPDATE**. No hay excepción ni warning: la
asignación se descarta en silencio y el objeto en memoria queda mintiendo hasta
que hagas `reload`.

Moraleja operativa: **después de tocar `quantity_on_hand` o `quantity_reserved`,
hacé `reload` para leer un `quantity_available` correcto.** Es exactamente lo que
hace `ApplyMovement#apply_to` (`app/services/stock/apply_movement.rb:132`). En
Hibernate el equivalente es `@Generated(GenerationTime.ALWAYS)`, que sí fuerza un
SELECT de refresco automático; acá tenés que pedirlo a mano.

---

## 7. El contrato `Result`

### 7.1 Por qué las reglas de negocio no usan excepciones

En Java tenés checked exceptions: la firma te dice qué puede fallar. En Ruby
**todas** las excepciones son unchecked y nada en la firma te avisa. Si usás una
excepción para "no hay stock suficiente", el que llama no tiene forma de saberlo
salvo leyendo la implementación, y un `rescue` sin tipo específico se come todo.

La regla del proyecto (`app/lib/result.rb`), y la que conviene defender:

| Tipo de falla | Mecanismo | Ejemplos |
|---|---|---|
| **Esperada** (regla de negocio) | `Result.failure` — es un **valor** | stock insuficiente, producto dado de baja, transición inválida, reserva vencida |
| **Inesperada** (bug o infraestructura) | Excepción. Que explote | la base se cayó, un `nil` donde no puede haber `nil` |

`Result` es inmutable (`freeze` en el constructor) y su `Error` es un
`Data.define(:code, :message, :details)` — el `record` de Java 16+. Compone con
`then_try`, que es el `flatMap` de `Optional`/`Either` y corta la cadena en el
primer failure, y se consume con pattern matching de Ruby 3:

```ruby
case Stock::Receive.call(...)
in { ok: true, value: }  then render json: value
in { ok: false, error: } then render json: error, status: :unprocessable_content
end
```

Eso funciona porque `Result` define `deconstruct_keys` (`app/lib/result.rb:88`) y
`deconstruct` (`:91`). A diferencia de `case/when`, si ningún patrón matchea
`case/in` levanta `NoMatchingPatternError` en vez de devolver `nil` callado — que
es exactamente lo que querés en una máquina de estados.

### 7.2 `transactional`: dónde se decide qué es qué

`app/services/application_service.rb:68`:

```ruby
def transactional
  ApplicationRecord.transaction { yield }
rescue BusinessRuleViolation        => e ; e.result
rescue ActiveRecord::RecordInvalid  => e ; Result.failure(:validation_failed, …)
rescue ActiveRecord::StaleObjectError    ; Result.failure(:conflict, …)   # → HTTP 409
rescue ActiveRecord::RecordNotUnique     ; Result.failure(:duplicate, …)
rescue ActiveRecord::LockWaitTimeout     ; Result.failure(:locked, …)
end
```

Todo lo demás sube y explota, como tiene que ser.

### 7.3 Por qué `fail!` usa una excepción interna y no `return`

Dos trampas de Rails, documentadas en `app/services/application_service.rb:46`:

1. Desde Rails 7, un `return` dentro de un bloque `transaction` **hace COMMIT** de
   lo que ya escribiste. Antes hacía rollback; el cambio rompió muchísimo código
   en silencio.
2. `raise ActiveRecord::Rollback` dentro de una transacción **anidada** sin
   `requires_new: true` se traga la excepción **sin** revertir la de afuera.

Con una excepción propia (`BusinessRuleViolation`) que viaja hasta el `rescue` de
`transactional`, el rollback está garantizado en los dos casos y afuera seguís
devolviendo un `Result`.

### 7.4 Por qué cada llamador hace `.tap { |r| fail!(...) if r.failure? }`

Es el detalle más sutil de toda la arquitectura, y lo verifiqué corriendo código.

Las transacciones anidadas de Active Record **sin `requires_new: true` no son
savepoints**: la interna se *une* a la externa. Entonces, cuando `Stock::Receive`
llama a `Stock::ApplyMovement`, el hijo levanta `BusinessRuleViolation`, su propio
`transactional` la **rescata** y devuelve `Result.failure`… y como el `rescue`
está fuera del bloque `transaction` pero la transacción es la misma que la del
padre, **lo que el hijo ya escribió NO se revierte**.

Comprobación (transacción externa revertida al final para no ensuciar la base):

```
reorder_quantity original = 25
el service interno devolvio: boom
en memoria dentro de la tx externa: 999
>>> la tx externa SIGUE VIVA y la escritura del inner NO se revirtio sola
despues del rollback externo: 25
```

Por eso **todos** los llamadores rematan con:

```ruby
ApplyMovement.call(...).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
```

Ese `fail!` re-lanza la excepción en el contexto del llamador, y **eso** es lo que
aborta la transacción compartida. No es ceremonia: es la línea que hace que el
rollback ocurra. Si la sacás, un `Stock::Transfers::Dispatch` con una línea que
falla te deja las líneas anteriores commiteadas.

En JPA el equivalente es `REQUIRED` vs `REQUIRES_NEW` y el *rollback-only flag*:
cuando un método `REQUIRED` marca la transacción, el commit de afuera tira
`UnexpectedRollbackException`. Rails no tiene ese flag por defecto: si vos
rescatás, la transacción sigue viva. Ahí es donde la analogía se rompe.

---

## 8. Cómo agregar una operación de negocio nueva

Receta concreta y verificable. Como ejemplo, **devolución de cliente**: el `kind`
`"return"` ya existe en el CHECK constraint de la migración y en
`StockMovement::KINDS` / `INBOUND`, pero **no hay service que lo emita**. Es el
hueco perfecto para practicar.

**1. Poné el nombre en el dominio, no en la UI.** `Stock::ReturnFromCustomer`, no
`Stock::AddStock`. Si el nombre necesita un "y" ("recibirYnotificar"), son dos
clases. El nombre del service **es** el caso de uso.

**2. Escribí el service.** Archivo nuevo (no existe todavía; esto es el
ejercicio): `app/services/stock/return_from_customer.rb`

```ruby
# frozen_string_literal: true

module Stock
  # Devolución de un cliente: la mercadería vuelve al depósito.
  # Se distingue de `receipt` a propósito: contablemente una devolución no es una
  # compra, y el ledger tiene que poder responder "¿cuánto nos devolvieron?".
  class ReturnFromCustomer < ApplicationService
    def initialize(product:, warehouse:, quantity:, user: nil, reference: nil,
                   reason: nil, idempotency_key: nil,
                   event_recorder: Outbox::Recorder.new, clock: Time)
      @product = product ; @warehouse = warehouse ; @quantity = Integer(quantity)
      @user = user ; @reference = reference ; @reason = reason
      @idempotency_key = idempotency_key
      @event_recorder = event_recorder ; @clock = clock
    end

    def call
      return Result.failure(:invalid_quantity, "La cantidad debe ser positiva") unless @quantity.positive?
      return Result.failure(:reason_required, "Una devolución requiere un motivo") if @reason.blank?

      transactional do
        item = ItemResolver.call(product: @product, warehouse: @warehouse).value!

        ApplyMovement.call(
          stock_item: item,
          kind: "return",              # positivo: está en INBOUND
          quantity: @quantity,
          user: @user, reference: @reference, reason: @reason,
          idempotency_key: @idempotency_key,
          event_recorder: @event_recorder, clock: @clock
        ).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
      end
    end
  end
end
```

Fijate qué **no** tiene: locking, escritura del ledger, emisión de eventos, manejo
de transacción. Todo eso lo hereda de `ApplyMovement`. Lo único propio es "qué
significa devolver".

**3. Probalo en la consola antes de tocar HTTP.**

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
bin/rails runner '
  r = Stock::ReturnFromCustomer.call(
        product: Product.first, warehouse: Warehouse.physical.first,
        quantity: 2, reason: "Cliente devolvió por talle")
  puts r.ok? ? "OK movimiento ##{r.value.id} kind=#{r.value.kind}" : r.error.to_h.inspect
'
```

Que ande desde la consola, desde un job y desde un import CSV **sin tocar una
línea** es la prueba de que no se te filtró lógica al controller.

**4. Verificá que la invariante siga cerrando.**

```bash
bin/rails runner 'puts StockItems::Reconciliation.call.size'   # tiene que dar 0
```

**5. Autorización.** En `app/policies/stock_item_policy.rb`:
`def return_from_customer? = operator?`. Decidí el nivel a conciencia: `adjust?`
es `manager?` porque un ajuste cambia la contabilidad; una devolución la puede
hacer un operador.

**6. Ruta.** En `config/routes.rb`, dentro de `namespace :api → namespace :v1`:
`post "stock/return", to: "stock_operations#return_from_customer"`. No la llames
`return`: es palabra reservada de Ruby y no podés definir `def return`. Mismo
problema que `dispatch`, ya resuelto igual más arriba en ese archivo.

**7. Acción del controller (flaca).** En `stock_operations_controller.rb`:

```ruby
def return_from_customer
  item = resolve_stock_item(create_if_missing: true)
  authorize item, :return_from_customer?

  render_result(
    Stock::ReturnFromCustomer.call(
      product: @product, warehouse: @warehouse, quantity: quantity_param,
      user: current_user, reason: params[:reason], idempotency_key:
    ),
    success_status: :created, serializer: StockMovementSerializer
  )
end
```

Cuatro cosas y nada más: parsear, autorizar, delegar, traducir el `Result`.

**8. Mapeá los códigos de error nuevos.** Si inventaste un `code` que no está en
`STATUS_FOR` (`app/controllers/concerns/api/error_handling.rb:38`), agregalo. El
default es 422, que suele estar bien, pero `:not_found` y `:conflict` no se
adivinan. (`reason_required` ya está mapeado.)

**9. Verificá el contrato completo.**

```bash
bin/rails routes | grep stock/return
bundle exec rspec
bundle exec brakeman
```

**Checklist final**

- [ ] El service devuelve `Result` siempre, nunca levanta por reglas de negocio.
- [ ] Toda escritura pasa por `ApplyMovement` (o justificás por escrito por qué no).
- [ ] Cada llamada a un sub-service termina en `.tap { fail! if failure? }`.
- [ ] Hay `authorize` en la acción (si no, `verify_pundit_usage` te explota en dev).
- [ ] El `kind` nuevo, si lo hubiera, está en el CHECK constraint **y** en `StockMovement::KINDS` **y** en `INBOUND`/`OUTBOUND`.
- [ ] `StockItems::Reconciliation.call` sigue devolviendo `[]`.
- [ ] El evento de outbox tiene `event_type` con namespace (`stock.return`).

---

## 9. Dónde NO poner lógica, y por qué

**El controller gordo.** Síntoma: `if @stock_item.quantity_available < params[:quantity].to_i`
dentro de una acción. Esa regla no se puede ejecutar desde un job, desde la
consola ni desde un import CSV: la vas a duplicar y las dos copias van a divergir.
La prueba objetiva: si no podés ejecutar la operación completa con
`bin/rails runner`, tenés lógica atrapada en el controller.

**El modelo gordo.** Síntoma: `StockItem#receive!` que bloquea, valida, escribe el
ledger y emite un evento. Eso es un **caso de uso**, no responsabilidad de la
entidad de persistencia. Es el camino directo al God Model de 2000 líneas, viola
SRP y hace imposible testear las reglas sin base de datos — está dicho en la
cabecera de `app/models/stock_item.rb`. Sí van en el modelo: lecturas derivadas
(`available`, `below_reorder_point?`, `valuation`), validaciones de forma, scopes
y las invariantes que aplican siempre.

**Los callbacks.** Se disparan en **todos** los contextos, incluidos seeds,
migraciones de datos, fixtures y tests que no los quieren; convierten un `save!`
en una operación de efectos desconocidos; y los `after_commit` que encolan jobs
son especialmente traicioneros, porque dentro de una transacción anidada se
disparan **antes** de que la externa termine y encolás un job para datos que
todavía pueden hacer rollback. La solución correcta es
`ActiveRecord.after_all_transactions_commit`, que es lo que usa
`Outbox::Recorder#schedule_publish` (`app/services/outbox/recorder.rb:47`).
En el repo hay una decena de callbacks y la mayoría son inocuos: derivan un valor
de la **misma** fila antes de validar o de crear (`denormalize_from_stock_item` en
`StockMovement`, `recompute_path` y `assign_slug` en `Category`,
`assign_reference` en `StockTransfer` y `PurchaseOrder`, el `expires_at ||=` de
`Session`, `IdempotencyKey` y `StockReservation`). Los dos que **sí** salen de su
propia fila son los que hay que mirar con lupa:
`ProductSupplier#unset_other_preferred` (un `update_all` sobre las filas hermanas,
para no chocar con el índice único parcial) y
`PurchaseOrderLine#refresh_order_totals` (escribe en `purchase_orders`). Ninguno
encola un job: ese efecto vive en `Outbox::Recorder`, fuera de los callbacks, y
por las razones de arriba.

**`default_scope`.** Nunca. Está explicado en
`app/models/concerns/discardable.rb`: se cuela en todas las asociaciones, joins y
counts; hace que `Product.count` mienta; y `unscoped` para sacártelo de encima te
vuela también el `order` y los `where` del join. La convención sana es el scope
explícito (`Product.kept`).

**`Current` como bolsa de parámetros.** Es para contexto **transversal**: usuario
actual, `request_id`, IP. Pasar parámetros de negocio por ahí convierte argumentos
explícitos en dependencias globales invisibles y te arruina los tests. Es el mismo
abuso que hacerle `static` a todo en Java.

**Lógica en la vista.** `app/views/` sólo presenta. Un cálculo va en el modelo (si
es del dominio), en un helper (si es de formato) o en un query object (si es una
agregación).

---

## 10. Errores que ves en producción

| # | Síntoma | Causa real | Arreglo |
|---|---|---|---|
| 1 | Vendiste 14 unidades de 10; `quantity_on_hand` negativo o el CHECK rechazando UPDATEs | Se leyó la cantidad **fuera** del lock y se calculó el delta en Ruby. Postgres en READ COMMITTED no te protege: cada UPDATE ve la fila nueva, pero tu cálculo usó un valor viejo | `SELECT … FOR UPDATE` **antes** de validar, en la misma transacción: `StockItem.lock.find(id)` (`app/services/stock/apply_movement.rb:102`). El CHECK `quantity_on_hand >= 0` es la última red |
| 2 | 500 intermitentes e "imposibles de reproducir" en transferencias multi-línea; en el log `deadlock detected` | Dos transacciones toman los locks de `stock_items` en **orden distinto** (A: [7,3], B: [3,7]) | Orden total y determinístico: `.order(:id).lock`, en `lock_items_in_order` (`app/services/stock/transfers/dispatch.rb:99`). Misma disciplina en `ReleaseReservation`: siempre reserva → item, nunca al revés |
| 3 | Una transferencia falló a mitad y quedaron líneas commiteadas | Alguien sacó el `.tap { fail! }` después de un sub-service. La transacción anidada **se une** a la externa: que el hijo devuelva `Result.failure` no revierte nada (§7.4) | Todo llamado a un sub-service termina en `.tap { \|r\| fail!(...) if r.failure? }` |
| 4 | Dos comprobantes con la misma referencia (`PO-2026-000045`) | El **query cache** de Rails: `INSERT … RETURNING` ejecutado con `select_value` cuenta como SELECT y se cachea, así que la segunda llamada no toca la base | `connection.uncached { … }` + `clear_query_cache`, ya presente en `app/models/sequence_counter.rb`. No aparece en un test unitario suelto porque el cache está apagado fuera del executor |
| 5 | Un rate limit de 20/min corta en la request 11 | Dos declaraciones de `rate_limit` en el mismo controller **sin `name:`** generan la misma clave: comparten contador y cada request lo incrementa dos veces | `name:` distinto en cada `rate_limit` (`"api-global"`, `"stock-writes"`, `"reports"`) |
| 6 | El rate limit real es 4× el configurado y encima inconsistente | `Rack::Attack` con `MemoryStore`: cada worker de Puma tiene su propio contador | Store compartido y atómico (Redis). Sin `REDIS_URL`, el initializer ya loguea un warning explícito |
| 7 | Un solo cliente detrás de un balanceador tira a todos afuera | `Rack::Attack` insertado **antes** de `ActionDispatch::RemoteIp`: `request.ip` es la IP del balanceador y todos comparten contador | `insert_after ActionDispatch::RemoteIp` (`config/application.rb:52`) + `trusted_proxies` configurado. Nunca confíes en `X-Forwarded-For` a secas: lo manda el cliente |
| 8 | `quantity_available` "no se actualiza" después de escribir | Es una columna **generada**: la asignación se descarta en silencio y el objeto queda viejo. `StockItem.readonly_attributes` está vacío, así que ni te avisa | `reload` después de escribir, como hace `ApplyMovement#apply_to` (`:132`) |
| 9 | Doble ingreso de mercadería tras un timeout del cliente | El cliente reintentó un POST no idempotente | `Idempotency-Key` + índice único parcial sobre `stock_movements.idempotency_key`. Y el **fingerprint** del body: misma clave con body distinto → 422, no la respuesta vieja |
| 10 | El disponible baja solo y nunca se recupera | Reservas sin vencer: carritos abandonados que inmovilizan stock | `expires_at` obligatorio en toda reserva + `Stock::ExpireReservationsJob` cada minuto. Es el job que más se olvida |
| 11 | Un listado de 200 productos tarda 6 segundos | N+1 de **agregación**: `products.map { \|p\| p.stock_items.sum(...) }`. `includes` **no** lo arregla | `StockItems::Availability` — un `GROUP BY` + `pluck`. Bullet lo caza en los specs marcados `:n_plus_one` (`spec/support/bullet.rb`) |
| 12 | La página 5000 del ledger tarda segundos y repite filas | Paginación por `OFFSET`: Postgres genera y descarta 100.000 filas, y una inserción concurrente desplaza todo | Keyset con comparación de tuplas: `StockMovements::Ledger` |
| 13 | Un evento roto tapa la cola del outbox para siempre | *Poison message*: sin `rescue` por evento, el lote entero falla y se reintenta igual | El `rescue` va dentro del `each`, más `attempts`/`MAX_ATTEMPTS`. Revisá `OutboxEvent.stuck` |
| 14 | El reporte diario salió con 3 horas de diferencia | `config/recurring.yml` interpreta los horarios en `Time.zone` de la app | Definí `config.time_zone` explícitamente y no lo deduzcas |
| 15 | `AbstractController::ActionNotFound` en endpoints que antes andaban — **la única fila de esta tabla que NO ves en producción**: aparece en dev, test y CI | Un callback con `only: %i[index]` en una clase base que heredan controllers sin `index`. Rails 7.1 agregó `raise_on_missing_callback_actions`, que el generador pone en `true` sólo en dev/test (default de la gema: `false`) | Un solo callback que decide adentro, como `verify_pundit_usage`. No lo tapes poniendo el flag en `false`: el error es correcto |
| 16 | Un SKU con `\n<script>` pasó la validación | En Ruby `^`/`$` son principio/fin de **línea**, no de string (al revés que en Java) | `\A` y `\z` siempre. Brakeman lo marca solo |
| 17 | Tablas de sesiones/idempotencia hinchadas y queries degradadas con pocas filas vivas | Un DELETE masivo dejó millones de tuplas muertas y el autovacuum no da abasto | Borrar seguido y en lotes chicos (`Cleanup::ExpiredRecordsJob`). A escala real: particionar por fecha y `DROP PARTITION` |

---

## 11. Cómo responder esto en una entrevista

**"Contame la arquitectura de la app."**

> Rails 8 sobre Postgres 16, con las capas separadas a mano porque Rails no te las
> da: controllers que sólo traducen HTTP, service objects que son los casos de uso
> y devuelven un `Result`, query objects para las lecturas complejas, policies de
> Pundit y serializers POROs para el JSON. El dominio está modelado como
> **proyección + ledger**: `stock_items` guarda el saldo para leer O(1) y
> `stock_movements` es un libro mayor append-only e inmutable que es la verdad. Un
> job nocturno reconcilia los dos y alerta si difieren.
>
> **Trade-off**: mantengo un dato duplicado y necesito disciplina para que todas
> las escrituras pasen por un solo lugar. A cambio, las lecturas son O(1) en vez
> de un `SUM` sobre millones de filas, y tengo auditoría completa gratis. Sólo el
> ledger es más puro pero no escala en lectura; sólo la proyección es rápida pero
> pierde la historia, que en stock es el activo más valioso.

**"¿Cómo evitás vender stock que no tenés, con concurrencia?"**

> Lock pesimista de fila: `SELECT … FOR UPDATE` sobre el `stock_item`, dentro de la
> transacción y **antes** de validar. Sin eso hay una *lost update* clásica:
> Postgres en READ COMMITTED hace que cada UPDATE vea la fila más nueva, pero si el
> cálculo lo hiciste en Ruby con un valor leído antes, escribís basura. Con
> `FOR UPDATE` la segunda transacción espera en el SELECT y lee el valor ya
> commiteado. Como el lock es sobre **una fila** por par (producto, depósito), no
> serializo el sistema: dos productos distintos van 100 % en paralelo. Y tengo un
> CHECK `quantity_on_hand >= 0` como última red, que vale aunque alguien entre por
> `psql`.
>
> **Trade-off**: el pesimista cuesta un round-trip extra y puede generar deadlocks
> si no ordenás los locks. Para una sola fila con condición expresable en SQL, un
> UPDATE condicional atómico (`StockItem.atomically_decrement`) es más barato; para
> conflictos raros donde el usuario puede reintentar, optimistic locking con
> `lock_version`. Uso los tres, cada uno donde corresponde.

**"¿Por qué no usás excepciones para las reglas de negocio?"**

> Porque en Ruby todas las excepciones son unchecked y nada en la firma dice qué
> puede fallar. Separo falla **esperada** (regla de negocio → `Result.failure`, un
> valor con un `code` que el borde HTTP mapea a un status) de falla **inesperada**
> (bug o infra → excepción, que explota, se loguea y activa el retry del job). El
> `Result` compone con `then_try` —el `flatMap` de `Either`— y se consume con
> pattern matching, así que el camino de error es explícito en el tipo de retorno.
>
> **Trade-off**: más ceremonia que un `throw`, y el compilador no me obliga a
> chequear el `Result` como sí haría una checked exception. Lo compenso con tests y
> con un `after_action` que verifica que no me haya olvidado nada.

**"¿Cómo publicás eventos sin perderlos?"**

> Transactional outbox: el evento se inserta en `outbox_events` en la **misma**
> transacción que el cambio de negocio, commit atómico de los dos. Un job aparte
> lee los no publicados con `FOR UPDATE SKIP LOCKED` y los manda al broker. La
> clave es que un `after_commit` **no** es equivalente: si el proceso muere entre el
> COMMIT de Postgres y la ejecución del callback en Ruby, el evento se pierde sin
> rastro. Lo mismo pasa con `@TransactionalEventListener(AFTER_COMMIT)` en Spring.
>
> **Trade-off**: la garantía es at-least-once, no exactly-once — eso no existe en
> sistemas distribuidos. Por eso cada evento lleva un UUID y el consumidor tiene que
> deduplicar. Y con varios workers pierdo el orden global; si necesito orden por
> agregado, particiono por `aggregate_id`, que es lo mismo que la partition key de
> Kafka.

**"Venís de Hibernate. ¿Qué es lo que más te sorprendió de Active Record?"**

> Que no hay sesión de persistencia. Active Record es el patrón Active Record, no
> Data Mapper: cada `save!` es un INSERT/UPDATE inmediato. No hay `EntityManager`,
> no hay entidades detached, no hay `merge()` y **no hay dirty checking diferido al
> final de la transacción**. El corolario práctico es que tampoco hay lazy loading
> transparente con una sesión que lo cachee: tocar `product.category` dispara una
> query **en ese instante**. Por eso el N+1 es tan fácil de crear y por eso hay
> `includes` explícito en todos los scopes de listado. Es peor que la
> `LazyInitializationException` de Hibernate, porque en vez de romper ruidosamente
> se degrada en silencio. Y como el modelo mezcla persistencia y dominio, la
> disciplina SOLID la tengo que poner yo: modelos flacos + service objects.

**"¿Dónde ponés la lógica y cómo lo hacés cumplir?"**

> En los service objects. La prueba objetiva es que toda operación de negocio se
> puede ejecutar desde `bin/rails runner` sin tocar una línea: si no podés, hay
> lógica atrapada en el controller. Lo hago cumplir con tres cosas: un
> `after_action` que explota en dev/test si una acción no llamó a `authorize` o a
> `policy_scope`, Bullet con `raise = true` en los specs marcados `:n_plus_one`
> —ahí un N+1 rompe el test— y Brakeman en CI. Y
> el modelo tiene un comentario en la cabecera que dice explícitamente qué **no** va
> ahí, porque la documentación que vive lejos del código no la lee nadie.
>
> **Trade-off**: son más archivos y más indirección que un modelo gordo, y para un
> CRUD chico es sobreingeniería. Lo justifico cuando la operación tiene más de un
> paso, toca más de una tabla o tiene que emitir eventos — que acá es prácticamente
> todo.

---

## Para seguir

Leé los comentarios del código en este orden: `app/lib/result.rb` →
`app/services/application_service.rb` → `app/services/stock/apply_movement.rb` →
`db/migrate/20260830160700_create_stock_movements.rb` →
`db/migrate/20260830161100_create_outbox_events.rb`. Con esos cinco archivos
entendés el 70 % del sistema.

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"

bin/rails middleware                            # el stack Rack real
bin/rails routes | grep api/v1                  # el contrato de la API
bin/rails runner 'p StockItems::Reconciliation.call.size'   # la invariante
bin/rails runner 'p StockItems::LowStock.call.explain(analyze: true)'
psql -d stock_development -c '\d stock_items'   # CHECKs, índices, columna generada
bundle exec brakeman                            # seguridad
```
