# 📦 Control de Stock — Rails 8.1

Sistema de control de inventario multi-depósito, escrito como **material de
estudio**: cada archivo está comentado explicando *qué hace, por qué está hecho
así, cuál era la alternativa y qué se rompe si lo hacés distinto*.

Está pensado para alguien que **viene de Java/Spring** y necesita entender Ruby
on Rails a nivel de entrevista técnica senior. En `docs/` hay ~16 documentos que
desarrollan cada tema a fondo.

---

## Qué hace la app

Un sistema de stock de verdad, no un CRUD de juguete:

| Capacidad | Dónde está |
|---|---|
| Catálogo (productos, categorías, proveedores) | `app/models/product.rb`, `category.rb`, `supplier.rb` |
| Stock por producto **y depósito** | `app/models/stock_item.rb` |
| **Libro mayor inmutable** de movimientos | `app/models/stock_movement.rb` |
| Reservas con vencimiento automático | `app/services/stock/reserve.rb` |
| Transferencias entre depósitos con depósito en tránsito y merma | `app/services/stock/transfers/` |
| Órdenes de compra con recepción parcial | `app/services/purchasing/receive_order.rb` |
| API JSON con tokens, scopes e **idempotencia** | `app/controllers/api/v1/` |
| **Rate limiting en dos capas** | `config/initializers/rack_attack.rb` + `base_controller.rb` |
| Cola de jobs y **transactional outbox** | `app/jobs/`, `app/services/outbox/` |
| UI web con Hotwire + Tailwind | `app/views/` |

---

## Arranque rápido

```bash
# Requisitos: Ruby 3.3.6, PostgreSQL 16+, (Redis opcional)
bin/setup                 # instala gemas, prepara la base y siembra datos
bin/dev                   # levanta web + tailwind + worker de jobs
```

Abrí <http://localhost:3000> e ingresá con:

| Usuario | Contraseña | Rol |
|---|---|---|
| `admin@stock.test` | `password123` | admin |
| `manager@stock.test` | `password123` | manager |
| `operador@stock.test` | `password123` | operator |
| `viewer@stock.test` | `password123` | viewer |

El dashboard de jobs está en `/jobs` (sólo admin).

### Probar la API

```bash
# Generá un token
TOKEN=$(bin/rails runner 'print ApiToken.issue!(
  user: User.find_by(email_address: "admin@stock.test"),
  name: "curl", scopes: ApiToken::SCOPES).plaintext')

# Listar productos (con disponibilidad agregada, resuelta en UNA query)
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:3000/api/v1/products?limit=5" | jq

# Ingresar mercadería, con idempotencia
curl -s -X POST http://localhost:3000/api/v1/stock/receive \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"sku":"TOR-M5-20","warehouse_code":"BA-01","quantity":50,"reason":"Compra"}' | jq

# Intentar sacar más de lo que hay -> 422 con detalle accionable
curl -s -X POST http://localhost:3000/api/v1/stock/issue \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"sku":"TOR-M5-20","warehouse_code":"BA-01","quantity":999999}' | jq

# Reportes
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:3000/api/v1/reports/valuation | jq
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:3000/api/v1/reports/reconciliation | jq
```

### Correr los tests

```bash
bundle exec rspec                       # toda la suite (~20 s, 358 ejemplos)
bundle exec rspec spec/services         # sólo los casos de uso
bundle exec rspec spec/integration      # concurrencia con threads reales
COVERAGE=1 bundle exec rspec            # con reporte de cobertura
LINT_FACTORIES=1 bundle exec rspec      # valida todas las factories y traits
BULLET_UNUSED=1 bundle exec rspec       # además, eager loading innecesario
bundle exec rubocop                     # estilo
bundle exec brakeman -q                 # seguridad
bundle exec bundle-audit check --update # CVEs en las dependencias
bin/rails zeitwerk:check                # autoloading (lo que rompe en prod)
```

### Diagnóstico y operación

```bash
bin/rails stock:reconcile        # ¿el ledger cuadra con la proyección?
bin/rails stock:low[BA-01]       # qué hay que reponer
bin/rails stock:valuation        # cuánta plata hay parada
bin/rails stock:outbox           # estado de la cola de eventos
bin/rails stock:token[admin@stock.test,mi-app]
bin/rails db:unused_indexes      # índices que Postgres nunca usó
bin/rails db:table_sizes         # tuplas muertas y bloat
```

---

## La documentación

Todo el material de estudio está en [`docs/`](docs/). Empezá por el 00 si venís
de Java; si ya sabés Rails, andá directo al tema que te interese.

| # | Documento | De qué va |
|---|---|---|
| 00 | [Ruby y Rails para javeros](docs/00-ruby-y-rails-para-javeros.md) | El modelo de objetos, bloques, Data, pattern matching, GVL vs threads de la JVM |
| 01 | [Arquitectura](docs/01-arquitectura.md) | El mapa de capas, el modelo de dominio y por qué está así |
| 02 | [Dependencias y gemas](docs/02-dependencias-y-gemas.md) | Qué hace cada gema, la alternativa y por qué elegimos esta |
| 03 | [Base de datos y ActiveRecord](docs/03-base-de-datos-y-activerecord.md) | Pool, multi-DB, migraciones seguras, constraints, callbacks |
| 04 | [Optimización de queries](docs/04-optimizacion-de-queries.md) | N+1, includes vs joins, índices, EXPLAIN, keyset pagination |
| 05 | [SOLID y patrones](docs/05-solid-y-patrones.md) | Los 5 principios con el código real, y los patrones que usamos |
| 06 | [Concurrencia y locking](docs/06-concurrencia-transacciones-y-locking.md) | Lost update, FOR UPDATE, optimistic locking, deadlocks |
| 07 | [Colas y mensajería](docs/07-colas-jobs-y-mensajeria.md) | Active Job, Solid Queue vs Sidekiq, outbox transaccional |
| 08 | [Rate limiting](docs/08-rate-limiting.md) | Algoritmos, discriminadores, stores, las dos capas |
| 09 | [Testing](docs/09-testing.md) | Todos los tipos de test, con los ejemplos de este repo |
| 10 | [Errores comunes](docs/10-errores-comunes.md) | El catálogo de lo que rompe en producción |
| 11 | [API REST e idempotencia](docs/11-api-rest-serializacion-e-idempotencia.md) | Diseño, versionado, serialización, idempotencia estilo Stripe |
| 12 | [Seguridad](docs/12-seguridad.md) | OWASP aplicado a Rails, con los ejemplos del repo |
| 13 | [Observabilidad y performance](docs/13-observabilidad-y-performance.md) | Logs, métricas, profiling, memoria, Postgres |
| 14 | [Deploy y operación](docs/14-deploy-y-operacion.md) | Entornos, Docker, Kamal, migraciones sin downtime, runbook |
| 15 | [Preguntas de entrevista](docs/15-preguntas-de-entrevista.md) | ~100 preguntas con respuestas, agrupadas por tema |

---

## Las 6 decisiones de diseño que hay que poder defender

### 1. La cantidad NO vive en `products`

Vive en `stock_items`, que es un renglón por **(producto, depósito)**. Meter
`quantity` en `products` es el error de modelado número uno de este dominio y te
cierra la puerta a multi-depósito para siempre.

### 2. `stock_items` es una PROYECCIÓN; la verdad es el ledger

```
stock_items.quantity_on_hand  ==  SUM(stock_movements.quantity)
```

`stock_movements` es **append-only e inmutable**: el hecho histórico. La columna
es un cache para leer en O(1). El job `Stock::ReconcileBalancesJob` compara las
dos todas las noches y alerta si difieren (si difieren, hay un bug: alguien
escribió la cantidad sin pasar por un service).

Es CQRS/event sourcing en su versión pragmática, sin el peso conceptual completo.

### 3. Las invariantes viven en la BASE, no sólo en Rails

```sql
CHECK (quantity_on_hand >= 0)
CHECK (quantity_reserved >= 0)
CHECK (quantity_reserved <= quantity_on_hand)
```

Una validación de ActiveRecord corre en **un** proceso Ruby y **no** es atómica:
entre el `SELECT` que valida y el `UPDATE` que escribe, otro proceso puede haber
cambiado la fila. El `CHECK` lo evalúa Postgres dentro de la transacción, sobre
la fila final. Es la única garantía real bajo concurrencia — y además la respetan
los scripts, las migraciones y el `psql` a mano.

### 4. Un solo lugar muta el stock, y toma un lock

`Stock::ApplyMovement` es el único código que cambia una cantidad. Hace
`SELECT ... FOR UPDATE`, valida contra el estado ya bloqueado, actualiza la
proyección, escribe el asiento y registra el evento — todo en una transacción.

Hay un test que lo prueba con **8 threads reales** compitiendo por 10 unidades:
pasan exactamente 3 y el stock nunca queda negativo
(`spec/integration/concurrency_spec.rb`).

### 5. Los errores de negocio son VALORES, no excepciones

```ruby
case Stock::Issue.call(product:, warehouse:, quantity: 5)
in { ok: true, value: movimiento }  then render json: movimiento
in { ok: false, error: }            then render json: error, status: :unprocessable_content
end
```

Las excepciones quedan para lo **inesperado** (la base se cayó, un bug). Las
reglas de negocio ("no hay stock") son parte del contrato y viajan en el tipo de
retorno. En Java sería un `Either`/`Result` en vez de una unchecked exception.

### 6. Los eventos salen por un outbox transaccional

Escribir en la base **y** publicar un evento son dos sistemas: no hay transacción
distribuida. Escribimos el evento en `outbox_events` en la **misma** transacción
que el cambio de negocio (commit atómico), y un job aparte lo publica después.
Garantía: *at-least-once* + `event_id` para que el consumidor deduplique.

---

## Estructura del código

```
app/
├── models/           ActiveRecord: persistencia + invariantes simples
│   ├── concerns/     mixins reutilizables (Discardable, HasMoney)
│   └── value_objects/ Money y Quantity con Data.define (≈ record de Java)
├── services/         CASOS DE USO. Una clase, un `call`, devuelve Result
│   ├── stock/        receive, issue, adjust, reserve, commit, transfers
│   ├── purchasing/   recepción de órdenes de compra
│   └── outbox/       grabador de eventos y publishers intercambiables
├── queries/          QUERY OBJECTS: consultas complejas, fuera del modelo
├── policies/         Pundit: una clase por recurso, un método por acción
├── serializers/      POROs que arman el JSON (contrato explícito de la API)
├── forms/            Form objects: validan el INPUT, que no es el modelo
├── jobs/             Active Job (Solid Queue por defecto)
├── controllers/
│   ├── api/v1/       API JSON: token, scopes, idempotencia, rate limit
│   └── concerns/api/ auth, manejo de errores, idempotencia
└── views/            Hotwire + Tailwind
```

**La regla**: el controller traduce HTTP ↔ dominio y nada más. El modelo sabe de
persistencia y de sus propias invariantes. Todo lo demás —las operaciones de
negocio— vive en `services/`.

---

## Stack

| Capa | Elección | Por qué |
|---|---|---|
| Lenguaje | Ruby 3.3.6 | `Data.define`, pattern matching, endless methods |
| Framework | Rails 8.1 | autenticación nativa, `rate_limit`, stack Solid |
| Base | PostgreSQL 16 | columnas generadas, `citext`, `pg_trgm`, índices parciales, `SKIP LOCKED` |
| Jobs | Solid Queue (o Sidekiq por ENV) | sin infra extra; encolar es transaccional |
| Cache | Solid Cache | mismo backend que producción también en desarrollo |
| Front | Hotwire + Tailwind + importmap | sin build de JS, sin duplicar el dominio en el front |
| Autorización | Pundit | policies = Strategy, testeables sin HTTP |
| Rate limiting | Rack::Attack + `rate_limit` de Rails | borde + política de negocio |
| Tests | RSpec, FactoryBot, Capybara, Cuprite, Bullet | ver `docs/09` |

**Estado de la suite**: 358 ejemplos, 0 fallas (~20 s). RuboCop sin ofensas,
Brakeman sin warnings, `zeitwerk:check` OK, lint de factories OK.
La detección de N+1 con Bullet está activa de verdad y hay un
[control positivo](spec/n_plus_one_guard_spec.rb) que falla si deja de detectar.

Cambiá el backend de colas sin tocar una línea de código:

```bash
QUEUE_ADAPTER=sidekiq REDIS_URL=redis://localhost:6379/0 bin/rails server
```

---

## Variables de entorno

| Variable | Default | Para qué |
|---|---|---|
| `DATABASE_URL` | — | Conexión a Postgres en producción |
| `RAILS_MAX_THREADS` | `5` | Threads de Puma **y** tamaño del pool de conexiones |
| `QUEUE_ADAPTER` | `solid_queue` | `solid_queue` \| `sidekiq` \| `async` \| `inline` \| `test` |
| `REDIS_URL` | — | Si está, Rack::Attack y el rate limiter usan Redis |
| `OUTBOX_ADAPTER` | `log` | `log` \| `noop` \| `webhook` |
| `OUTBOX_WEBHOOK_URL` | — | Destino del adapter `webhook` |
| `OUTBOX_WEBHOOK_SECRET` | — | Clave HMAC para firmar los webhooks |
| `INTERNAL_CIDRS` | redes privadas | Rangos que Rack::Attack no limita |
| `SEED_ADMIN_PASSWORD` | `password123` | Contraseña de los usuarios sembrados |
| `SEED_DEMO` | `true` | Sembrar o no el dataset de demo |

---

## Bugs reales encontrados construyendo esto

Están documentados en el código, con el comentario al lado del arreglo y —donde
corresponde— un test de regresión que los cubre. Son buen material de entrevista
porque son problemas que **de verdad** aparecen:

1. **Query cache de ActiveRecord sobre un `INSERT ... RETURNING`** — ejecutado con
   `select_value`, Rails lo trata como un SELECT y lo cachea: dos comprobantes
   con el mismo número. → `app/models/sequence_counter.rb`
2. **Rack::Attack antes de `ActionDispatch::RemoteIp`** — sin la IP real, detrás de
   un balanceador todos los usuarios comparten un solo contador. → `config/application.rb`
3. **Una acción llamada `dispatch`** — pisa `ActionController::Metal#dispatch` y
   revienta **todas** las acciones del controller. → `config/routes.rb`
4. **Dos `rate_limit` sin `name:`** — comparten clave de cache, cada request cuenta
   doble y el límite corta a la mitad. → `app/controllers/api/v1/base_controller.rb`
5. **Clave de idempotencia global en vez de por usuario** — dos clientes con la
   misma clave se pisaban entre sí. → `app/controllers/concerns/api/idempotency.rb`
6. **Constantes dentro de `Data.define do ... end`** — se resuelven léxicamente y
   NO quedan anidadas. → `app/models/value_objects/money.rb`
7. **`Rails.cache` como `:null_store` en test** — el rate limiting no hacía nada, en
   silencio. → `config/environments/test.rb`
8. **`driven_by :cuprite` re-registra el driver** en Rails 8 y descarta las opciones
   de `Capybara.register_driver`. → `spec/support/capybara.rb`
9. **`after_action ... only: [:index]`** en una clase base rompe los controllers que
   no tienen esa acción (Rails 7.1+). → `app/controllers/api/v1/base_controller.rb`
10. **Autofix de reconciliación vía `ApplyMovement`** — mueve la proyección y el
    ledger a la vez, así que la diferencia nunca converge. → `app/jobs/stock/reconcile_balances_job.rb`
11. **Bullet sólo en `group :development`** — en test la constante no existía, los
    guards `if defined?(Bullet)` daban false y los specs marcados `:n_plus_one`
    pasaban hubiera o no un N+1. Una red de seguridad que no atrapaba nada.
    → `Gemfile`, `spec/n_plus_one_guard_spec.rb`
12. **`find_or_provision!` con un `rescue` inútil** — se llama dentro de una
    transacción, y en Postgres una sentencia fallida aborta la transacción
    entera: el `find_by!` del rescate moría. Necesita un SAVEPOINT.
    → `app/models/stock_item.rb`
13. **`enqueue_after_transaction_commit = :always` en un initializer** — no-op en
    Rails 8.1: el railtie excluye esa clave de la config global. Parecía
    configurado y no lo estaba. → `app/jobs/application_job.rb`
14. **Los throttles de login por email nunca dispararon** — leían los params
    anidados (`session[email_address]`) y el formulario los manda planos.
    Discriminador nil = Rack::Attack no cuenta nada, sin error ni aviso.
    → `config/initializers/rack_attack.rb`
15. **Fuerza bruta de tokens de API sin límite** — el 401 corta la cadena de
    callbacks, así que el rate limit de aplicación nunca corría, y el de borde
    discrimina por token: cada token adivinado estrenaba su propio balde.
    → `config/initializers/rack_attack.rb`
16. **Sesiones vencidas seguían autenticando** — `Session.find_by` en vez de
    `Session.active.find_by`. → `app/controllers/concerns/authentication.rb`
17. **Paginación sin techo** — `?limit=1000000` era un DoS de una línea en seis
    endpoints. → `app/controllers/api/v1/base_controller.rb`
18. **La clave de idempotencia se quemaba con un error del cliente** — quedaba en
    `processing` 24 h. Y el arreglo obvio (`ensure`) tampoco sirve: corre antes
    de que el `rescue_from` renderice. → `app/controllers/concerns/api/idempotency.rb`
19. **`"false"` es truthy en Ruby** — `SOLID_QUEUE_IN_PUMA: false` en Kamal llega
    como el string `"false"` y el plugin arrancaba igual en los contenedores web.
    → `config/deploy.yml`
20. **Traits de enum autogenerados por FactoryBot** — inventaban estados que
    violan los CHECK constraints y rompían el lint de factories en CI.
    → `spec/support/factory_bot.rb`

---

## Licencia

Material educativo. Usalo como quieras.
