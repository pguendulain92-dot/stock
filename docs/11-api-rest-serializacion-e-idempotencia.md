# Diseño de la API: REST, serialización, idempotencia y versionado

Acá tenés el contrato HTTP de este repo explicado desde adentro: por qué hay
endpoints que no son recursos, por qué la API habla en SKUs y no en ids, cómo se
traduce un error de dominio a un status, y —sobre todo— cómo está implementada la
idempotencia estilo Stripe en `app/controllers/concerns/api/idempotency.rb`, que
es el tema que más se pregunta y el que más gente contesta a medias.

Todo lo que ves acá lo corrí contra la app real: levanté `bin/rails server -p 3001`
sobre la base `stock_development` (15 productos, 4 depósitos, 106 movimientos) y
pegué las respuestas literales. Cuando digo "devuelve 410", devolvió 410. Cuando
digo "esto está roto", lo rompí a propósito y guardé el stacktrace.

Una nota sobre los bugs. Escribir esta doc destapó defectos reales del repo, y
**la mayoría ya está corregida**. No los borré: el valor está en el diagnóstico,
no en el parche. Los dejo contados en pasado —"así se veía, así se detectó, así
se arregló"— con la referencia al archivo y al spec de regresión. Los que
**siguen vivos** están marcados con ⚠️ y dicen qué falta. La tabla de estado
está al principio de la sección "Errores que ves en producción".

Venís de Java: el mapa mental es `@RestController` + `@ControllerAdvice` +
`ResponseEntity` + Jackson + Spring Security. Te marco en cada sección dónde la
analogía se rompe, que es donde se cometen los errores.

---

## 1. REST vs RPC sobre HTTP: por qué `POST /stock/receive`

El dogma REST dice: modelá *recursos* (sustantivos) y usá los verbos HTTP para
manipularlos. Bajo esa regla, "ingresar 10 unidades" sería:

```http
POST /api/v1/stock_movements
{"kind": "receipt", "product_id": 9, "warehouse_id": 1, "quantity": 10}
```

Este repo hace otra cosa (`config/routes.rb:92`):

```ruby
post "stock/receive", to: "stock_operations#receive"
post "stock/issue",   to: "stock_operations#issue"
post "stock/adjust",  to: "stock_operations#adjust"
```

Y está bien. El razonamiento:

**1. La intención es dato de dominio, no metadato de transporte.** `receive`,
`issue` y `adjust` producen los tres una fila en `stock_movements`, pero *no son
lo mismo*. Un `adjust` de +10 es "el conteo físico dio 10 más de lo que decía el
sistema" — eso dispara una investigación de merma. Un `receive` de +10 es "llegó
el camión". Si el cliente elige el `kind` como si fuera un campo más, el día que
agregues una regla ("ajustar requiere rol manager y motivo obligatorio") no la
podés aplicar sin inspeccionar el body. Con endpoints separados, la regla vive en
la ruta: `app/controllers/api/v1/stock_operations_controller.rb:68` autoriza
`adjust` contra una policy distinta que `receive`.

**2. Los parámetros no son los mismos.** Mirá las firmas reales:

| Operación | Parámetro de cantidad | Semántica |
|---|---|---|
| `receive` | `quantity` | delta positivo |
| `issue` | `quantity` | delta a restar |
| `adjust` | `counted_quantity` | **valor absoluto** contado, el delta lo calcula el servicio |

Un único `POST /movements` te obliga a un body polimórfico con campos que sólo
aplican a veces. Eso es un tipo suma mal modelado, y en OpenAPI se resuelve con
`oneOf` + `discriminator`, que es exactamente admitir que son tres operaciones.

**3. `create_if_missing` difiere.** `receive` y `adjust` crean el `StockItem` si
no existe; `issue` no (`app/controllers/api/v1/stock_operations_controller.rb:82`).
No podés expresar eso con un solo endpoint sin un flag feo.

### 1.1 Dónde SÍ conviene el recurso puro

En este repo conviven los dos estilos, y el criterio es simple:

| Estilo | Cuándo | Ejemplo del repo |
|---|---|---|
| Recurso REST | El cliente hace CRUD sobre una entidad con estado propio | `resources :products` (`config/routes.rb:58`) |
| Sub-recurso de acción | Transición de máquina de estados sobre un recurso existente | `POST /purchase_orders/:id/submit`, `.../cancel` |
| RPC puro | Comando que no mapea a una entidad que el cliente conozca de antemano | `POST /stock/receive` |

La regla que conviene decir en una entrevista: **REST es un estilo, no una
religión. Si tu dominio es de comandos (banca, logística, pagos), forzar CRUD te
hace perder información de intención, y esa información es la que después
necesitás para auditar.** Stripe hace lo mismo: `POST /v1/charges/:id/capture`,
`POST /v1/refunds`. Nadie diría que la API de Stripe está mal diseñada.

### 1.2 Dónde se rompe la analogía con Spring

En Spring MVC, `@PostMapping("/stock/receive")` y `@PostMapping("/movements")`
son igual de baratos: mapeás un método y listo. En Rails, `resources :x` te
genera siete rutas, helpers de URL, y una convención que el resto del framework
asume. **Salirte de la convención tiene costo real**: perdés los helpers
generados, y si nombrás mal una acción, chocás con el framework. Ejemplo genuino
de este repo (`config/routes.rb:38`):

```ruby
post :dispatch, action: :dispatch_transfer
```

`dispatch` es un método de `ActionController::Metal` — el router lo invoca como
`controller.dispatch(name, request, response)`. Si definís `def dispatch` en un
controller, pisás el motor de Rails y **todas** las acciones de ese controller
revientan con `wrong number of arguments (given 3, expected 0)`. En Java esto no
te pasa: `@PostMapping` no depende del nombre del método. Otros nombres a evitar:
`process`, `render`, `params`, `send`, `status`, `response`, `request`.

---

## 2. Claves naturales vs ids internos

Esta API habla en **SKU** y **código de depósito**, no en ids autoincrementales:

```ruby
# app/controllers/api/v1/base_controller.rb:153
def find_product!
  Product.find_by!(sku: params.require(:sku).to_s.strip.upcase)
end

def find_warehouse!
  Warehouse.find_by!(code: params.require(:warehouse_code).to_s.strip.upcase)
end
```

Y en `products` el `:id` de la ruta *es* el SKU
(`app/controllers/api/v1/products_controller.rb:34`):

```ruby
product = Product.includes(:category).find_by!(sku: params[:id].to_s.upcase)
```

Verificado contra la app corriendo:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:3001/api/v1/products/AMO-115 | jq -r '.data.sku'
# => AMO-115
```

### 2.1 Las tres razones

**Usabilidad de integración.** El ERP del cliente conoce el SKU `AMO-115`. No
conoce tu `id = 9`. Con claves naturales, integrar es escribir la URL; con ids
internos, es mantener una tabla de mapeo del lado del cliente y sincronizarla.

**Idempotencia de integración.** Si reimportás el catálogo, el SKU sigue siendo
el mismo; el id puede cambiar (restore de backup, migración entre entornos, un
`db:seed` distinto). Un cliente que guardó ids apunta al producto equivocado.

**Enumeración.** Un id secuencial expuesto es un oráculo:

- Te dice el **volumen del negocio**. Si el 1 de enero tu API devuelve
  `purchase_order.id = 4120` y el 1 de febrero `4890`, el competidor sabe que
  hacés ~770 órdenes por mes. Es el clásico *German tank problem*.
- Habilita el **IDOR por barrido**: `GET /reservations/1`, `/2`, `/3`… Si una
  sola policy falla, el atacante encuentra el agujero probando en orden. Con
  UUIDs o claves naturales tiene que adivinar.

**Ojo, no es control de acceso.** Ocultar el id no te autoriza nada: la defensa
real sigue siendo la policy. Este repo tiene `after_action :verify_pundit_usage`
(`app/controllers/api/v1/base_controller.rb:117`) justamente para que "me olvidé
el `authorize`" sea un error ruidoso y no un agujero silencioso.

Y el límite de esa red también vale conocerlo, porque acá se pagó: el callback te
obliga a **llamar** a `policy_scope`, pero no puede saber que la policy no
existe. `GET /api/v1/reservations` llamaba a `policy_scope(StockReservation)` sin
que hubiera `StockReservationPolicy`, así que devolvía `Pundit::NotDefinedError`
→ 500 para **cualquier** request, y ningún test lo ejecutaba. Hoy la policy está
(`app/policies/stock_reservation_policy.rb`) y lo que impide que vuelva a pasar
es `spec/requests/api/v1/endpoint_coverage_spec.rb`, que recorre todas las rutas
de `/api/v1` y falla si alguna devuelve 5xx. Un chequeo estático no reemplaza
ejecutar el código.

### 2.2 Dónde este repo NO lo aplica (y qué significa)

`reservations` y `stock_transfers` usan el id numérico en la URL:
`POST /api/v1/reservations/5/commit`. `purchase_orders` usa la `reference`
(`PurchaseOrder.find_by!(reference: params[:id])`, línea 19 del controller), que
sí es una clave natural (`TR-2026-000001`, generada por `sequence_counters`).

La inconsistencia es real y vale reconocerla: las reservas son efímeras y
privadas del que las creó, así que el riesgo de enumeración es bajo; pero si
mañana exponés reservas a un portal de clientes, ahí sí querés un UUID público.
El patrón para arreglarlo sin romper nada es agregar una columna `public_id`
(`uuid`, con índice único) y rutear por ella dejando el `id` bigint como PK
interna — no cambiás las FKs ni el tamaño de los índices.

---

## 3. Versionado

Este repo versiona **por path**: `/api/v1/...` (`config/routes.rb:55`).

| Estrategia | Ejemplo | A favor | En contra |
|---|---|---|---|
| **Path** | `/api/v1/products` | Explícito, visible en logs y en el balanceador, cacheable, probable desde el browser, `curl` sin ceremonia | Los puristas dicen que la URI debe identificar el recurso, no su representación |
| **Header custom** | `X-API-Version: 2` | No ensucia la URI | Invisible en logs; los caches intermedios no lo conocen salvo `Vary:`; imposible de probar pegando una URL |
| **Accept / media type** | `Accept: application/vnd.stock.v2+json` | Es lo que dice HTTP en serio (content negotiation) | Igual que el anterior + hay que educar a cada cliente; muchos SDKs lo pisan |
| **Query param** | `?version=2` | Trivial | Se pierde en redirects, ensucia claves de cache, se cae si el cliente arma la query con un builder que reordena |
| **Sin versión, sólo aditivo** | — | Nunca rompés | Requiere disciplina brutal; no podés borrar nunca un campo |

**Path gana en la práctica** y es lo que usan Stripe (que además tiene versión
por *cuenta*, fijada en el momento del alta), GitHub, Twilio y AWS. El comentario
en `config/routes.rb:43-54` lo dice con el argumento operativo: con el path podés
enrutar `v1` y `v2` a *deploys distintos* en el balanceador, y hacer canary de
`v2` sin tocar `v1`.

### 3.1 Qué es un breaking change (y qué no)

| Cambio | ¿Rompe? | Por qué |
|---|---|---|
| Agregar un campo al response | No | Un cliente sano ignora lo que no conoce |
| Agregar un parámetro **opcional** | No | — |
| Quitar un campo del response | **Sí** | — |
| Renombrar un campo | **Sí** | Es quitar + agregar |
| Cambiar el tipo (`"10"` → `10`) | **Sí** | Parsers estrictos revientan |
| Hacer obligatorio un parámetro antes opcional | **Sí** | — |
| Agregar un valor a un enum (`kind: "transfer_out"`) | **Depende** | Rompe a los clientes que hacen `switch` exhaustivo. En la práctica sí rompe |
| Cambiar un 200 por un 201 | **Sí, sutil** | Muchos clientes chequean `== 200` |
| Endurecer una validación | **Sí** | Requests que antes pasaban ahora dan 422 |

El de los enums es el que más muerde. `StockMovement#kind` tiene valores
cerrados; el día que agregues uno, un cliente Java con un `switch` sobre un enum
generado va a tirar `IllegalArgumentException` en producción. **Documentá desde
el día uno que los enums son abiertos y que el cliente tiene que tener un caso
`default`.**

### 3.2 Deprecación: cómo se hace de verdad

Las cabeceras estándar son `Deprecation` (RFC 9745) y `Sunset` (RFC 8594):

```ruby
# Lo que agregarías en Api::V1::BaseController cuando salga v2:
before_action :announce_deprecation

def announce_deprecation
  response.set_header("Deprecation", "@1767225600")             # epoch de anuncio
  response.set_header("Sunset", "Wed, 01 Jul 2026 00:00:00 GMT") # HTTP-date
  response.set_header("Link", '</api/v2/products>; rel="successor-version", ' \
                              '<https://docs.stock.test/migracion-v2>; rel="deprecation"')
end
```

Ojo con el formato, porque son distintos: `Sunset` (RFC 8594) va en
**HTTP-date**, o sea el IMF-fixdate de RFC 9110 §5.6.7 (`Wed, 01 Jul 2026
00:00:00 GMT`). `Deprecation` (RFC 9745) NO es HTTP-date: es un **Structured
Field Date** (el tipo `Date` de RFC 9651), que se serializa como `@` + segundos desde epoch
(`@1767225600`). Los borradores viejos de la spec usaban HTTP-date y por eso
circula mal copiado. Mandarlos con formatos inventados es peor que no mandarlos,
porque el cliente que los parsea explota.

La cabecera es la parte fácil. El proceso real:

1. **Instrumentá antes de anunciar.** No podés deprecar lo que no medís. Con el
   `token.touch_usage!` que ya existe (`app/models/api_token.rb:77`) sabés qué
   tokens están vivos; falta registrar *qué endpoints* usa cada uno. Un `after_action`
   que loguee `{token_id, path, version}` a un log estructurado alcanza.
2. **Ventana proporcional al costo de migrar.** Regla usable: 6 meses para una
   API pública, 3 para partners con contrato, 30 días para un cliente interno.
3. **Comunicación dirigida, no un blog post.** Con los datos del paso 1 mandás
   mail *sólo a los que usan el endpoint*, con el `token.name` y la última fecha
   de uso. Un anuncio genérico lo ignora todo el mundo.
4. **Brownouts.** Antes del apagón, devolvé 410 durante ventanas cortas y
   anunciadas (una hora, tres veces, con dos semanas de aviso). Es la única forma
   de descubrir al cliente que no leyó el mail y no tiene alertas.
5. **410 Gone, no 404.** Cuando lo apagás, el 410 dice "existía y lo matamos", y
   es la diferencia entre que el cliente busque el changelog o crea que hay un
   bug de routing.

En Java el paralelo es `@Deprecated` + `@since` + el `maven-enforcer-plugin`. La
diferencia grande: en una librería, el que rompe *decide cuándo* actualizar. En
una API, **vos rompés a todos a la vez y ellos no eligen**. Por eso la ventana y
la comunicación pesan más que la cabecera.

---

## 4. Tabla de endpoints (los 33 de `bin/rails routes`)

Los 33 endpoints de `/api/v1` (`bin/rails routes | grep api/v1 | wc -l` → 33).
Un detalle de lectura: el router siempre nombra el segmento **`:id`**; abajo lo
escribo como `:sku`, `:code` o `:reference` porque es la clave natural que ese
`:id` transporta en cada recurso (ver §2). La columna *Scope* sale de los
`requires_scope` de cada controller; *Idem.* marca las acciones envueltas por
`idempotent`.

Que la tabla no mienta lo garantiza un spec, no mi memoria:
`spec/requests/api/v1/endpoint_coverage_spec.rb` enumera las rutas desde
`Rails.application.routes`, las ejecuta todas con datos reales y falla si alguna
devuelve 5xx. Se actualiza solo: si mañana agregás un endpoint, aparece en la
lista sin que nadie tenga que acordarse.

| Método | Path | Controller#acción | Scope | Idem. |
|---|---|---|---|---|
| GET | `/api/v1/products` | `products#index` | `catalog:read` | — |
| POST | `/api/v1/products` | `products#create` | `catalog:write` | ✓ |
| GET | `/api/v1/products/:sku` | `products#show` | `catalog:read` | — |
| PATCH/PUT | `/api/v1/products/:sku` | `products#update` | `catalog:write` | — |
| DELETE | `/api/v1/products/:sku` | `products#destroy` | `catalog:write` | — |
| GET | `/api/v1/warehouses` | `warehouses#index` | `catalog:read` | — |
| GET | `/api/v1/warehouses/:code` | `warehouses#show` | `catalog:read` | — |
| GET | `/api/v1/stock_items` | `stock_items#index` | `stock:read` | — |
| GET | `/api/v1/stock_items/:id` | `stock_items#show` | `stock:read` | — |
| GET | `/api/v1/stock_movements` | `stock_movements#index` | `stock:read` | — |
| GET | `/api/v1/reservations` | `reservations#index` | `stock:read` | — |
| POST | `/api/v1/reservations` | `reservations#create` | `stock:write` | ✓ |
| GET | `/api/v1/reservations/:id` | `reservations#show` | `stock:read` | — |
| DELETE | `/api/v1/reservations/:id` | `reservations#destroy` | `stock:write` | — |
| POST | `/api/v1/reservations/:id/commit` | `reservations#commit` | `stock:write` | ✓ |
| GET | `/api/v1/stock_transfers` | `stock_transfers#index` | `stock:read` | — |
| POST | `/api/v1/stock_transfers` | `stock_transfers#create` | `transfers:write` | ✓ |
| GET | `/api/v1/stock_transfers/:id` | `stock_transfers#show` | `stock:read` | — |
| POST | `/api/v1/stock_transfers/:id/dispatch` | `stock_transfers#dispatch_transfer` | `transfers:write` | ✓ |
| POST | `/api/v1/stock_transfers/:id/receive` | `stock_transfers#receive_transfer` | `transfers:write` | ✓ |
| GET | `/api/v1/purchase_orders` | `purchase_orders#index` | `stock:read` | — |
| POST | `/api/v1/purchase_orders` | `purchase_orders#create` | `purchases:write` | ✓ |
| GET | `/api/v1/purchase_orders/:reference` | `purchase_orders#show` | `stock:read` | — |
| POST | `/api/v1/purchase_orders/:reference/submit` | `purchase_orders#submit` | `purchases:write` | — |
| POST | `/api/v1/purchase_orders/:reference/receive` | `purchase_orders#receive_order` | `purchases:write` | ✓ |
| POST | `/api/v1/purchase_orders/:reference/cancel` | `purchase_orders#cancel` | `purchases:write` | — |
| POST | `/api/v1/stock/receive` | `stock_operations#receive` | `stock:write` | ✓ |
| POST | `/api/v1/stock/issue` | `stock_operations#issue` | `stock:write` | ✓ |
| POST | `/api/v1/stock/adjust` | `stock_operations#adjust` | `stock:write` | ✓ |
| GET | `/api/v1/reports/low_stock` | `reports#low_stock` | `stock:read` | — |
| GET | `/api/v1/reports/valuation` | `reports#valuation` | `stock:read` | — |
| GET | `/api/v1/reports/reconciliation` | `reports#reconciliation` | `stock:read` | — |

### 4.1 curl que funcionan

Generá un token (el texto plano existe **una sola vez**, en el objeto que
devuelve `issue!` — después sólo queda el digest):

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
export BASE=http://localhost:3001

export TOKEN=$(bin/rails runner 'puts ApiToken.issue!(
  user: User.first, name: "curl", scopes: ApiToken::SCOPES).plaintext')
```

Catálogo, con las cabeceras de paginación estilo GitHub:

```bash
curl -s -D - -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/products?limit=2"
```

```http
HTTP/1.1 200 OK
link: <http://localhost:3001/api/v1/products?limit=2&page=1>; rel="first",
      <http://localhost:3001/api/v1/products?limit=2&page=2>; rel="next",
      <http://localhost:3001/api/v1/products?limit=2&page=8>; rel="last"
current-page: 1
page-items: 2
total-pages: 8
total-count: 15
etag: W/"e4e2db703e7702e08a5f970166b2cbeb"
x-request-id: a5393b31-b9ed-4e58-aafa-04d8bcfb3386
```

Operaciones de stock:

```bash
# Ingreso (201) — con clave de idempotencia
curl -s -X POST "$BASE/api/v1/stock/receive" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"sku":"AMO-115","warehouse_code":"BA-01","quantity":5,"reason":"Remito 1234"}'

# Egreso
curl -s -X POST "$BASE/api/v1/stock/issue" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sku":"AMO-115","warehouse_code":"BA-01","quantity":2}'

# Ajuste por conteo físico: manda el ABSOLUTO contado, no el delta
curl -s -X POST "$BASE/api/v1/stock/adjust" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sku":"AMO-115","warehouse_code":"BA-01","counted_quantity":95,"reason":"Conteo cíclico"}'
```

Respuesta real del `receive`:

```json
{"data":{"id":1275106,"kind":"receipt","quantity":5,"quantity_after":59,
  "product":{"id":9,"sku":"AMO-115","name":"Amoladora angular 115mm"},
  "warehouse":{"id":1,"code":"BA-01"},"user":{"id":1,"name":"Ana Admin"},
  "unit_cost":{"cents":190000,"currency":"ARS","formatted":"ARS 1900.00"},
  "reason":"doc","occurred_at":"2026-08-30T18:25:28.263Z"}}
```

Reservas (el flujo de dos fases: reservás, después confirmás o liberás):

```bash
curl -s -X POST "$BASE/api/v1/reservations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sku":"AMO-115","warehouse_code":"BA-01","quantity":2,"ttl_seconds":3600}'
# => 201 {"data":{"id":5,"status":"held",...,"expires_at":"2026-08-30T19:28:18.564Z"}}

curl -s -X POST "$BASE/api/v1/reservations/5/commit" -H "Authorization: Bearer $TOKEN"
curl -s -X DELETE "$BASE/api/v1/reservations/5" -H "Authorization: Bearer $TOKEN"
```

Ledger con cursor, y reportes:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/v1/stock_movements?limit=50&sku=AMO-115&kinds=receipt,issue"

curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/reports/valuation"
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/reports/reconciliation"
# => {"data":[],"meta":{"count":0,"healthy":true}}
```

---

## 5. Códigos de estado: el mapa completo de este repo

El contrato vive en **un solo lugar**
(`STATUS_FOR` en `app/controllers/concerns/api/error_handling.rb`), y eso es deliberado: si el
mapeo dominio→HTTP estuviera esparcido por los controllers, el mismo error de
negocio devolvería 409 en un endpoint y 422 en otro.

```ruby
STATUS_FOR = {
  insufficient_stock:           :unprocessable_content,   # 422
  insufficient_available_stock: :unprocessable_content,   # 422
  invalid_quantity:             :unprocessable_content,   # 422
  validation_failed:            :unprocessable_content,   # 422
  reason_required:              :unprocessable_content,   # 422
  invalid_transition:           :unprocessable_content,   # 422
  nothing_to_receive:           :unprocessable_content,   # 422
  product_discarded:            :unprocessable_content,   # 422
  warehouse_inactive:           :unprocessable_content,   # 422
  reservation_expired:          :gone,                    # 410
  reservation_not_active:       :conflict,                # 409
  conflict:                     :conflict,                # 409
  duplicate:                    :conflict,                # 409
  locked:                       :conflict,                # 409
  stock_item_not_found:         :not_found,               # 404
  not_found:                    :not_found,               # 404
  forbidden:                    :forbidden                # 403
}.freeze
```

Y el mapa completo, incluyendo lo que producen los `rescue_from` y los concerns:

| Status | Cuándo lo devuelve este repo | Origen |
|---|---|---|
| **200** | Lectura, o comando que muta un recurso existente (`commit`, `submit`, `cancel`) | `render_result` |
| **201** | Se creó una fila nueva del ledger o del dominio | `success_status: :created` |
| **204** | `DELETE /products/:sku` (soft delete, sin body) | `head :no_content` |
| **400** | Falta un parámetro (`parameter_missing`), vino uno no permitido (`unpermitted_parameters`), el body no es JSON válido (`malformed_body`) o un valor no castea (`bad_request`) | `rescue_from ParameterMissing` / `UnpermittedParameters` / `ParseError` / `BadRequest` |
| **401** | Token ausente, inválido, vencido o revocado. **Siempre con `WWW-Authenticate`** | `token_authentication.rb`, `authenticate_api_token!` |
| **403** | Token sin el scope (`insufficient_scope`), usuario deshabilitado (`account_disabled`), policy de Pundit | `require_scope!` / `render_forbidden` |
| **404** | SKU/código/reference que no existe. **Sin decir de qué modelo** | `render_not_found` |
| **409** | Optimistic locking perdido, `RecordNotUnique`, `LockWaitTimeout`, clave de idempotencia en vuelo, reserva ya no activa | `render_conflict` / `idempotency_conflict` |
| **410** | La reserva **venció** | `reservation_expired` |
| **422** | Regla de negocio violada; clave de idempotencia reusada con otro body | `STATUS_FOR` |
| **429** | Rate limit, en dos capas (ver `docs/08`). La del controller manda sólo `Retry-After`; las cabeceras `RateLimit-*` las agrega Rack::Attack en `throttled_responder` | `rate_limited!` / `Rack::Attack` |
| **500** | Bug. Mensaje genérico + `request_id` para soporte | `render_internal_error` |

### 5.0 Los dos 400 que NO salían con este formato (arreglado)

Esto **estuvo roto en este repo** y vale entenderlo entero, porque el modo de
falla es de los que no se ven en un test mal escrito. La tabla de arriba vale
para lo que pasa por `rescue_from`; había dos caminos que devolvían 400 **sin**
el JSON de la API, y son la fuente número uno de tickets tipo "su API me
devuelve HTML":

| Caso | Excepción | Qué pasaba |
|---|---|---|
| `quantity` no entera | `ActionController::BadRequest` (la levanta `quantity_param`, `stock_operations_controller.rb:97`) | No había `rescue_from` para ella |
| Body JSON roto | `ActionDispatch::Http::Parameters::ParseError` | Tampoco |

Las dos son `StandardError`, así que el comportamiento **cambiaba según el
entorno**, y ese era el detalle feo:

- En **dev/test** `rescue_from StandardError` no está registrado
  (`error_handling.rb:24` lo declara `unless Rails.env.local?`), así que la
  excepción salía del controller, la agarraba `ActionDispatch::ShowExceptions` y
  el cliente recibía **400 con `content-type: text/html`** (`public/400.html`).
- En **producción** sí está registrado, y como `rescue_from` busca handlers en
  orden inverso al de declaración y ninguno de los específicos matcheaba, la
  atrapaba el de `StandardError` → **500 `internal_error` en JSON**.

O sea: el mismo request daba 400-HTML en desarrollo y 500-JSON en producción, y
en ninguno de los dos casos daba el 400-JSON que el contrato promete. Y el
request spec que lo cubría (`stock_operations_spec.rb:104`) sólo asertaba el
**status**, nunca el `content-type` ni el body — por eso pasaba verde.

**Hoy están los dos `rescue_from`** (`error_handling.rb`, líneas 37-38):

```ruby
rescue_from ActionController::BadRequest, with: :render_bad_request
rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_malformed_body
```

Verificado contra la app corriendo, en los dos casos:

```bash
curl -s -D - -X POST "$BASE/api/v1/stock/receive" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"sku": '
# HTTP/1.1 400 Bad Request
# content-type: application/json; charset=utf-8
# {"error":{"code":"malformed_body","message":"El cuerpo de la solicitud no es JSON válido."},"status":400}

curl -s -X POST "$BASE/api/v1/stock/receive" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"sku":"AMO-115","warehouse_code":"BA-01","quantity":"abc"}'
# {"error":{"code":"bad_request","message":"El parámetro 'quantity' debe ser un entero"},"status":400}
```

Fijate que `render_malformed_body` **no** devuelve `exception.message`: el mensaje
del parser incluye el contenido del body y la posición exacta del error, o sea
un canal de sondeo gratis para un atacante. El de `BadRequest` sí lo devuelve
porque ese mensaje lo escribimos nosotros en `quantity_param`.

La regresión la fija `spec/requests/api/v1/hardening_spec.rb`, y —lección del
bug— aserta **status + `media_type` + `code`**, no sólo el status. El detalle
completo del diagnóstico está en el error #4 de la sección de producción.

### 5.1 409 vs 422 vs 410 — el criterio

Los tres significan "tu request está bien formada pero no la puedo hacer". La
diferencia está en **qué tiene que hacer el cliente después**:

| Status | Significa | Qué hace el cliente |
|---|---|---|
| **422** | El *contenido* es inválido contra las reglas de negocio | Corregir el body y reintentar. Reintentar igual siempre va a fallar |
| **409** | El contenido está bien; el **estado del servidor** no lo permite *ahora* | Releer el recurso y reintentar. **Puede funcionar sin cambiar nada** |
| **410** | El recurso existía y **ya no existe para siempre** | No reintentar nunca. Empezar de cero |

Aplicado al repo:

- `insufficient_stock` es **422**: pedís 500 unidades y hay 100. Reintentar el
  mismo body falla igual. El error trae el detalle accionable:
  ```json
  {"error":{"code":"insufficient_stock",
            "message":"Stock insuficiente: hay 59, se pidieron 999999",
            "details":{"available":59,"requested":999999,"product_id":9,"warehouse_id":1}},
   "status":422}
  ```
- `conflict` (`StaleObjectError`) es **409**: mandaste un `lock_version` viejo.
  Releés, mandás el nuevo, funciona. Verificado:
  ```bash
  curl -s -X PATCH "$BASE/api/v1/products/AMO-115" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d '{"lock_version":99,"product":{"name":"X"}}'
  # 409 {"error":{"code":"conflict","message":"El recurso fue modificado por otra operación. Recargá y reintentá."},"status":409}
  ```
- `reservation_expired` es **410**: la reserva venció, el stock ya se liberó, ese
  id no vuelve. Verificado:
  ```bash
  curl -s -X POST "$BASE/api/v1/reservations/5/commit" -H "Authorization: Bearer $TOKEN"
  # 410 {"error":{"code":"reservation_expired","message":"La reserva venció el 2026-08-30T17:28:19Z"},"status":410}
  ```
  Fijate el matiz frente a `reservation_not_active` (409): "ya la commiteaste" es
  un conflicto de estado recuperable leyendo; "venció" es terminal.

### 5.2 Por qué 422 y no 400

**400 Bad Request** es un problema de **sintaxis / protocolo**: el servidor no
puede parsear lo que mandaste. JSON roto, falta un campo requerido, un tipo que
no castea. Es lo que devuelve este repo cuando falta `warehouse_code`:

```json
{"error":{"code":"parameter_missing","message":"Falta el parámetro 'warehouse_code'.",
          "details":{"param":"warehouse_code"}},"status":400}
```

**422 Unprocessable Content** (RFC 9110 §15.5.21) es: *"entendí perfectamente tu
JSON, la sintaxis está bien, pero el contenido viola una regla semántica"*. Es
exactamente "no hay stock", "la orden no se puede cancelar en estado `received`".

Por qué importa la distinción operativamente:

- **El cliente decide distinto.** Un 400 significa "hay un bug en mi código de
  serialización" → alerta al equipo. Un 422 significa "el usuario pidió algo
  imposible" → mostrale el mensaje. Si mandás todo como 400, el dashboard de
  errores del cliente se llena de ruido y nadie mira las alertas.
- **Los proxies y WAFs tratan distinto el 400.** Algunos lo cuentan como request
  malformada y lo usan para banear. Un 422 no dispara eso.

Detalle de Rails 8: el símbolo canónico es `:unprocessable_content`.
`:unprocessable_entity` sigue funcionando pero está deprecado — el nombre "Entity"
venía de WebDAV y RFC 9110 lo renombró. Los dos son 422.

### 5.3 Trampa de nomenclatura para el javero

En Spring devolvés `ResponseEntity.status(HttpStatus.UNPROCESSABLE_ENTITY)`. En
Rails escribís un **símbolo**, y `Rack::Utils::SYMBOL_TO_STATUS_CODE` lo traduce.
La trampa: **si escribís mal el símbolo, no explota en compilación** (no hay
compilación) sino en runtime. Verificado con `Rack::Utils.status_code`:

```ruby
Rack::Utils.status_code(:unprocessable_content)   # => 422
Rack::Utils.status_code(:unprocessable_entity)    # => 422, con warning de Rack:
#   "Status code :unprocessable_entity is deprecated ... use :unprocessable_content"
Rack::Utils.status_code(:unprocessible_content)   # ArgumentError: Unrecognized status code
```

Un `:unprocessible_content` con typo llega a producción si no hay un request spec
que lo toque. En Java el enum te lo agarra el compilador. Acá te lo agarra el
test — por eso los request specs no son opcionales.

---

## 6. Formato de errores: RFC 9457 (Problem Details)

Todo error de esta API sale con la misma forma, armada en
`app/serializers/error_serializer.rb`:

```json
{
  "error": {
    "code": "insufficient_stock",
    "message": "Stock insuficiente: hay 59, se pidieron 999999",
    "details": {"available": 59, "requested": 999999, "product_id": 9, "warehouse_id": 1}
  },
  "status": 422
}
```

Tres métodos de fábrica, uno por origen del error
(`error_serializer.rb:7`, `:18`, `:31`):

| Método | Origen | `code` |
|---|---|---|
| `from_result(result, status:)` | Un `Result.failure` de un service | el `code` del `Result::Error` |
| `from_record(record, status:)` | Un `ActiveRecord::RecordInvalid` | siempre `validation_failed`, con `details` = `errors.to_hash(true)` |
| `simple(code, message, status:, **details)` | Errores de transporte/auth armados en el controller | el que le pasás |

### 6.1 Qué dice RFC 9457 y qué hace este repo

El estándar define un objeto con estos campos y el content type
`application/problem+json`:

| Campo RFC 9457 | Qué es | Equivalente acá |
|---|---|---|
| `type` | URI que identifica el *tipo* de problema (y sirve de doc) | ✗ no está — el rol lo cumple `error.code` |
| `title` | Resumen legible, **estable** para ese `type` | ✗ (el `message` es variable) |
| `status` | El status HTTP, duplicado en el body | ✓ `status` |
| `detail` | Explicación específica de *esta* ocurrencia | ✓ `error.message` |
| `instance` | URI de esta ocurrencia | ✗ (parcial: `request_id` en el 500) |
| *extensiones* | Campos propios | ✓ `error.details` |

O sea: **este repo sigue el espíritu, no la letra** — y el comentario del archivo
lo dice así, honestamente. Si querés cumplir de verdad, el cambio es chico y vale
la pena conocerlo:

```ruby
# Cómo se vería cumpliendo RFC 9457 al pie de la letra
{
  type: "https://docs.stock.test/errors/insufficient-stock",
  title: "Stock insuficiente",
  status: 422,
  detail: "Stock insuficiente: hay 59, se pidieron 999999",
  instance: "/api/v1/stock/issue##{request.request_id}",
  available: 59, requested: 999999
}
# y render json: problem, status: 422, content_type: "application/problem+json"
```

La diferencia práctica entre `title` y `detail` es la que más se pasa por alto:
**`title` tiene que ser estable** para poder agrupar en Sentry/Datadog. Si tu
título incluye "hay 59, se pidieron 999999", cada ocurrencia es un grupo distinto
y el dashboard es inútil. En este repo el que cumple ese rol es `error.code`, que
sí es estable — por eso los tests asertan sobre `code`, nunca sobre `message`.

### 6.2 La regla de oro: nunca `e.message` crudo

```ruby
# app/controllers/concerns/api/error_handling.rb, #render_internal_error
def render_internal_error(exception)
  Rails.logger.error(event: "api.internal_error", request_id: request.request_id,
                     exception: exception.class.name, message: exception.message,
                     backtrace: exception.backtrace&.first(15))
  render_error(:internal_error,
               "Ocurrió un error inesperado. Contactá a soporte con este id.",
               status: :internal_server_error, request_id: request.request_id)
end
```

Un `PG::UndefinedColumn` crudo te filtra nombres de tablas y columnas; un
`PG::UniqueViolation` te filtra el nombre del índice y a veces **el valor que
colisionó** (o sea, datos de otro usuario). Detalle completo al log, `request_id`
al cliente.

⚠️ El repo **rompía su propia regla** en un camino, y es el ejemplo perfecto de
por qué la regla hay que aplicarla en cada `rescue`, no sólo en el handler
genérico: `application_service.rb:80` traducía `RecordNotUnique` a un
`Result.failure(:duplicate, ..., detail: e.message)`, y ese `e.message` —índice y
valor colisionado incluidos— viajaba al cliente dentro de `error.details` del
409. **Hoy el mensaje va al log y el body sale pelado**:

```ruby
# app/services/application_service.rb:80
rescue ActiveRecord::RecordNotUnique => e
  Rails.logger.warn(event: "service.duplicate", error: e.message)
  Result.failure(:duplicate, "Ya existe un registro con esos datos.")
```

Verificado pasando un `RecordNotUnique` real por la misma traducción: el `details`
ya no existe en la respuesta.

```json
{"error":{"code":"duplicate","message":"Ya existe un registro con esos datos."},"status":409}
```

El detalle completo y el antes/después están en el error #6 de la sección de
producción; la regresión la cubre `spec/requests/api/v1/hardening_spec.rb`, que
aserta que el body no contenga `PG::`, ni `index_…`, ni `DETAIL`.

Lo mismo con el 404 (`render_not_found`): no decimos qué modelo era. Si
`GET /products/X` dijera "Couldn't find Product with sku=X", ya confirmaste que
existe un modelo `Product` y que la clave es `sku`; y peor, un 404 que distingue
"no existe" de "existe pero no es tuyo" es un oráculo de enumeración.

### 6.3 Cómo se prueba

Los request specs asertan **status + `code` + `details`**, nunca el `message`
(`spec/requests/api/v1/stock_operations_spec.rb:111`):

```ruby
it "422 cuando no alcanza el stock, con detalle accionable" do
  post "/api/v1/stock/issue", params: payload(quantity: 500), headers: headers
  expect(response).to have_http_status(:unprocessable_content)
  error = response.parsed_body["error"]
  expect(error["code"]).to eq("insufficient_stock")
  expect(error["details"]).to include("available" => 100, "requested" => 500)
end
```

Y hay un test que verifica que el 404 **no filtra** el nombre del modelo
(línea 95): `expect(...dig("error","message")).not_to include("Product")`. Ese
test es el que evita que alguien "mejore" el mensaje de error y abra el oráculo.

Un matiz que salió de un bug real (§5.0): **asertar sólo el status no alcanza**.
El caso del 400 pasaba verde con `expect(response).to have_http_status(:bad_request)`
mientras el cuerpo era una página HTML. Por eso los tests nuevos de
`spec/requests/api/v1/hardening_spec.rb` asertan también `response.media_type` y
el `code`, y hay uno que verifica lo que el error **no** dice:

```ruby
it "no filtra el detalle del parser en el mensaje" do
  post "/api/v1/stock/receive", params: '{"sku": "SECRETO', headers: headers
  expect(response.body).not_to include("SECRETO")
end
```

---

## 7. Idempotencia (el corazón del asunto)

### 7.1 El problema, planteado bien

Un cliente manda `POST /api/v1/stock/receive` con 500 unidades. El servidor las
aplica, escribe el ledger, encola el evento… y la respuesta se pierde: timeout
del balanceador, se cortó la 4G del operario del depósito, el pod se reinició
justo después del `COMMIT`.

El cliente queda en **estado indeterminado**. Sus dos opciones son malas:

- **Reintenta** → puede duplicar 500 unidades de mercadería que no existen.
- **No reintenta** → puede haber perdido un ingreso real, y el inventario queda
  descuadrado hasta el próximo conteo físico.

No hay forma de resolver esto sólo del lado del cliente. La única salida es que
el servidor pueda reconocer "esto es el mismo intento" y garantizar
**exactly-once effect**.

### 7.2 Por qué GET, PUT y DELETE son idempotentes y POST no

Idempotente en HTTP (RFC 9110 §9.2.2) significa: *el efecto en el servidor de N
requests idénticas es el mismo que el de una*. No significa "devuelve lo mismo".

| Método | Idempotente | Por qué |
|---|---|---|
| `GET` | ✓ | No muta nada (es además *safe*) |
| `HEAD`, `OPTIONS`, `TRACE` | ✓ | Idem |
| `PUT` | ✓ | Semántica de **reemplazo total**: "el recurso queda así". Mandarlo 5 veces deja el mismo estado |
| `DELETE` | ✓ | "El recurso no existe". Repetirlo lo deja igual de inexistente (el status puede cambiar 204→404, pero el **estado** no) |
| `PATCH` | ✗ (en general) | Depende del patch. `{"name":"x"}` sí; `{"op":"increment","by":1}` no |
| `POST` | ✗ | Semántica de **"procesá esto"**: cada request es un evento nuevo |

**La confusión típica del que viene de Java**: creer que idempotente = "devuelve
la misma respuesta". No. `DELETE /x` puede devolver 204 la primera vez y 404 la
segunda: **sigue siendo idempotente**, porque el estado del servidor es el mismo.

Y el punto clave: `POST /stock/receive` con `quantity: 10` **no puede** ser
idempotente por diseño, porque dos ingresos de 10 unidades *son legítimamente dos
ingresos*. El servidor no tiene forma de distinguir "reintento" de "segundo
camión" mirando el body. Por eso hace falta una clave explícita.

> ¿Y por qué no hacemos `PUT /stock_items/AMO-115@BA-01 {"quantity_on_hand": 59}`,
> que sería naturalmente idempotente? Porque perdés el ledger: `PUT` dice "quedá
> en 59" y no registra **por qué**. En un dominio auditable, el estado es una
> proyección de eventos, no la fuente de verdad. Además introducís lost updates
> masivos: dos operarios leen 54, los dos escriben 59, se pierde un ingreso.

### 7.3 Por qué la clave la genera el cliente

```ruby
# app/controllers/concerns/api/idempotency.rb:33
HEADER = "HTTP_IDEMPOTENCY_KEY"
```

**Sólo el cliente sabe que dos requests son "el mismo intento".** El servidor ve
dos POSTs idénticos y no puede inferir nada: pueden ser un retry o dos camiones.
El cliente sí sabe: genera un UUID *antes* del primer intento, lo guarda junto al
trabajo pendiente, y lo reusa en cada reintento del **mismo** trabajo.

La regla para el cliente, que hay que documentar explícitamente:

> Generá la clave **una vez por operación de negocio**, no una por request HTTP.
> Si la generás dentro del loop de retry, la idempotencia no hace absolutamente
> nada y no te vas a enterar hasta que dupliques algo.

Alternativa "server-side dedup" (hashear el body y rechazar duplicados dentro de
una ventana): es **incorrecta** para este dominio. Rechaza operaciones legítimas
repetidas y es una fuente de bugs de negocio dificilísimos de diagnosticar.

### 7.4 El fingerprint del body: el ataque que previene

Esta es la parte que se olvida el 80% de las implementaciones caseras.

```ruby
# app/controllers/concerns/api/idempotency.rb:88
fingerprint = IdempotencyKey.fingerprint(request.raw_post)
# app/models/idempotency_key.rb:18
def self.fingerprint(payload) = OpenSSL::Digest::SHA256.hexdigest(payload.to_s)
```

Guardamos el SHA-256 del body junto a la clave. Si llega la misma clave con un
body **distinto**, devolvemos 422 en vez de la respuesta vieja.

Sin el fingerprint, dos escenarios feos:

**a) Cliente con bug (el común).** Alguien hardcodea `Idempotency-Key: pedido-1`
o usa un contador que se reinicia con el proceso. Manda `receive 10`, después
`receive 500`. Sin fingerprint recibe **200 con la respuesta del receive de 10**,
cree que se aplicó, y el ingreso de 500 nunca ocurrió. Pérdida de datos
silenciosa: nadie ve un error, el inventario simplemente está mal.

**b) Ataque de confusión (el peligroso).** Un atacante que puede observar o
adivinar claves ajenas manda una request con la clave de otro y un body suyo. Sin
fingerprint, dependiendo del orden, o le devolvés la respuesta de la víctima
(fuga de información) o **suprimís la operación de la víctima** (denegación
silenciosa). El fingerprint corta las dos: clave repetida + body distinto = 422,
sin ejecutar nada y sin revelar nada.

Verificado en vivo:

```bash
KEY=$(uuidgen)
# 1) 201 Created
curl -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: $KEY" ... -d '{"...","quantity":5}'
# 2) mismo body -> 201 + idempotent-replay: true, MISMO id de movimiento
# 3) body distinto, misma clave:
curl -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: $KEY" ... -d '{"...","quantity":99}'
# => 422 {"error":{"code":"idempotency_key_reuse",
#          "message":"Esta clave ya se usó con un cuerpo distinto."},"status":422}
```

Y el complemento imprescindible: **el scoping por usuario**
(`idempotency.rb:68`, y el índice único `(user_id, key)` en la migración):

```ruby
def idempotency_key
  key = raw_idempotency_key
  return nil if key.nil?
  "u#{current_user&.id || 'anon'}:#{key}"
end
```

Este prefijo existe porque la columna `stock_movements.idempotency_key` tiene un
índice único **global**. Si el usuario A manda `Idempotency-Key: pedido-1` y el
usuario B (otra empresa) manda `pedido-1`, sin el prefijo el service encontraría
el movimiento de A y se lo devolvería a B: fuga de datos + pérdida de la
operación de B, en silencio. Con claves tipo `"1"` o `"pedido-1"` —que la gente
usa— la colisión no es hipotética. El test que cubre la regresión está en
`spec/requests/api/v1/stock_operations_spec.rb:163`.

### 7.5 La máquina de estados

```text
                        ┌──────────────────────────────────────────┐
   POST + Idempotency-Key                                          │
            │                                                      │
            ▼                                                      │
   ┌────────────────────┐   fingerprint distinto    ┌──────────────┴──┐
   │ ¿existe fila live? │──────────────────────────▶│ 422 key_reuse    │
   └────────┬───────────┘                           └─────────────────┘
       no   │   sí
            │    ├── status = completed ──▶ 200/201 + Idempotent-Replay: true
            │    ├── status = processing ─▶ 409 idempotency_conflict
            │    └── status = failed ─────▶ vuelve a 'processing' y REEJECUTA
            ▼
   INSERT (status: 'processing')
            │
            ├── RecordNotUnique (perdí la carrera) ──▶ 409 idempotency_conflict
            │
            ▼
      yield  (corre la acción)
            │
            ├── response 2xx ──▶ UPDATE status='completed', guarda status + body
            ├── response ≠2xx ─▶ UPDATE status='failed' (NO cachea el body)
            └── EXCEPCIÓN ──────▶ UPDATE status='failed' y RE-RAISE (que el
                                  rescue_from haga su trabajo)
```

Esa última rama **estuvo rota**: si la acción levantaba una excepción que atrapa
un `rescue_from` (404, 403, 400…), `persist_response` no llegaba a correr y la
clave quedaba trabada en `processing` hasta que vencía el TTL. El error #1 de la
sección de producción tiene la reproducción completa. El arreglo vive hoy en
`idempotency.rb` y no es un `ensure`, por un motivo que vale la pena tener claro
(ver §7.7).

Los tres estados salen del modelo (`app/models/idempotency_key.rb:8`) y están
además protegidos por un `CHECK` en Postgres
(`db/migrate/20260830161200_create_idempotency_keys.rb`), o sea que ni un
`update_column` te puede meter un estado inventado.

El despacho usa **pattern matching** de Ruby 3 (`idempotency.rb:101`):

```ruby
case record
in { replay: true, record: IdempotencyKey => stored }
  skip_pundit_verification
  response.set_header("Idempotent-Replay", "true")
  render json: stored.response_body, status: stored.response_status
in { conflict: true }  then ... 409
in { mismatch: true }  then ... 422
in { record: IdempotencyKey => fresh }
  begin
    yield
  rescue StandardError
    mark_failed(fresh)   # la clave NO se quema con un error del cliente
    raise                # y el rescue_from renderiza normalmente
  else
    persist_response(fresh)
  end
end
```

Dos detalles que valen para la entrevista:

- `in { replay: true, record: IdempotencyKey => stored }` chequea **estructura y
  tipo** y liga la variable, todo en una línea. En Java es `instanceof` + cast, o
  los *record patterns* de Java 21 con sealed interfaces.
- **`case/in` levanta `NoMatchingPatternError` si nada matchea**, a diferencia de
  `case/when`, que devuelve `nil` en silencio. En una máquina de estados eso es
  exactamente lo que querés: un estado no contemplado tiene que ser ruidoso.

### 7.6 El índice UNIQUE como lock distribuido

Esta es la parte elegante y la que más se pregunta.

```ruby
# app/controllers/concerns/api/idempotency.rb:163
def claim_key(key, fingerprint)
  existing = IdempotencyKey.live.find_by(user_id: current_user&.id, key:)
  # ... chequeos de estado ...
  record = IdempotencyKey.create!(user: current_user, key:, ..., status: "processing")
  { record: }
rescue ActiveRecord::RecordNotUnique
  { conflict: true }   # carrera perdida: otra request idéntica está en vuelo AHORA
end
```

El `find_by` + `create!` es un **check-then-act**, o sea una condición de carrera
de manual. Y está bien que lo sea, porque **el índice único es la sección
crítica**: si dos requests con la misma clave llegan al mismo tiempo, las dos
pasan el `find_by` (ninguna ve nada), las dos intentan el `INSERT`, y Postgres
deja pasar **una sola**. La otra recibe `RecordNotUnique` → 409.

```sql
-- db/migrate/20260830161200_create_idempotency_keys.rb
CREATE UNIQUE INDEX index_idempotency_keys_on_user_id_and_key
  ON idempotency_keys (user_id, key);
```

Por qué esto es mejor que las alternativas:

| Mecanismo | Problema |
|---|---|
| `Mutex` de Ruby | Sólo protege **un proceso**. Con 4 workers de Puma no protege nada |
| `SETNX` en Redis | Funciona, pero es **otro sistema**: si Redis se cae o se desincroniza del commit de Postgres, la clave dice "hecho" y la transacción hizo rollback |
| `SELECT ... FOR UPDATE` | Necesitás una fila que ya exista para lockear. Justo lo que no tenés |
| `pg_advisory_lock` | Válido, pero es un lock explícito que hay que soltar; el índice único ya te lo da **transaccionalmente** |
| **Índice único** | Atómico, durable, en la **misma transacción** que el trabajo. Cero infraestructura extra |

**El punto que hay que decir**: el lock y el efecto viven en la misma base y en
la misma transacción, así que no existe la ventana "commiteé el trabajo pero no
la marca" ni al revés. Eso es lo que te compra la falta de un sistema externo.

**Contraste con Java**: la analogía natural es `@Transactional` +
`DataIntegrityViolationException`, o un `ShedLock`/Redisson distribuido. La
analogía **se rompe** en un punto importante: en Postgres, después de un error de
constraint la transacción queda **abortada** — cualquier query siguiente devuelve
`current transaction is aborted`. Si este `create!` estuviera adentro de una
transacción más grande, el `rescue RecordNotUnique` no alcanzaría: necesitarías
un `SAVEPOINT` (que en Rails es `transaction(requires_new: true)`). Acá funciona
porque el `claim_key` corre **fuera** de la transacción de negocio, antes del
`yield`. En Hibernate/JPA esto no te muerde igual porque el flush es diferido; en
ActiveRecord el `INSERT` sale ya mismo.

### 7.7 Qué respuestas se cachean

```ruby
# app/controllers/concerns/api/idempotency.rb:194
def persist_response(record)
  if response.successful?
    record.update!(status: "completed", response_status: response.status,
                   response_body: safe_parse(response.body))
  else
    record.update!(status: "failed", response_status: response.status)
  end
end
```

**Sólo 2xx.** Y la razón es contundente: si cachearas un 500, ese cliente
recibiría ese mismo 500 **para siempre** (24 h, el TTL) aunque el bug ya esté
arreglado y aunque la operación sea perfectamente válida. El estado `failed`
además **libera** la clave: el próximo intento con la misma clave vuelve a
`processing` y **reejecuta** (`claim_key`, línea 173). Un error no debe quemar la
clave.

Trade-off que conviene admitir: un 422 tampoco se cachea, así que si el cliente
reintenta con el mismo body, vuelve a correr toda la validación. Es más caro pero
correcto: las reglas de negocio pueden haber cambiado (llegó stock).

⚠️ **Acá estuvo el agujero, y el arreglo tiene una trampa adentro.** Todo lo de
arriba valía sólo para los errores que se renderizan por `render_result`, o sea
los fallos de negocio. Los que viajan como **excepción** hasta un `rescue_from`
—404, 403, 400, `StaleObjectError`, `RecordInvalid`— nunca llegaban a
`persist_response`, porque `rescue_from` vive por fuera del `around_action`: esa
clave no quedaba en `failed`, quedaba en `processing`, y el reintento recibía 409
durante 24 horas.

Lo interesante es **por qué el arreglo obvio no sirve**. El reflejo es envolver
el `yield` en un `ensure` y llamar a `persist_response` ahí. No alcanza: el
`ensure` corre mientras la excepción viaja hacia arriba, o sea **antes** de que
el `rescue_from` renderice. En ese momento `response.status` todavía es 200 y
`response.successful?` da `true`, así que marcarías la clave como `completed`
guardando un cuerpo vacío — cambiás un bug por otro peor, porque ahora el
reintento devuelve un 200 vacío en vez de un 409.

Por eso el código usa **`rescue`/`else`**: en el camino de excepción marca
`failed` y **re-lanza** (para que el `rescue_from` haga su trabajo); en el camino
limpio, y sólo ahí, persiste la respuesta real. Verificado contra la app
corriendo: después de un 404, la fila queda en `failed` y el reintento con el
mismo body **vuelve a ejecutar** en vez de devolver 409. La regresión está en
`spec/requests/api/v1/hardening_spec.rb` ("permite reintentar con la misma clave
después de un 404"). El antes/después completo, en el error #1 de la sección de
producción.

### 7.8 TTL y limpieza

```ruby
DEFAULT_TTL = 24.hours                        # app/models/idempotency_key.rb:6
scope :live, -> { where(expires_at: Time.current..) }
before_validation { self.expires_at ||= DEFAULT_TTL.from_now }
```

Fijate que el `find_by` de `claim_key` usa `IdempotencyKey.live`: una clave
vencida **no se encuentra**, así que se puede reusar y la operación se ejecuta de
nuevo. Es una decisión, no un descuido: pasadas 24 h, un cliente que manda la
misma clave casi seguro está haciendo una operación nueva.

Stripe usa 24 h también. El criterio: el TTL tiene que cubrir con margen la
ventana máxima de reintentos de tu cliente más lento (colas con backoff
exponencial + dead letter + reproceso manual). Si tu cliente reprocesa una DLQ a
las 48 h, un TTL de 24 h te duplica la operación.

El borrado va por lotes (`app/jobs/cleanup/expired_records_job.rb`), no de un
saque:

```ruby
IdempotencyKey.where(expires_at: ...Time.current).in_batches(of: 5_000, &:delete_all)
```

En Postgres un `DELETE` no libera espacio: deja tuplas muertas que el autovacuum
tiene que limpiar. Borrar 190M de filas de golpe hincha la tabla (bloat) y
degrada las queries aunque queden pocas filas vivas. `in_batches` pagina por PK
(`WHERE id > ?`), no con `OFFSET`, y hace una transacción corta por lote. A
escala real, la respuesta buena es **particionar por fecha y hacer
`DROP PARTITION`**, que es instantáneo y no genera tuplas muertas.

### 7.9 Comparación con Stripe

| Aspecto | Stripe | Este repo |
|---|---|---|
| Cabecera | `Idempotency-Key` | igual |
| Quién genera | el cliente (UUID v4 recomendado) | igual |
| TTL | 24 h | 24 h (`DEFAULT_TTL`) |
| Obligatoria | recomendada para POST; algunos endpoints la exigen | **opcional** (`return yield if key.blank?`) |
| Body distinto, misma clave | error | 422 `idempotency_key_reuse` |
| Request en vuelo | 409 `idempotency_error` | 409 `idempotency_conflict` |
| Marca el replay | `Idempotent-Replayed: true` | `Idempotent-Replay: true` |
| Alcance de la clave | por cuenta de API | por `user_id` |
| Errores cacheados | sí, cachea también errores | **no**, sólo 2xx |
| Reintentos del SDK | el SDK reintenta solo con la misma clave | el cliente lo implementa |

Dos diferencias defendibles:

1. **Opcional**: forzar la cabecera rompería clientes existentes. En una API de
   pagos la haría obligatoria para todo POST. La nota está en el propio código.
2. **No cachear errores**: Stripe sí lo hace, lo cual es más estricto (te obliga
   a cambiar la clave para reintentar). Nuestra elección favorece la
   recuperabilidad automática; el costo es que un cliente en loop puede repetir
   una operación que falla, y por eso el rate limit por token importa.

Nombre de la cabecera de replay: la nuestra es `Idempotent-Replay`, la de Stripe
`Idempotent-Replayed`. Es una cabecera custom, no hay estándar, pero **el
borrador IETF `draft-ietf-httpapi-idempotency-key-header` sí estandariza el
nombre `Idempotency-Key`**, que es el que importa.

### 7.10 Cómo se prueba

`spec/requests/api/v1/stock_operations_spec.rb:126-171`. Los cinco casos que
tiene que cubrir cualquier implementación:

```ruby
it "el reintento devuelve la MISMA respuesta y no aplica dos veces" do
  post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem
  primera = response.parsed_body
  post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem

  expect(response).to have_http_status(:created)
  expect(response.parsed_body).to eq(primera)
  expect(response.headers["Idempotent-Replay"]).to eq("true")
  expect(item.reload.quantity_on_hand).to eq(110)   # sumó 10 UNA vez
end
```

| Test | Qué protege |
|---|---|
| reintento devuelve lo mismo y aplica una vez | el caso feliz |
| misma clave + otro body → 422 | el fingerprint |
| claves distintas aplican las dos | que no estés deduplicando de más |
| sin cabecera funciona normal | que sea opcional |
| claves scopeadas por usuario | la fuga entre tenants |

**Lo que falta y hay que saber decirlo**: no hay test de la carrera real **a
nivel HTTP** (`RecordNotUnique` → 409). Sí hay uno a nivel de servicio
(`spec/integration/concurrency_spec.rb`, "la misma clave desde 5 threads aplica
UNA sola vez", que aserta `StockMovement.where(idempotency_key: key).count == 1`),
pero eso cubre el índice único de `stock_movements`, no el 409 del concern. Para
el 409 se usa `spec/support/concurrency.rb`, con dos threads y conexiones
distintas, o —más barato y determinista— insertando a mano una fila en
`processing` y disparando la request. Así lo verifiqué:

```bash
bin/rails runner 'IdempotencyKey.create!(user_id: 1, key: "en-vuelo",
  request_path: "/api/v1/stock/receive", request_method: "POST",
  request_fingerprint: IdempotencyKey.fingerprint(BODY), status: "processing")'

curl -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: en-vuelo" ... 
# 409 {"error":{"code":"idempotency_conflict",
#      "message":"Ya hay una solicitud en curso con esta clave de idempotencia."},"status":409}
```

Y la asimetría que descubrí corriéndolo: **el body del replay no es
byte-idéntico al original**, aunque sea el mismo Hash.

```json
// original
{"data":{"id":1275106,"kind":"receipt","quantity":5,"quantity_after":59,"product":{...}}}
// replay
{"data":{"id":1275106,"kind":"receipt","user":{...},"reason":"doc","product":{...},"quantity":5,...}}
```

El motivo: `response_body` es una columna **`jsonb`**, y jsonb **no preserva el
orden de las claves** (las ordena por longitud y después alfabéticamente). El
test pasa porque `Hash#==` en Ruby ignora el orden, pero un cliente que compare
la respuesta byte a byte, o que calcule un hash del body para conciliar, va a ver
diferencias. Si necesitás fidelidad exacta, la columna tiene que ser `json`
(que preserva orden y espacios) o `text`. Es un detalle que no aparece en ningún
blog post sobre idempotencia y que sí aparece cuando lo corrés.

---

## 8. Autenticación: Bearer tokens

```http
Authorization: Bearer stk_3nQb7xW2fK9_ejemploNoUsarEnSerio-A1B2C3D4E5
                      └┬┘ └──────────────── 32 bytes urlsafe_base64 ────┘
                    prefijo
```

`app/models/api_token.rb:35`:

```ruby
def issue!(user:, name:, scopes:, expires_in: nil)
  raw = "#{PREFIX}_#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"   # TOKEN_BYTES = 32
  token = create!(user:, name:, scopes: Array(scopes),
                  token_digest: digest(raw), token_prefix: raw.first(12),
                  expires_at: expires_in&.from_now)
  token.instance_variable_set(:@plaintext, raw)
  token
end
```

El texto plano existe **una sola vez**, en memoria, en el objeto que devuelve
`issue!`. Después sólo queda el digest. Es exactamente el modelo de los PAT de
GitHub, y es el correcto: si te filtran la base, los tokens siguen sin servir.

El `token_prefix` (12 chars) se guarda aparte para mostrarlo en la UI
(`stk_3nQb7xW2…`) y para que soporte pueda identificar de qué token habla el
cliente sin pedírselo entero.

### 8.1 SHA-256 y no bcrypt: el razonamiento completo

Este es un favorito de entrevista y casi todo el mundo contesta "bcrypt siempre",
que es **incorrecto**.

```ruby
def digest(raw) = OpenSSL::Digest::SHA256.hexdigest(raw)
def authenticate(raw)
  return nil if raw.blank?
  active.find_by(token_digest: digest(raw))
end
```

| | Password humano | Token generado |
|---|---|---|
| Entropía real | ~20-30 bits (`Verano2024!`) | **256 bits** |
| ¿Fuerza bruta viable? | **Sí**, con diccionario + reglas | No. 2^256 no se rompe |
| ¿Se valida con qué frecuencia? | 1 vez por sesión | **cada request** |
| Función correcta | bcrypt / argon2 / scrypt (**lentas a propósito**) | SHA-256 (rápida) |

El *stretching* de bcrypt existe para compensar la baja entropía de lo que
hashea. Con 256 bits de entropía real no hay nada que compensar: aunque el
atacante tenga la base y un cluster, no puede enumerar el espacio. Y bcrypt a
~100 ms por request te destruye el throughput: 3 threads de Puma × 100 ms = 30
req/s de techo, sólo autenticando.

**El segundo beneficio, más sutil**: como buscamos por **índice único sobre el
digest**, nunca comparamos el secreto en Ruby. No hay `==` entre strings
secretos, entonces **no hay timing attack posible**. Con bcrypt tendrías que
traer el candidato primero (¿por qué campo lo buscás si el digest es salado y
distinto cada vez?) — de hecho con bcrypt este esquema ni siquiera funcionaría
sin agregar una columna de lookup.

Por eso `ActiveSupport::SecurityUtils.secure_compare` **no hace falta acá**
(comentario en `token_authentication.rb:22`). Sí haría falta si compararas dos
strings secretos directamente — por ejemplo al verificar la firma HMAC de un
webhook entrante.

Una crítica legítima que conviene anticipar: SHA-256 sin sal es vulnerable a
tablas precomputadas… **para inputs de bajo espacio**. Con 256 bits de entropía
no existe tabla posible. La sal no aporta nada acá.

### 8.2 Scopes

```ruby
SCOPES = %w[stock:read stock:write catalog:read catalog:write
            transfers:write purchases:write admin].freeze

def permits?(scope) = scopes.include?("admin") || scopes.include?(scope.to_s)
```

Se declaran a nivel de clase, estilo `@PreAuthorize`:

```ruby
# app/controllers/api/v1/products_controller.rb:6
requires_scope "catalog:read",  only: %i[index show]
requires_scope "catalog:write", only: %i[create update destroy]
```

**El punto de diseño**: el scope es del **token**, no del usuario. Un token de
integración de sólo lectura no puede escribir *aunque su dueño sea admin*. Es
mínimo privilegio aplicado a la credencial, y es lo que te permite darle a un BI
un token que no puede tocar stock.

Verificado:

```bash
# token con scopes ["stock:read","catalog:read"]
curl -X POST "$BASE/api/v1/stock/receive" -H "Authorization: Bearer $RO" ...
# 403 {"error":{"code":"insufficient_scope",
#      "message":"El token no tiene el permiso 'stock:write'.",
#      "details":{"required_scope":"stock:write","token_scopes":["stock:read","catalog:read"]}},
#      "status":403}
```

Fijate que el error **dice qué scope falta**. Es información útil para el
integrador y no es sensible (ya está autenticado y es su propio token).

**Scopes vs roles: no son lo mismo y hay dos chequeos.** El scope dice *qué puede
hacer la credencial*; la policy de Pundit dice *qué puede hacer el usuario*. Los
dos tienen que pasar. Ejemplo real: un token con todos los scopes en manos de un
usuario `operator` recibe **403 de Pundit** al intentar `POST /stock/adjust`,
porque ajustar requiere `manager` (`spec/requests/api/v1/stock_operations_spec.rb:178`).
Permiso efectivo = scopes del token **∩** permisos del rol.

Detalle de implementación que vale: `scopes` es un **array nativo de Postgres**
con índice GIN, así que `WHERE scopes @> ARRAY['stock:write']` usa índice. Un
B-tree no sirve para "contiene". La alternativa normalizada (tabla join) te
costaría un join por request; jsonb sería más flexible y menos tipado. Para una
lista corta y fija, el array gana.

### 8.3 Expiración, rotación, revocación

```ruby
scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
def revoke! = update!(revoked_at: Time.current)
```

`authenticate` busca **sólo sobre `active`**, así que revocar es un `UPDATE` y
surte efecto en la **request siguiente**. Sin caches, sin propagación, sin
esperar a que venza nada. Ese es el punto entero de los tokens opacos.

El repo tiene tests para los tres casos
(`spec/requests/api/v1/stock_operations_spec.rb:36-66`): sin token → 401 con
`WWW-Authenticate`; token inventado → 401; token revocado → 401; usuario
deshabilitado → **403 `account_disabled`** (403 y no 401 porque la credencial es
válida, el que no puede es el sujeto).

**Rotación sin downtime** — el procedimiento que hay que saber describir, porque
el modelo ya lo soporta (un usuario puede tener N tokens activos):

1. `ApiToken.issue!` genera el token nuevo. El viejo sigue vivo.
2. El cliente despliega el nuevo. Ventana de solapamiento: días.
3. Mirás `last_used_at` del viejo: cuando deja de moverse, nadie lo usa.
4. `viejo.revoke!`. Si algo se rompe, des-revocás (`update!(revoked_at: nil)`).

Ese paso 3 depende de `touch_usage!` (`api_token.rb:77`), que tiene un detalle de
performance que conviene notar:

```ruby
def touch_usage!
  return if last_used_at.present? && last_used_at > 1.minute.ago
  update_columns(last_used_at: Time.current, requests_count: requests_count + 1)
end
```

Un `UPDATE` por request sobre la misma fila sería contención pura (cada UPDATE en
Postgres escribe una tupla nueva + WAL, y todos los requests del mismo token
compiten por la misma fila). El throttle a un minuto lo convierte en algo
despreciable. `update_columns` saltea validaciones y callbacks a propósito.
Contrapartida honesta: `requests_count` es un **conteo aproximado**, y con
concurrencia real se pierden incrementos (es un read-modify-write sin lock). Si
lo necesitás exacto, va `increment_counter` (que emite `SET x = x + 1` en SQL) o
un contador en Redis.

### 8.4 Por qué acá NO usamos JWT

| | Token opaco (este repo) | JWT |
|---|---|---|
| **Revocación** | `UPDATE`, efecto inmediato | **Imposible sin estado**. Vale hasta que expira |
| Validación | 1 query por índice único (<1 ms) | Verificación de firma en CPU, sin I/O |
| Tamaño en el header | ~48 bytes | 300-1500 bytes, **en cada request** |
| Claims | ninguno visible | **Base64, legibles por cualquiera** que vea el token |
| Escala multi-servicio | necesitás compartir la base o un servicio de auth | cada servicio valida solo |
| Rotación de secreto | irrelevante | invalida **todos** los tokens |

**La revocación es el argumento que decide.** Un JWT es un permiso firmado: una
vez emitido, es válido hasta `exp` y no hay forma de anularlo salvo mantener una
denylist — que es exactamente el estado que el JWT prometía evitar. En una API de
inventario, "revoqué el token del integrador que despedimos y sigue escribiendo
durante 30 minutos" no es aceptable.

Sumale que los JWT largos se filtran en logs de proxies, en URLs cuando alguien
los pone como query param, y en los headers de los reportes de error. Y que los
claims son **legibles**: `{"user_id":1,"email":"ana@empresa.test","role":"admin"}`
en base64. Un token opaco no dice nada de nadie.

Bonus histórico que vale mencionar: la familia de vulnerabilidades `alg: none` y
la confusión RS256/HS256 (verificar una firma RS256 usando la clave *pública*
como secreto HMAC). Son bugs de librería, están arreglados, pero ilustran que el
JWT tiene superficie criptográfica que un token opaco simplemente **no tiene**.

**Cuándo SÍ conviene JWT**, para no sonar dogmático:

- Muchos servicios que necesitan validar sin llamar a un auth central (evitás el
  cuello de botella y el SPOF).
- Tokens de **vida muy corta** (5-15 min) + refresh token opaco revocable. Ahí la
  ventana de no-revocabilidad es aceptable. Es el patrón de OAuth2/OIDC serio.
- Federación entre organizaciones, donde no podés compartir una base.
- Claims que el receptor necesita sin poder consultarte (`tenant_id`, `plan`).

Con **un** servicio Rails y Postgres al lado, JWT te agrega complejidad
criptográfica y te saca la revocación a cambio de ahorrar una query indexada de
menos de un milisegundo. Mal negocio.

---

## 9. CSRF: por qué en la API no y en la web sí

El ataque CSRF depende de una cosa: **el browser adjunta la cookie solo**, aunque
la request la origine otro sitio. `evil.test` pone un `<form action="https://stock.test/products" method="post">`,
la víctima logueada lo dispara, y el browser manda la cookie de sesión.

Un header `Authorization` **no se adjunta solo**. Nadie puede hacer que el
browser de la víctima mande tu Bearer token desde otro origen. Sin cookie, no hay
CSRF: el token de sincronización sería redundante.

En este repo esto no es una configuración, es **arquitectura**:

```ruby
class BaseController < ActionController::API   # NO ActionController::Base
```

`ActionController::API` no incluye `RequestForgeryProtection`, ni cookies, ni
sesión, ni flash, ni vistas. Verificado en la consola:

```ruby
Api::V1::BaseController.respond_to?(:protect_from_forgery)   # => false
ApplicationController.forgery_protection_strategy
# => ActionController::RequestForgeryProtection::ProtectionMethods::Exception
```

O sea: **en la API el CSRF no está "desactivado", no existe**. Eso es mucho mejor
que un `skip_before_action :verify_authenticity_token`, porque no se puede
reactivar por accidente ni desactivar "porque molesta" en un controller que sí
usa sesión.

Y del lado web sí está y funciona (verificado con `curl` contra el server):

```bash
curl -X POST "$BASE/session" -d "email_address=admin@stock.test&password=password123"
# => 422   (ActionController::InvalidAuthenticityToken)
curl -X POST "$BASE/products" -d "product[name]=x"
# => 422
```

También verifiqué que la API no emite **ninguna** cabecera `Set-Cookie`, mientras
que `/session/new` sí: `_stock_session=...`. La API es stateless de verdad.

### 9.1 SameSite

La segunda capa está en `app/controllers/concerns/authentication.rb`:

```ruby
cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
```

| Valor | Qué hace | Cuándo |
|---|---|---|
| `Strict` | La cookie **nunca** viaja cross-site, ni en navegación top-level | Máxima seguridad. Costo: si llegás desde un mail, aparecés deslogueado |
| `Lax` | Viaja en navegación top-level con métodos **safe** (GET). No en POST cross-site | El default sano, y el que usa este repo |
| `None` | Viaja siempre. **Exige `Secure`** | Sólo si tenés un flujo cross-site real (SSO, iframes) |

`Lax` mata el CSRF clásico por formulario POST. **No lo mata todo**: quedan los
GET que mutan estado (por eso nunca hagas un GET que muta) y ataques desde un
subdominio, porque SameSite razona por *site* (eTLD+1), no por origen. Por eso
`Lax` es una capa **adicional**, no un reemplazo del token. Los dos, siempre.

Y `httponly: true` es contra XSS, no contra CSRF: impide que un script lea la
cookie. Detalle que se confunde seguido: **httponly no protege contra CSRF**,
porque el ataque no necesita *leer* la cookie, sólo que el browser la mande.

---

## 10. Serialización: POROs, y por qué no las otras cinco opciones

```ruby
# app/serializers/application_serializer.rb:28
class ApplicationSerializer
  def initialize(object, **options) = (@object = object; @options = options)
  def self.collection(objects, **options) = objects.map { |o| new(o, **options).as_json }
  def as_json = raise(NotImplementedError, "#{self.class} debe implementar #as_json")
  private def iso(time) = time&.iso8601(3)
end
```

Contrato mínimo: `.new(objeto).as_json → Hash`, `.collection(array) → Array<Hash>`.
En `app/serializers/` hay **seis** serializers de recurso que heredan de
`ApplicationSerializer` (`product`, `stock_item`, `stock_movement`,
`stock_reservation`, `stock_transfer`, `purchase_order`), más `ErrorSerializer`,
que no hereda de nada porque no serializa un modelo sino un `Result` fallido.
Los `warehouses` no tienen serializer propio: el controller arma el Hash a mano
en un método privado `serialize` — una inconsistencia menor pero real.

### 10.1 El riesgo de `render json: modelo`

```ruby
render json: product   # NO
```

`ActiveRecord::Base#as_json` serializa **todas las columnas**. El día que alguien
agregue `internal_cost_notes`, `supplier_secret_price` o `discarded_at`, se
filtra sola en la API pública, sin que nadie toque el controller y sin que ningún
test falle. Es una **fuga por omisión**: el default es exponer, y en seguridad el
default tiene que ser ocultar.

`only:`/`except:` no salvan: `except:` es una deny-list, o sea que la columna
nueva se expone igual. `only:` es allow-list pero queda enterrada en el
controller, sin tests propios y duplicada en cada acción.

Con un PORO, agregar una columna a la tabla **no cambia nada** en la API. Para
exponerla hay que escribir la línea. Eso es una decisión explícita y revisable en
el diff.

### 10.2 La comparación

| Opción | Cómo funciona | A favor | En contra |
|---|---|---|---|
| **PORO** (acá) | Clases planas de Ruby | Cero magia, testeable como cualquier objeto, sin dependencia, el contrato se lee de arriba abajo | Boilerplate; te lo escribís vos |
| `render json:` directo | `to_json` de AR | Una línea | Fuga por omisión, N+1 fácil, sin control de forma |
| **jbuilder** | Vistas `.json.jbuilder` | Viene con Rails, cómodo para JSON anidado | Son **vistas**: lookup de templates, más lentas, no se testean como objetos, la lógica se te escapa al template |
| **alba** | Gema declarativa, DSL | Muy rápida (top de los benchmarks), buena API, soporta `root_key`, condicionales | Una dependencia más; DSL propio que hay que aprender |
| **blueprinter** | Gema declarativa con *views* | `fields`, `association`, vistas por caso de uso | Idem; la magia de las views confunde al que llega |
| **jsonapi-serializer** | Implementa JSON:API | Estándar real, paginación/relaciones/sparse fieldsets definidos | JSON:API es **verborrágico** y el cliente necesita librería para consumirlo cómodo. Sólo vale si adoptás el estándar entero |
| **ActiveModel::Serializers** | La clásica | Muchos ejemplos viejos | Prácticamente sin mantenimiento; no la elijas hoy |

**Por qué POROs acá**: es un proyecto de estudio y el objetivo es que se vea
exactamente qué sale, sin resolver ninguna magia. Además un serializer PORO es la
clase más fácil de testear que existe (`spec/serializers/serializers_spec.rb`).
En un proyecto grande con 60 recursos, **alba** o **blueprinter** son elecciones
perfectamente defendibles y ahorran mucho boilerplate.

En Java el paralelo es Jackson con `@JsonView`/`@JsonProperty` sobre el entity, o
un DTO + MapStruct. **La analogía se rompe acá**: en Jackson, anotar el entity es
la práctica común y funciona razonablemente porque el compilador y las anotaciones
te dan control estático. En Ruby no hay compilador ni anotaciones — serializar el
modelo es serializar *lo que sea que tenga la tabla hoy*. El DTO explícito no es
una preferencia estética, es la única forma de tener un contrato.

### 10.3 El detalle que evita el N+1 de agregación

```ruby
# app/serializers/product_serializer.rb
availability: options[:availability],   # se pasa POR PARÁMETRO, precalculada
```

y en el controller (`products_controller.rb:23`):

```ruby
availability = StockItems::Availability.call(product_ids: records.map(&:id))
records.map { |p| ProductSerializer.new(p, availability: availability[p.id]).as_json }
```

Si el serializer llamara `product.total_available`, serían **25 queries extra por
página**. El patrón general: **el serializer nunca hace queries**. Recibe todo
armado. Si un serializer necesita datos que el caller no le pasó, el problema es
del caller. Ver `docs/04` para el detalle del `GROUP BY`.

El `options` hash es también el mecanismo para las variantes: `.new(p, availability:)`
es el equivalente barato de las *views* de blueprinter o los `@JsonView` de Jackson.

### 10.3.1 El N+1 que sí estaba, y por qué el arreglo NO fue `includes`

La regla "el serializer nunca hace queries" se cumplía para la agregación pero
**no para las asociaciones**: `PurchaseOrderSerializer` y `StockTransferSerializer`
recorren las líneas y tocan `line.product`. Con Bullet activo en el entorno de
test, eso apareció como un N+1 real.

El arreglo obvio sería buscar la orden con `includes(lines: :product)`. Acá no
sirve, y el motivo es interesante: `submit`, `cancel` y `receive_order` tienen
**caminos de error que cortan antes de serializar** (estado inválido → 422, sin
permiso → 403). En esos casos el eager loading se paga y no se usa, que es
exactamente lo que Bullet reporta como *"AVOID eager loading detected"* — y con
razón.

La herramienta correcta para "ya tengo el objeto y **ahora sí** necesito sus
asociaciones" es el objeto que `includes` usa por debajo
(`app/controllers/api/v1/purchase_orders_controller.rb`, método privado
`serialize`):

```ruby
def serialize(order)
  ActiveRecord::Associations::Preloader.new(
    records: [ order ],
    associations: [ :supplier, :warehouse, :created_by, { lines: :product } ]
  ).call
  PurchaseOrderSerializer.new(order).as_json
end
```

Por eso `receive_order` desarma el `Result` a mano en vez de usar `render_result`:
necesita precargar **sólo en el camino de éxito**. En transferencias el caso es
distinto —las tres acciones serializan siempre— así que ahí alcanza con el scope
`with_associations` del modelo.

La misma idea, del lado de las queries: `StockMovements::Ledger` acepta un
parámetro `preload:` (default `%i[product warehouse user]`) para que cada caller
precargue lo que va a renderizar y nada más; el dashboard, que no muestra el
usuario, pasa `%i[product warehouse]`. Un query object compartido entre varias
vistas necesita ese parámetro, o precarga de más para unas y de menos para otras.

### 10.4 `.compact` y los campos ausentes

`ProductSerializer` y `StockMovementSerializer` terminan en `.compact`, que
**saca las claves con valor `nil`**. Consecuencia real, verificada:

```json
// GET /api/v1/products/AMO-115 -> las claves presentes
["active","availability","barcode","category","cost","created_at",
 "discarded","id","name","price","sku","unit","updated_at"]
// no hay "description": el producto la tiene en nil
```

Es una decisión con costo. A favor: payloads más chicos, no mandás ruido. En
contra: **el cliente no puede distinguir "campo ausente" de "campo null"**, y un
deserializador estricto (un `record` de Java con Jackson en modo `FAIL_ON_NULL_FOR_PRIMITIVES`,
o un `data class` de Kotlin sin default) puede romper. Si tu cliente principal es
tipado, mejor emitir `null` explícito y sacarle el `.compact`. Fijate que
`StockItemSerializer` **no** usa `.compact`: sus campos son siempre presentes, y
además expone `lock_version` a propósito para cerrar el ciclo de optimistic
locking sobre HTTP.

---

## 11. Paginación: offset para listados, cursor para el ledger

### 11.1 Offset, con cabeceras estilo GitHub

```ruby
# app/controllers/api/v1/base_controller.rb
MAX_PAGE_SIZE = 100

def paginate(scope) = pagy(scope, limit: page_limit)

def page_limit
  return Pagy::DEFAULT[:limit] if params[:limit].blank?

  Integer(params[:limit]).clamp(1, MAX_PAGE_SIZE)
rescue ArgumentError, TypeError
  Pagy::DEFAULT[:limit]
end

def render_collection(pagy, records, serializer, **options)
  pagy_headers_merge(pagy)
  render json: { data: serializer.collection(records, **options),
                 meta: { page:, limit:, total_count:, total_pages:, next_page:, prev_page: } }
end
```

La info de paginación va **duplicada**: en cabeceras (para clientes genéricos y
proxies) y en `meta` (para el front, que no siempre puede leer headers por CORS).
La configuración está en `config/initializers/pagy.rb`.

El `page_limit` con `clamp` **no está de adorno**: el techo lo pone la app, no la
gema. El `Pagy::DEFAULT[:max_limit]` del initializer es una opción que Pagy 9.4 no
lee (la suya se llama `:limit_max` y sólo la mira `Pagy::LimitExtra`), así que
durante un tiempo `?limit=5000` devolvió 5000 filas. Está contado entero en el
error #2 de la sección de producción. Y fijate el `Integer(...)` con `rescue`:
`"todos".to_i` daría 0 y `clamp(1, 100)` lo subiría a 1 —una página de un ítem
en silencio—; con `Integer` un limit no numérico cae al default de 25.

Salida real de `GET /api/v1/products?limit=2`:

```http
link: <...?limit=2&page=1>; rel="first", <...&page=2>; rel="next", <...&page=8>; rel="last"
current-page: 1
page-items: 2
total-pages: 8
total-count: 15
```

`Link` con `rel=` es RFC 8288 y es lo que usa GitHub: el cliente **no arma URLs**,
sigue las que le das. Eso te deja cambiar el esquema de paginación sin romperlo.

`Pagy::DEFAULT[:overflow] = :last_page` hace que `?page=9999` devuelva la última
página en vez de reventar. Verificado con el `limit` por defecto de 25: como los
15 productos entran en una sola página, `GET /api/v1/products?page=9999` responde
`200` con `current-page: 1`. Sin ese `overflow`, Pagy levanta `Pagy::OverflowError`
y eso llega al cliente como 500.

### 11.2 Cursor (keyset) para el ledger

```ruby
# app/queries/stock_movements/ledger.rb, #apply_cursor
relation.where("(stock_movements.occurred_at, stock_movements.id) < (?, ?)", t, i)
        .order(occurred_at: :desc, id: :desc).limit(@limit)
```

| | OFFSET | KEYSET |
|---|---|---|
| Costo de la página N | O(N·limit): Postgres **genera y descarta** las filas saltadas | O(log n): salta con el índice |
| Página 5000 | segundos | igual que la página 1 |
| Si insertan mientras paginás | **se te corre todo**: ves filas repetidas o te salteás otras | nada se mueve: el cursor apunta a una fila |
| "Ir a la página 37" | ✓ | ✗ |
| Total de filas | ✓ (a costa de un `COUNT(*)`) | ✗ (o lo estimás) |

La comparación de **tuplas** `(a, b) < (x, y)` es SQL estándar y hace exactamente
lo que querés (compara `a`, y sólo si empata compara `b`). Es lo que permite que
el índice compuesto `(occurred_at DESC, id DESC)` resuelva todo el `WHERE` de una
pasada. Escribirlo como `occurred_at < ? OR (occurred_at = ? AND id < ?)` es
equivalente lógicamente pero el planner suele no usar bien el índice.

El cursor es **opaco**: Base64url de un JSON (`Ledger.encode_cursor`). Verificado:

```bash
curl -s "$BASE/api/v1/stock_movements?limit=2" -H "Authorization: Bearer $TOKEN" | jq .meta
# {"count": 2, "next_cursor": "eyJ0IjoiMjAyNi0wOC0zMFQxNzo1MDoyMy4yMTg2MjZaIiwiaSI6MTI3NTEwNX0"}

echo 'eyJ0IjoiMjAyNi0wOC0zMFQxNzo1MDoyMy4yMTg2MjZaIiwiaSI6MTI3NTEwNX0' | base64 -d
# {"t":"2026-08-30T17:50:23.218626Z","i":1275105}

# la página siguiente arranca justo después:
curl -s "$BASE/api/v1/stock_movements?limit=2&cursor=eyJ0Ijoi..." | jq '[.data[].id]'
# [963104, 963103]     (la anterior fue [1275106, 1275105])
```

Que sea opaco importa: si el cursor fuera `?after_id=1275105`, los clientes lo
tratarían como parte del contrato y no podrías cambiar el criterio de orden nunca
más. Base64 comunica "esto no es tuyo, devolvémelo tal cual". **No es cifrado**
—el cliente puede decodificarlo— pero sí es una señal de contrato. Si el
contenido fuera sensible (por ejemplo si filtrara un id que el usuario no debería
ver), habría que firmarlo o cifrarlo.

Fijate el `iso8601(6)`: **microsegundos**. Con precisión de segundos, dos
movimientos del mismo segundo se pisan y el cursor te saltea filas. Postgres
guarda `timestamptz` con microsegundos; si truncás al serializar el cursor,
perdés filas en silencio.

Y el manejo de cursor corrupto (el `rescue` de `apply_cursor`): se loguea y **se devuelve la
primera página**, no un 500. Un cursor roto es un bug del cliente, no una caída
del servidor.

### 11.3 Cómo documentar cada una

Regla que conviene decir: **no mezcles los dos esquemas en el mismo endpoint**.
Elegí uno por recurso y decilo en la doc:

- **Listados navegables por humanos** (productos, depósitos, órdenes): offset.
  Documentá `page`, `limit`, el máximo de `limit`, y que las cabeceras `Link`
  son la forma canónica de avanzar.
- **Feeds/ledgers append-only e infinitos**: cursor. Documentá que `next_cursor:
  null` significa "no hay más", que el cursor es opaco y de duración limitada, y
  que **no** hay `total_count` (calcularlo sería un `COUNT(*)` sobre millones de
  filas en cada página).

---

## 12. Filtrado y ordenamiento seguros

### 12.1 Allow-list de columnas, siempre

```ruby
# app/queries/products/search.rb:25
SORTS = {
  "name"   => { name: :asc,        id: :asc },
  "sku"    => { sku: :asc,         id: :asc },
  "newest" => { created_at: :desc, id: :desc },
  "price"  => { price_cents: :desc, id: :asc }
}.freeze

@sort = SORTS.key?(sort.to_s) ? sort.to_s : "name"   # cualquier otra cosa cae al default
relation.includes(:category).order(SORTS.fetch(@sort))
```

El param del usuario **nunca toca el SQL**. Es una clave de un Hash congelado; el
valor es un Hash de símbolos que ActiveRecord cita solo. Verificado:

```bash
curl -s "$BASE/api/v1/products?limit=2&sort=price_cents%3B+DROP+TABLE+products--" \
  -H "Authorization: Bearer $TOKEN" | jq '[.data[].sku]'
# => ["AMO-115","ARA-M5"]     <- orden por 'name', el default. No pasó nada.

curl -s "$BASE/api/v1/products?limit=2&sort=price" | jq '[.data[] | [.sku, .price.cents]]'
# => [["TAL-750",89900],["AMO-115",79900]]
```

Fijate además el **desempate por `id`** en cada orden. Sin él, dos filas con el
mismo `name` pueden salir en orden distinto en páginas distintas (Postgres no
garantiza estabilidad), y ves un producto dos veces o ninguna. Es el bug de
paginación más común y el más difícil de creer cuando lo reportan.

### 12.2 Mostrá la inyección: qué pasa si interpolás

Rails 8.1 tiene una red de seguridad, pero **no es una defensa**. Corrido en
`bin/rails runner`:

```ruby
# 1) Interpolación "inocente": pasa el filtro sin problema
Product.order("price_cents DESC").to_sql
# => SELECT "products".* FROM "products" ORDER BY price_cents DESC

# 2) Algo complejo: Rails lo bloquea
evil = "(CASE WHEN (SELECT count(*) FROM users WHERE role = 'admin') > 0 THEN 1 ELSE 2 END)"
Product.order(evil)
# => ActiveRecord::UnknownAttributeReference: Dangerous query method
#    (method whose arguments are used as raw SQL) called with non-attribute argument(s)

# 3) Arel.sql DESACTIVA el guard por completo
Product.order(Arel.sql(evil)).to_sql
# => SELECT "products".* FROM "products"
#    ORDER BY (CASE WHEN (SELECT count(*) FROM users WHERE role = 'admin') > 0 THEN 1 ELSE 2 END)
```

Y acá está el punto que casi nadie ve. El guard usa
`adapter_class.column_name_matcher`, un regex que acepta *nombres de columna con
dirección opcional*, incluyendo **calificados por tabla**:

```ruby
m = ActiveRecord::Base.adapter_class.column_name_matcher
m.match?("name")               # => true
m.match?("price_cents DESC")   # => true
m.match?("users.role")         # => true      <-- ojo
m.match?("name; DROP TABLE x") # => false
```

O sea que `order(params[:sort])` **no te deja ejecutar SQL arbitrario**, pero sí
deja al cliente ordenar por **cualquier columna de cualquier tabla del `FROM`**.
Eso es un oráculo de inferencia: pedís `?sort=users.password_digest` sobre un
listado joineado, mirás el orden resultante, y extraés información carácter por
carácter con suficientes requests. No hace falta un `UNION` para filtrar datos.

**La conclusión operativa**: el guard de Rails es una red contra el error tonto,
no un control de acceso. La única defensa correcta sigue siendo la **allow-list
explícita**, que es lo que hace `SORTS`. Y si alguna vez escribís `Arel.sql`,
tratalo como un `unsafe { }` de Rust: sólo con literales, nunca con un param.

### 12.3 Filtros

Los filtros del repo son todos por clave natural o por columna fija:

```ruby
# app/controllers/api/v1/stock_items_controller.rb:10-12 y :27
scope = scope.where(warehouse_id: warehouse_filter) if params[:warehouse_code].present?
scope = scope.where("quantity_available <= reorder_point") if truthy?(params[:low_stock])
# ...
def warehouse_filter = Warehouse.where(code: params[:warehouse_code].to_s.upcase).select(:id)
```

Tres cosas a notar:

1. `where(id: subquery)` genera `IN (SELECT ...)`, que Postgres convierte en
   semi-join. Mejor que `joins` acá: un join uno-a-muchos duplica filas del lado
   izquierdo y te obliga a un `.distinct` que fuerza un sort agregado caro.
2. El `where("quantity_available <= reorder_point")` es SQL literal **sin
   interpolación de params** — comparar dos columnas de la misma fila no se puede
   expresar con el hash de AR. Es seguro porque no hay nada del usuario adentro.
   La regla: SQL literal sí, interpolación de params jamás.
3. `boolean_param` (`products_controller.rb:87`) existe por una trampa de Ruby:
   **`"false"` es truthy**. `if params[:active]` da `true` para el string
   `"false"`. Hay que castear siempre con `ActiveModel::Type::Boolean.new.cast(v)`.
   Viniendo de Java esto no se te ocurre, porque `Boolean.parseBoolean("false")`
   hace lo obvio. En Ruby **sólo `nil` y `false` son falsy**: `0`, `""` y `"false"`
   son todos verdaderos.

Sobre el `LIKE`: `Products::Search#apply_term` usa
`Product.sanitize_sql_like(@term)` (línea 59), que escapa `%` y `_`. Sin eso, un
usuario manda `"%"` y te fuerza un seq scan de la tabla entera: DoS de un
carácter. Con `pg_trgm` + índice GIN (`index_products_on_name_trgm`) el `ILIKE
'%texto%'` sí puede usar índice, cosa que un B-tree no puede por el comodín
inicial.

---

## 13. Timeouts, tamaño de payload, compresión

Lo que hay de verdad en este repo, sin inventar:

| Capa | Configuración | Dónde |
|---|---|---|
| **Statement timeout de PG** | `statement_timeout: 15000` ms | `config/database.yml:53` |
| **Checkout del pool** | `checkout_timeout: 5` s | `config/database.yml:44` |
| **Threads de Puma** | `RAILS_MAX_THREADS`, default 3 | `config/puma.rb` |
| **Timeout del webhook saliente** | `open_timeout` / `read_timeout` = 5 s | `app/services/outbox/publisher.rb:74` |
| **Proxy / compresión** | Thruster 0.1.26 (`CMD ["./bin/thrust", "./bin/rails", "server"]`) | `Dockerfile:77` |
| **Límite de `limit` en el ledger** | `clamp(1, 200)` | `app/queries/stock_movements/ledger.rb:51` |
| **Techo del TTL de reservas** | `clamp(60, 7.days)` | `app/controllers/api/v1/reservations_controller.rb:76` |

**El `statement_timeout` es la protección más importante y la que más falta en
las apps que uno ve.** Sin él, una query patológica (un reporte sin índice, un
`ILIKE '%'`) ocupa una conexión del pool indefinidamente; con 3 threads por
worker, tres queries colgadas dejan el worker inservible y el health check
empieza a fallar. 15 s es agresivo a propósito: si un endpoint necesita más, o lo
optimizás o lo movés a un job.

Lo que **falta** y hay que saber decirlo:

- **No hay límite de tamaño de body.** `MAX_REQUEST_BODY` de Thruster tiene
  default `0` = sin límite, y no está seteado en el `Dockerfile` ni en
  `.env.example`. Un POST de 500 MB llega a Rails, se parsea a `params`, y te
  come la memoria del worker. El arreglo es una línea de env
  (`MAX_REQUEST_BODY=1048576`), y conviene además un `Rack::Attack` que corte por
  `CONTENT_LENGTH`.
- **No hay timeout de request end-to-end en Rails.** El `statement_timeout` cubre
  la base, pero no un loop en Ruby ni una llamada HTTP saliente sin timeout.
  `rack-timeout` es la gema clásica; ojo que corta con `Thread#raise`, lo cual
  puede dejar estado inconsistente — hay que usarla sabiendo eso, y preferir
  timeouts explícitos por dependencia (que es lo que hace el `WebhookAdapter`).
- **Compresión**: no hay `Rack::Deflater` en el stack (verificado con
  `bin/rails middleware`). La hace Thruster, con gzip habilitado por default y
  32 bytes de jitter para mitigar BREACH. Comprimir en Ruby es quemar CPU del
  worker; que lo haga el proxy es lo correcto.

Sobre **BREACH/CRIME**, que es la pregunta capciosa: comprimir una respuesta que
mezcla un secreto (un token CSRF) con contenido controlado por el atacante deja
filtrar el secreto midiendo el tamaño comprimido. Para esta API el riesgo es
bajo (no hay secretos en el body y el auth va por header), pero es la razón por
la que Thruster ofrece `GZIP_COMPRESSION_DISABLE_ON_AUTH` y el jitter.

---

## 14. Documentación: OpenAPI y rswag

**Estado real de este repo: no hay OpenAPI.** No está `rswag` en el `Gemfile` ni
hay un `swagger.yaml`. La documentación viva son los request specs y los
comentarios. Es una deuda consciente y conviene poder explicarla.

### 14.1 Las tres formas de tener un spec, y cuál se pudre

| Enfoque | Cómo | Riesgo |
|---|---|---|
| **Escrito a mano** (`swagger.yaml` en el repo) | Lo mantenés vos | **Se desincroniza en dos sprints.** Es documentación, no verdad |
| **Generado del código** (anotaciones, `rswag` sin tests) | Comentarios/DSL en los controllers | Mejor, pero sigue siendo una afirmación que nadie verifica |
| **Generado de los tests** (`rswag` con `run_test!`) | El mismo test que valida el contrato emite el spec | **El spec no puede mentir**: si el endpoint cambia, el test falla y el spec no se genera |

El tercero es el que vale la pena, y es la respuesta a "por qué los tests de
request pueden generar la doc": porque **son la única fuente que se ejecuta**. Un
YAML a mano dice lo que alguien creía en marzo; un test verde dice lo que la app
hace hoy. Es el mismo argumento que en Java hace que se prefiera springdoc-openapi
(que introspecciona el código y los `@Valid`) sobre un `.yaml` a mano — pero
rswag va un paso más allá, porque la fuente es el *test*, no las anotaciones.

Así se vería, sobre el endpoint real de este repo:

```ruby
# spec/requests/api/v1/stock_operations_spec.rb, si adoptáramos rswag
path "/api/v1/stock/receive" do
  post "Ingreso de mercadería" do
    tags "Stock"
    consumes "application/json"
    produces "application/json"
    security [ bearer_auth: [] ]

    parameter name: "Idempotency-Key", in: :header, schema: { type: :string },
              required: false, description: "UUID por operación de negocio, no por request"
    parameter name: :body, in: :body, schema: {
      type: :object, required: %w[sku warehouse_code quantity],
      properties: {
        sku: { type: :string, example: "AMO-115" },
        warehouse_code: { type: :string, example: "BA-01" },
        quantity: { type: :integer, minimum: 1, example: 25 },
        reason: { type: :string, nullable: true }
      }
    }

    response 201, "movimiento creado" do
      schema "$ref" => "#/components/schemas/StockMovement"
      run_test!           # <- ejecuta de verdad y valida la respuesta contra el schema
    end
    response 422, "stock insuficiente" do
      schema "$ref" => "#/components/schemas/Error"
      run_test!
    end
    response 409, "clave de idempotencia en vuelo" do
      run_test!
    end
  end
end
```

Con `rake rswag:specs:swaggerize` sale el `swagger.yaml`, y `rswag-api` +
`rswag-ui` lo sirven. El costo honesto: los specs se vuelven más verbosos y menos
legibles como *tests*. La estrategia que suele funcionar es **híbrida**: rswag
sólo en los endpoints públicos que documentás, request specs normales para el
resto.

Aunque no adoptes OpenAPI, hay dos cosas baratas que conviene tener:

1. **Los `code` de error documentados en una tabla**, porque son el contrato
   estable (el `message` cambia, el `code` no).
2. **Ejemplos de `curl` que corran**, como los de §4.1. Un integrador copia y
   pega; si el ejemplo funciona, te ahorrás media docena de mails.

---

## 15. Webhooks salientes

La salida de eventos usa el patrón **outbox** (detalle completo en `docs/07`): el
evento se escribe en `outbox_events` **dentro de la transacción de negocio**, y
un job lo publica después. Acá me interesa la parte HTTP.

```ruby
# app/services/outbox/publisher.rb:59
def publish(message)
  body = message.to_json
  timestamp = Time.current.to_i

  request = Net::HTTP::Post.new(@uri)
  request["Content-Type"]     = "application/json"
  request["X-Stock-Event"]    = message[:event_type].to_s
  request["X-Stock-Timestamp"] = timestamp.to_s
  request["X-Stock-Signature"] = sign("#{timestamp}.#{body}") if @secret
  request.body = body
  # ... open_timeout/read_timeout = 5s ...
  raise DeliveryError, "El webhook respondió #{response.code}" unless response.is_a?(Net::HTTPSuccess)
end

def sign(payload) = OpenSSL::HMAC.hexdigest("SHA256", @secret, payload)
```

### 15.1 Por qué el timestamp entra en la firma

Si firmaras sólo el body, la firma sería **eternamente válida para ese body**. Un
atacante que capture un webhook legítimo (un proxy corporativo, un log, un
`ngrok` mal configurado) puede reenviarlo mil veces: eso es un **replay attack**,
y en este dominio significa "se recibieron 10.000 unidades" que nunca llegaron.

Firmando `"#{timestamp}.#{body}"` el receptor puede rechazar todo lo que tenga
más de N minutos. Es exactamente el esquema de Stripe (`t=...,v1=...` en un solo
header) y el de GitHub (`X-Hub-Signature-256`).

**La firma sola no alcanza: el receptor tiene que validar la ventana.** Si el
receptor sólo verifica el HMAC y no mira el timestamp, el timestamp no sirve para
nada. Por eso la doc del webhook tiene que incluir el código del verificador:

```ruby
# Del lado del RECEPTOR
TOLERANCIA = 5.minutes

def verificar!(request, secret)
  ts   = request.headers["X-Stock-Timestamp"].to_i
  sig  = request.headers["X-Stock-Signature"].to_s
  body = request.raw_post

  raise "timestamp fuera de ventana" if (Time.current.to_i - ts).abs > TOLERANCIA

  esperada = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")

  # ACÁ SÍ hace falta secure_compare: comparamos dos secretos en Ruby, y un `==`
  # común corta en el primer byte distinto => filtra la firma por timing.
  raise "firma inválida" unless ActiveSupport::SecurityUtils.secure_compare(esperada, sig)
end
```

Verificado que las dos puntas dan lo mismo:

```ruby
adapter.sign("1756577000.#{body}")
# => 4a05814162f8567170292c92231fdc2a9e39e1c8aad036c93ed217d87a78e547
OpenSSL::HMAC.hexdigest("SHA256", "shhh", "1756577000.#{body}")
# => 4a05814162f8567170292c92231fdc2a9e39e1c8aad036c93ed217d87a78e547
```

Detalle que arruina implementaciones: hay que firmar **el body crudo**
(`request.raw_post`), no el hash reserializado. Si el receptor hace
`JSON.parse(body).to_json` y firma eso, el orden de claves y los espacios cambian
y la firma nunca coincide. Mismo problema que el de jsonb en §7.10.

### 15.2 Reintentos y entrega

```ruby
MAX_ATTEMPTS = 10                                  # app/models/outbox_event.rb:5
def mark_failed!(error) = update!(attempts: attempts + 1, last_error: ...)
def self.claim_batch(limit:) = pending.where(attempts: ...MAX_ATTEMPTS)
                                      .order(:id).limit(limit).lock("FOR UPDATE SKIP LOCKED")
```

Cuatro propiedades que hay que poder enunciar:

1. **At-least-once, nunca exactly-once.** Si el proceso muere después de publicar
   y antes de marcar `published_at`, el evento sale dos veces. Es inevitable sin
   transacciones distribuidas. Por eso cada mensaje lleva `event_id` (UUID) y **el
   consumidor tiene que deduplicar**. "Exactly-once delivery" no existe; lo que
   existe es *at-least-once + procesamiento idempotente* — que es exactamente el
   mismo patrón de §7, del otro lado del cable.
2. **Poison message.** El `rescue` por evento
   (`app/jobs/outbox/publish_pending_job.rb:48`) evita que un payload roto tape
   la cola para siempre. Cuenta el intento y sigue.
3. **Orden.** Se procesa `ORDER BY id`, pero con varios workers y `SKIP LOCKED`
   el orden **global** no está garantizado. Si necesitás orden por agregado (y en
   stock lo necesitás), hay que particionar por `aggregate_id`: mismo agregado,
   mismo worker. Es el rol de la partition key en Kafka.
4. **Backpressure.** `BATCH_SIZE = 200` y auto-reencolado si el lote se llenó.

Lo que **falta** frente a un sistema de webhooks maduro, y conviene decirlo antes
de que te lo pregunten:

- **No hay backoff exponencial**: los 10 intentos salen a la misma cadencia del
  job recurrente. Un receptor caído recibe 10 golpes seguidos y el evento muere
  en una hora, cuando debería reintentarse a 1 min, 5, 25, 2 h, 12 h.
- **No hay dead-letter visible**: hay un scope `stuck` (`attempts >= 10`) pero
  ningún endpoint ni alerta que lo exponga.
- **No hay endpoint de reintento manual** para que el integrador se recupere solo.
- El adapter por default es `log`, no `webhook` (`OUTBOX_ADAPTER=log` en
  `.env.example`). Verificado: `Outbox::Publisher.build.class # => Outbox::Publisher::LogAdapter`.
  Con un colector de logs eso ya es un stream de eventos consultable, y es
  **suficiente** hasta que necesites de verdad un broker. "Empezá con lo simple"
  es una respuesta válida en una entrevista de arquitectura, siempre que sepas
  cuándo dejar de serlo.

---

## Errores que ves en producción

Todos estos los reproduje contra la app corriendo en `localhost:3001`. Los
primeros seis son bugs que **estuvieron vivos en este repo**, cada uno con su
reproducción original; los demás son el patrón general que conviene tener a mano.

Estado actual, para que se lea de un vistazo:

| # | Bug | Estado | Arreglo (o qué falta) |
|---|---|---|---|
| 1 | Clave de idempotencia trabada en `processing` tras una excepción | **Corregido** | `rescue`/`else` alrededor del `yield` en `app/controllers/concerns/api/idempotency.rb`; regresión en `spec/requests/api/v1/hardening_spec.rb` |
| 2 | `?limit=5000` devolvía 5000 filas (`max_limit` de Pagy inerte) | **Corregido** | `MAX_PAGE_SIZE = 100` + `page_limit` en `app/controllers/api/v1/base_controller.rb`; regresión en `hardening_spec.rb` |
| 3 | `Idempotency-Key` de más de 255 chars → 500 | **Sigue vivo** | Falta un `skip_pundit_verification` en esa rama (`idempotency.rb:83`) |
| 4 | JSON malformado → 400 con HTML en dev y 500 en producción | **Corregido** | `rescue_from ParseError` y `BadRequest` en `error_handling.rb:37-38`; regresión en `hardening_spec.rb` |
| 5 | `ProductSerializer` no emite `lock_version` | **Sigue vivo** | Falta la línea en el serializer |
| 6 | El 409 `duplicate` filtraba el mensaje crudo de Postgres | **Corregido** | `application_service.rb:80` loguea `e.message` y no lo adjunta; regresión en `hardening_spec.rb` |

Los dos que siguen vivos están marcados como tales en su sección. Dejo la
explicación completa de los corregidos: el valor está en el diagnóstico, no en
el parche.

---

**1. Una excepción durante la acción dejaba la clave de idempotencia trabada en
`processing` — y la quemaba por 24 horas.** ✅ **Corregido.**

*Síntoma*: el cliente mandaba un POST con `Idempotency-Key`, se comía un 404 o un
403 (un SKU mal escrito, un token sin rol), corregía el problema, reintentaba con
la misma clave… y recibía **409 `idempotency_conflict` para siempre**. Desde
afuera parecía que había una request colgada que nunca termina. Duraba hasta que
vencía el TTL: 24 horas.

*Causa*: `with_idempotency` es un `around_action`. En el camino feliz hace
`yield` y después `persist_response(fresh)`. Pero si la acción **levanta**, el
`yield` propaga la excepción y `persist_response` **no corría**: la fila quedaba
en `processing`, que es exactamente el estado que `claim_key` traduce a 409.

La clave está en qué errores levantan y cuáles no:

| Camino | Cómo termina | Estado final de la fila (antes) |
|---|---|---|
| Éxito 2xx | `render_result` | `completed` ✔ |
| Fallo de negocio (`insufficient_stock`, 422) | `render_result`, **sin excepción** | `failed` ✔ (reintentable) |
| Todo lo que pasa por `rescue_from` (404, 403, 400, 409 `StaleObjectError`, 422 `RecordInvalid`) | **excepción** | `processing` ✘ **trabada** |

Los `rescue_from` viven en `process_action`, que está **por fuera** del
`around_action`: para cuando el handler renderiza el 404, el `around_action` ya
se desarmó sin ejecutar su segunda mitad.

Así se veía cuando el bug estaba vivo, reproducido contra la app corriendo:

```bash
K=demo-trabada   # (comportamiento VIEJO; hoy el paso 1 deja la fila en 'failed')

# 1) SKU inexistente -> 404 por rescue_from RecordNotFound
curl -s -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: $K" ... \
  -d '{"sku":"NO-EXISTE","warehouse_code":"BA-01","quantity":1}'
# {"error":{"code":"not_found","message":"Recurso no encontrado."},"status":404}

bin/rails runner 'r = IdempotencyKey.find_by(key: "demo-trabada");
                  puts "#{r.status} / #{r.response_status.inspect}"'
# => processing / nil          <- se quedó ahí

# 2) mismo body, reintento
# => 409 {"code":"idempotency_conflict"}   <- y así por 24 h

# 3) body corregido, misma clave
# => 422 {"code":"idempotency_key_reuse"}  <- el fingerprint tampoco lo deja salir
```

Fijate lo cerrado que quedaba el callejón: con el mismo body daba 409, con el
body arreglado daba 422. El cliente **no tenía ninguna forma** de completar esa
operación con esa clave; tenía que inventar una nueva, que es justo lo que la
idempotencia le pedía no hacer.

Y no era un caso de borde: `POST /api/v1/products` está envuelto por
`idempotent only: %i[create]`, y el error más común de ese endpoint —SKU
repetido— sale por `rescue_from ActiveRecord::RecordInvalid`. O sea que trababa
la clave igual.

*Arreglo* (`app/controllers/concerns/api/idempotency.rb`, la última rama del
`case/in`): marcar `failed` en el camino de excepción y persistir la respuesta
sólo en el limpio.

```ruby
in { record: IdempotencyKey => fresh }
  begin
    yield
  rescue StandardError
    mark_failed(fresh)
    raise               # que el rescue_from renderice el 404/403/422 real
  else
    persist_response(fresh)
  end
end
```

**Por qué `rescue`/`else` y no `ensure`.** Este es el detalle que hace la
diferencia y el que conviene poder explicar: el `ensure` corre mientras la
excepción viaja hacia arriba, o sea **antes** de que el `rescue_from` renderice.
En ese momento `response.status` todavía es 200, `response.successful?` da `true`,
y `persist_response` marcaría la clave como `completed` guardando un cuerpo
vacío. El reintento devolvería un 200 vacío en vez de un 409: cambiabas un bug
por uno peor y más difícil de ver. El `else` de un `begin/rescue` corre **sólo
si no hubo excepción**, que es exactamente la condición que queremos.

(`mark_failed` además tiene su propio `rescue`: estamos en un camino de excepción
y no queremos que un fallo al escribir la fila tape el error original.)

Verificado contra la app corriendo, después del arreglo:

```bash
K=doc-verif-b
# 1) SKU inexistente -> 404
curl -s -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: $K" ... \
  -d '{"sku":"NO-EXISTE","warehouse_code":"BA-01","quantity":1}'
# {"error":{"code":"not_found","message":"Recurso no encontrado."},"status":404}

bin/rails runner 'puts IdempotencyKey.find_by(key: "doc-verif-b").status'
# => failed          <- ya no queda en 'processing'

# 2) mismo body, reintento -> REEJECUTA (404 de nuevo, no 409)
# 3) POST /api/v1/products con SKU repetido -> 422 validation_failed, fila en 'failed'
```

Sigue valiendo —y es correcto— que la misma clave con **otro** body devuelva 422
`idempotency_key_reuse`: eso es el fingerprint haciendo su trabajo (§7.4), no el
bug. La diferencia es que ahora la clave se libera y el reintento del *mismo*
intento funciona.

Regresión: `spec/requests/api/v1/hardening_spec.rb`, ejemplo "permite reintentar
con la misma clave después de un 404", que aserta explícitamente
`IdempotencyKey.find_by(key:).status == "failed"`.

*Lección general*: **un `around_action` es un `try/finally` a medias.** Todo lo
que ponés después del `yield` es código que sólo corre en el camino feliz. Si
mantenés estado externo —una fila de lock, un contador, un span de tracing— la
segunda mitad tiene que estar en un camino que corra siempre. Es el mismo error
que en Java sería escribir el `close()` después del `return` en vez de en el
`finally`. Y el corolario, que es la parte fina: **el `finally` tampoco es
gratis** si lo que mirás adentro todavía no está escrito.

*Nota*: este bug **no se llevaba puesto** el caso que §7.7 describe como bien
resuelto (el 422 de negocio que libera la clave). Lo que rompía era el
subconjunto de errores que viajan como excepción, que casualmente son los más
frecuentes en una integración nueva: SKU mal escrito, token sin permisos,
parámetro faltante.

---

**2. `?limit=5000` devolvía 5000 filas: el `max_limit` de Pagy estaba inerte.**
✅ **Corregido.**

*Síntoma*: un cliente pide `?limit=100000`, el worker carga 100k objetos AR en
memoria y se muere por OOM. El health check falla, el balanceador saca la
instancia, la carga se va a las otras. Cascada clásica.

*Causa*: **dos** errores encadenados. El primero, en `config/initializers/pagy.rb`:

```ruby
Pagy::DEFAULT[:max_limit] = 100     # <- esta clave NO EXISTE en pagy 9.4
```

En Pagy 9.4 la opción se llama **`:limit_max`**, y sólo la lee
`Pagy::LimitExtra`, que hay que requerir explícitamente
(`require "pagy/extras/limit"`) — el initializer requiere `overflow` y `headers`,
no `limit`. Comprobalo en la gema misma:

```bash
grep -rn "limit_max" $(gem contents pagy | grep '/extras/limit.rb')
# DEFAULT[:limit_max] = 100
# vars[:limit] = [limit_count.to_i, ... DEFAULT[:limit_max]].compact.min
```

El segundo: aunque la extra estuviera cargada, `paginate` pasaba el limit a mano
y el `||=` de Pagy nunca llegaba a correr:

```ruby
def paginate(scope) = pagy(scope, limit: params[:limit])
# y en Pagy::Backend#pagy:  vars[:limit] ||= pagy_get_limit(vars)
#                                        ^^^ nunca corre, ya viene seteado
```

Así se veía antes:

```bash
curl -s -D - -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/products?limit=5000" | grep page-items
# page-items: 5000
```

*Arreglo*: no depender de la gema y clampear en el código de la app
(`app/controllers/api/v1/base_controller.rb`):

```ruby
MAX_PAGE_SIZE = 100

def paginate(scope) = pagy(scope, limit: page_limit)

def page_limit
  return Pagy::DEFAULT[:limit] if params[:limit].blank?

  Integer(params[:limit]).clamp(1, MAX_PAGE_SIZE)
rescue ArgumentError, TypeError
  Pagy::DEFAULT[:limit]
end
```

El `Integer(...)` con `rescue` no es cosmético: con `.to_i`, un `?limit=todos`
daría 0, el `clamp(1, 100)` lo subiría a 1 y el cliente recibiría páginas de un
ítem sin ningún error. Con `Integer` cae al default de 25.

Verificado hoy contra la app corriendo:

```bash
curl -s -D - -o /dev/null -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/v1/products?limit=5000" | grep -E "page-items|total-pages"
# page-items: 100
# total-pages: 1
```

Regresión en `spec/requests/api/v1/hardening_spec.rb`, con los tres casos que
importan: limit absurdo → 100, limit no numérico → 25, limit razonable → se
respeta.

Fijate el contraste que ya existía: el ledger **sí** clampeaba
(`ledger.rb:51`, `limit.to_i.clamp(1, MAX_LIMIT)` con `MAX_LIMIT = 200`) y el
TTL de reservas también (`clamp(60, 7.days.to_i)`). El clamp explícito en el
código de la app es la defensa; la opción de la gema es un extra. Nota: la línea
`Pagy::DEFAULT[:max_limit] = 100` sigue en el initializer y sigue sin hacer nada
— queda como documentación de la trampa, ahora que el techo real está en el
controller.

*Lección general*: **una opción de configuración que la librería no lee falla en
silencio.** Ruby no valida las claves de un Hash. Toda config de seguridad hay
que **verificarla con un test**, no leerla y creerle — que es exactamente lo que
faltaba acá y lo que ahora existe.

---

**3. Un `Idempotency-Key` de más de 255 caracteres devuelve 500 en vez de 400.**
⚠️ **Sigue vivo** (verificado hoy contra la app corriendo).

*Síntoma*: cliente con un bug arma claves gigantes, recibe 500 y abre un ticket
de "su API está caída".

```bash
curl -X POST "$BASE/api/v1/stock/receive" -H "Idempotency-Key: $(python3 -c 'print("x"*300)')" ...
# => 500
```

```text
Pundit::AuthorizationNotPerformedError (Api::V1::StockOperationsController):
app/controllers/api/v1/base_controller.rb:120:in `verify_pundit_usage'
```

*Causa*: en `idempotency.rb:83`, el `around_action` corta antes del `yield`:

```ruby
if key.length > 255
  return render_error(:invalid_idempotency_key, "...", status: :bad_request)
end
```

Como la acción nunca corre, nunca se llamó a `authorize`, y el `after_action
:verify_pundit_usage` explota. Las **otras tres** ramas del `case/in` sí llaman a
`skip_pundit_verification`; esta se lo olvidó. Es la misma trampa que el propio
código documenta para el replay, aplicada a un camino que quedó fuera.

Nota: el arreglo del error #1 (el `rescue`/`else` alrededor del `yield`) **no
toca este camino**, porque acá el `around_action` corta con un `return` antes de
llegar al `case/in`. Son dos formas distintas de salirse del camino feliz y cada
una necesita su propio cuidado — que es justo la lección de abajo.

*Arreglo*: una línea.

```ruby
if key.length > 255
  skip_pundit_verification
  return render_error(:invalid_idempotency_key, "...", status: :bad_request)
end
```

*Lección general*: **cualquier `around_action` que cortocircuite tiene que
satisfacer los `after_action` que vienen después.** Si tenés un after_action que
verifica invariantes, cada camino que no llega a la acción es un candidato a
romperlo. La forma robusta es hacer el skip **al principio** de todos los caminos
que no hacen `yield`.

---

**4. Un JSON malformado devolvía 400 con cuerpo HTML en dev, y 500 en
producción.** ✅ **Corregido.**

*Síntoma*: el cliente hacía `JSON.parse(response.body)` sobre el error y explotaba
con `Unexpected token '<'`. El reporte que te llegaba era "su API devuelve HTML".

```bash
curl -s -D - -X POST "$BASE/api/v1/stock/receive" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"sku": '
# HTTP/1.1 400 Bad Request
# content-type: text/html; charset=UTF-8
# content-length: 7054              <- exactamente el tamaño de public/400.html
```

*Causa*, y acá hay que ser preciso porque la explicación que circula es falsa:
**el body NO se parsea en un middleware.** El parseo es **perezoso**: ocurre la
primera vez que alguien toca `params`. En este repo ese primer toque es un
`before_action` propio, y el backtrace lo dice sin ambigüedad:

```text
ActionDispatch::Http::Parameters::ParseError (Error occurred while parsing request parameters)
Caused by: JSON::ParserError (unexpected end of input at line 1 column 9)
app/controllers/api/v1/base_controller.rb:93:in `set_default_response_format'
```

O sea que la excepción ocurre **adentro** del controller y `rescue_from` sí puede
verla. No la veía por otra razón: **no había ningún `rescue_from` que matcheara**.
Y como `ParseError < StandardError`, el resultado dependía del entorno:

| Entorno | `rescue_from StandardError` | Resultado (antes) |
|---|---|---|
| dev/test | no registrado (`unless Rails.env.local?`) | escapaba a `ShowExceptions` → **400 + `public/400.html`** |
| producción | registrado | **500 `internal_error` en JSON** |

Las dos respuestas estaban mal: un body roto es culpa del cliente, así que
corresponde 400, y con el JSON del contrato. Lo mismo valía para
`ActionController::BadRequest` (ver §5.0): mismo mecanismo, mismo doble
comportamiento.

*Arreglo*: dos líneas en el concern, que cubren los dos casos de una. Es lo que
hoy está en `app/controllers/concerns/api/error_handling.rb`, líneas 37-38:

```ruby
rescue_from ActionController::BadRequest, with: :render_bad_request
rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_malformed_body

def render_bad_request(exception)
  render_error(:bad_request, exception.message.presence || "Solicitud inválida.",
               status: :bad_request)
end

def render_malformed_body(_exception)
  # NO devolvemos el mensaje del parser: filtra el contenido del body y la
  # posición exacta del error, que le sirve a un atacante para sondear.
  render_error(:malformed_body, "El cuerpo de la solicitud no es JSON válido.",
               status: :bad_request)
end
```

Fijate la asimetría entre los dos handlers, que es deliberada: el de `BadRequest`
devuelve `exception.message` porque ese mensaje lo escribimos nosotros en
`quantity_param`; el de `ParseError` **no**, porque el del parser trae el
contenido del body y la columna exacta del error. Es la regla de §6.2 aplicada
handler por handler.

Ojo con el orden: los `rescue_from` se evalúan **en orden inverso al de
declaración**, así que estos dos tienen que ir *después* del de `StandardError`
para ganarle. En este archivo se cumple, porque `StandardError` se declara
primero.

Verificado hoy contra la app corriendo (`content-type: application/json` en los
dos casos):

```text
{"error":{"code":"malformed_body","message":"El cuerpo de la solicitud no es JSON válido."},"status":400}
{"error":{"code":"bad_request","message":"El parámetro 'quantity' debe ser un entero"},"status":400}
```

Regresión en `spec/requests/api/v1/hardening_spec.rb`. Y la lección del bug quedó
escrita en el test: **asertar el status no alcanza**, hay que asertar también
`response.media_type` y el `code`. El spec viejo (`stock_operations_spec.rb:104`)
sólo miraba el status y por eso pasaba verde con una página HTML de respuesta.

`exceptions_app` **no** es el arreglo para este caso —la excepción nunca llega
tan afuera—, pero sí lo es para lo que de verdad pasa antes del controller: el
404 de routing y cualquier error que levante un middleware. Si querés que *eso*
también salga en JSON:

```ruby
# config/application.rb — sólo para lo que ocurre FUERA del controller
config.exceptions_app = lambda do |env|
  request = ActionDispatch::Request.new(env)
  status  = request.path_info[1..].to_i   # ShowExceptions setea PATH_INFO = "/404"

  if request.get_header("action_dispatch.original_path").to_s.start_with?("/api/")
    [ status, { "Content-Type" => "application/json" },
      [ { error: { code: "not_found", message: "Recurso no encontrado." },
          status: status }.to_json ] ]
  else
    ActionDispatch::PublicExceptions.new(Rails.public_path).call(env)
  end
end
```

*Lección general*: antes de decir "esto pasa en el middleware", **mirá el
backtrace**. En Rails casi nada del request se parsea con ganas: `params`,
`format` y `remote_ip` se resuelven la primera vez que los pedís, y eso mueve el
punto donde explotan. Lo que sí queda genuinamente fuera del alcance de
`rescue_from` es el 404 de routing y lo que levanta un middleware —`Rack::Attack`,
por ejemplo, arma su JSON a mano en `throttled_responder`
(`config/initializers/rack_attack.rb:278`) justamente porque corre antes de que
exista un controller.

---

**5. El optimistic locking de productos está a medio cablear.**
⚠️ **Sigue vivo** (verificado hoy contra la app corriendo).

*Síntoma*: el cliente hace `GET` de un producto y no encuentra el `lock_version`
que la doc le pide mandar en el `PATCH`. Termina no mandándolo, y entonces
**último que escribe gana**: dos operadores editan el precio y uno pierde su
cambio sin ningún error.

*Causa*: `products_controller.rb:56` lee `params[:lock_version]`, pero
`ProductSerializer` **no lo emite**. Verificado:

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/products/AMO-115" | jq '.data | keys'
# [..., "id","name","price","sku","unit","updated_at"]   <- no está lock_version

# con un lock_version viejo sí funciona, si te lo conseguís de algún lado:
curl -X PATCH ... -d '{"lock_version":99,"product":{"name":"X"}}'   # => 409
curl -X PATCH ... -d '{"product":{"name":"X"}}'                    # => 200, pisa
```

*Arreglo*: agregar `lock_version: object.lock_version` a `ProductSerializer`,
como ya hace `StockItemSerializer` (que lo documenta explícitamente). Si querés
ser estricto, hacé el `lock_version` **obligatorio** en el `PATCH` — pero eso es
un breaking change y va en v2.

*Lección general*: el optimistic locking sobre HTTP es un **ciclo**: el servidor
emite la versión, el cliente la devuelve, el servidor compara. Si falta cualquier
mitad, el mecanismo no protege nada y **no da error** — simplemente deja de
funcionar. Es la forma de ETag/If-Match, y tiene el mismo modo de falla.

---

**6. El 409 `duplicate` filtraba el mensaje crudo de Postgres.**
✅ **Corregido.**

*Síntoma*: ninguno — hasta que alguien leía un cuerpo de error y encontraba ahí el
nombre de un índice y **el valor que colisionó**, que puede ser dato de otro
usuario.

*Causa*: `app/services/application_service.rb:80` traducía el `RecordNotUnique` a
un `Result.failure` y le metía `e.message` como detalle:

```ruby
rescue ActiveRecord::RecordNotUnique => e
  Result.failure(:duplicate, "Ya existe un registro con esos datos.", detail: e.message)
```

`ErrorSerializer.from_result` renderiza `error.details` tal cual, así que eso
salía por el cable. Reproducido en su momento pasando un `RecordNotUnique` real
por la misma traducción:

```json
{
  "error": {
    "code": "duplicate",
    "message": "Ya existe un registro con esos datos.",
    "details": {
      "detail": "PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint \"index_categories_on_slug\"\nDETAIL:  Key (slug)=(dup-audit-zzz2) already exists.\n"
    }
  },
  "status": 409
}
```

Ahí hay tres cosas que el cliente no tenía por qué saber: que usás Postgres, cómo
se llama el índice (o sea la tabla y la columna), y el valor duplicado.

Lo notable es que el repo **ya tenía** la regla escrita y la aplicaba bien en el
500 (`render_internal_error` manda sólo un `request_id`) y en el 404
(`render_not_found` no dice ni el modelo). Este camino se la salteaba, y se la
salteaba justo en el lugar donde no se nota: nadie mira los cuerpos de los 409.

*Arreglo*: el `e.message` va al log, no al body. Es lo que hoy está en
`app/services/application_service.rb:80`:

```ruby
rescue ActiveRecord::RecordNotUnique => e
  Rails.logger.warn(event: "service.duplicate", error: e.message)
  Result.failure(:duplicate, "Ya existe un registro con esos datos.")
```

Verificado pasando un `RecordNotUnique` real por la misma traducción: el `details`
ya no aparece en la respuesta.

```json
{"error":{"code":"duplicate","message":"Ya existe un registro con esos datos."},"status":409}
```

La regresión está en `spec/requests/api/v1/hardening_spec.rb` y —esto es lo
interesante— **aserta ausencias**, no presencias:

```ruby
expect(response.body).not_to include("PG::")
expect(response.body).not_to match(/index_\w+/)
expect(response.body).not_to include("DETAIL")
```

Un test de fuga de información se escribe así: no podés enumerar todos los
mensajes posibles de Postgres, pero sí podés fijar las marcas que ninguno de
ellos debería dejar en un body.

Si querés darle algo accionable al cliente, extraé el **nombre lógico del campo**
de tu propio mapa de índices, nunca el texto de la excepción.

*Lección general*: **la regla "nunca `e.message` crudo" hay que aplicarla en cada
camino, no en el handler genérico.** El `rescue_from StandardError` es el que
todos revisan; los `rescue` puntuales que traducen una excepción a un DTO de
error son los que se olvidan, y son los que más contexto tienen para filtrar.

---

**7. La clave de idempotencia generada dentro del retry loop.**

*Síntoma*: duplicaste una operación aunque "tenés idempotencia". No hay error en
ningún log.

*Causa*: el cliente hace `SecureRandom.uuid` adentro del `retry`. Cada intento
lleva clave distinta: para el servidor son operaciones nuevas y todas legítimas.

*Arreglo*: es un problema **del cliente**, y por eso la documentación de la API
tiene que decirlo en negrita y el SDK tiene que hacerlo bien. Del lado servidor
lo único que podés hacer es **detectarlo**: alertar cuando un mismo `user_id`
manda N requests con el mismo `request_fingerprint` y claves distintas en pocos
segundos. La tabla `idempotency_keys` ya guarda todo lo necesario.

---

**8. El cliente reintenta con el mismo body pero cambia un campo derivado.**

*Síntoma*: 422 `idempotency_key_reuse` en reintentos que el cliente jura que son
idénticos.

*Causa*: el body lleva un `timestamp`, un `request_id` o un campo que el
serializador del cliente ordena distinto en cada serialización. El fingerprint es
sobre `request.raw_post`: **byte a byte**. `{"a":1,"b":2}` y `{"b":2,"a":1}` son
fingerprints distintos.

*Arreglo*: documentar que el reintento tiene que mandar **el mismo body byte a
byte** (guardalo serializado, no reserialices). Del lado servidor, si te importa
más la usabilidad que el rigor, podés normalizar antes de hashear
(`JSON.parse(raw).deep_sort.to_json`) — pero perdés el rigor con los tipos y con
los duplicados de claves, así que yo lo dejaría como está y lo documentaría.

---

**9. Cachear el 500 en la clave de idempotencia.**

*Síntoma*: arreglaste el bug, deployaste, y ese cliente sigue recibiendo el mismo
500 durante 24 horas.

*Causa*: la implementación cachea **toda** respuesta, no sólo las 2xx.

*Arreglo*: es lo que ya hace `persist_response` (`idempotency.rb:199`). Lo pongo
igual porque es el error #1 de las implementaciones caseras de idempotencia, y en
una entrevista es la pregunta de seguimiento obvia a "¿qué respuestas cacheás?".

---

**10. Rate limiter sobre un `NullStore`: no limita nada y no avisa.**

*Síntoma*: creés que tenés rate limiting; no tenés. Te enterás con la factura de
Postgres o con una caída.

*Causa*: `rate_limit` de Rails hace `store.increment(...)`;
`ActiveSupport::Cache::NullStore` devuelve `nil`, la comparación `count && count > to`
nunca se cumple, y el límite queda desactivado **sin un solo mensaje**.

*Arreglo*: lo que hace `base_controller.rb:46` — elegir el store
explícitamente y **loguear un warning** si el que hay no sirve. Detalle
relacionado del mismo archivo: dos `rate_limit` sin `name:` distinto comparten
contador y **cada request lo incrementa dos veces**, así que un límite de 20
corta en 11 (medido). Ver `docs/08`.

---

**11. El 404 que confirma existencia.**

*Síntoma*: alguien enumera tus recursos y no te das cuenta porque son todos 404.

*Causa*: devolver 404 cuando no existe y 403 cuando existe pero no es tuyo. La
diferencia **es** la información.

*Arreglo*: 404 para los dos casos en recursos privados, que es lo que hace este
repo (`render_not_found` no dice ni el modelo ni el id). Y del lado del ataque
sostenido, lo que corta es el rate limit por token de `docs/08`.

---

## Cómo responder esto en una entrevista

**1. "Explicame idempotencia en una API HTTP. ¿Cómo la implementarías?"**

> Idempotente significa que N requests idénticas dejan el mismo estado en el
> servidor que una. GET, PUT y DELETE lo son por semántica; POST no, porque
> significa "procesá este evento nuevo".
>
> Para hacer un POST idempotente hace falta que **el cliente** genere una clave
> —típicamente un UUID por operación de negocio— y la mande en `Idempotency-Key`.
> El servidor guarda `(user_id, key)` con un **índice único**, que actúa como
> lock distribuido: si dos requests concurrentes llegan con la misma clave, el
> `INSERT` de una falla con `RecordNotUnique` y esa devuelve 409 en vez de
> ejecutar dos veces. La fila tiene tres estados: `processing`, `completed`,
> `failed`. Un reintento de una `completed` devuelve la respuesta cacheada con
> `Idempotent-Replay: true`; una `failed` se puede reejecutar, porque un error no
> debería quemar la clave.
>
> Ahí hay un bug clásico que en este repo estuvo vivo y arreglé: eso valía para
> los fallos de negocio, pero no para los que salen como **excepción** vía
> `rescue_from` (404, 403, `RecordInvalid`). El `around_action` no llega a su
> segunda mitad, la fila queda trabada en `processing` y el cliente recibe 409
> durante las 24 h del TTL. Y el detalle fino es que **el `ensure` no lo
> arregla**: corre mientras la excepción sube, antes de que el `rescue_from`
> renderice, así que `response.status` todavía es 200 y marcarías `completed` con
> un cuerpo vacío. Va `rescue`/`else`: en el `rescue` marcás `failed` y
> re-lanzás; en el `else`, y sólo ahí, persistís la respuesta.
>
> Dos cosas que se olvidan casi siempre. Primero, el **fingerprint del body**: un
> SHA-256 del raw post. Si llega la misma clave con otro body devolvés 422; sin
> eso, un cliente con la clave hardcodeada recibe el resultado de otra operación y
> pierde datos en silencio. Segundo, **cachear sólo las 2xx**: si cacheás un 500,
> ese cliente lo recibe durante todo el TTL aunque el bug ya esté arreglado.
>
> *Trade-off*: la clave escrita en la base agrega un INSERT y un UPDATE por
> request. Con Redis es más barato, pero perdés la atomicidad con el commit de
> negocio: podés terminar con "Redis dice hecho" y la transacción con rollback. Yo
> elijo la base salvo que el volumen lo justifique.

**2. "¿Por qué `POST /stock/receive` y no `POST /movements`? ¿No es un
anti-patrón REST?"**

> Es RPC sobre HTTP y es deliberado. En un dominio de comandos la **intención**
> es dato: recibir mercadería y ajustar por conteo físico producen los dos una
> fila en el ledger, pero disparan procesos distintos —un ajuste abre una
> investigación de merma— y tienen parámetros distintos (`quantity` como delta vs
> `counted_quantity` como absoluto). Con un solo endpoint necesitás un body
> polimórfico, que en OpenAPI se resuelve con `oneOf` + discriminator, o sea
> admitir que son tres operaciones.
>
> Igual no es todo o nada: en el mismo repo el catálogo es CRUD REST puro y las
> transiciones de estado van como sub-recursos (`/purchase_orders/:id/submit`).
> Stripe hace lo mismo con `/charges/:id/capture`.
>
> *Trade-off*: perdés uniformidad y cacheabilidad, y cada endpoint hay que
> documentarlo a mano. Lo aceptás a cambio de que la intención quede registrada
> en el ledger, que es lo que auditoría necesita.

**3. "¿Por qué tokens opacos y no JWT?"**

> Por la **revocación**. Un JWT es un permiso firmado: una vez emitido vale hasta
> `exp` y no lo podés anular sin mantener una denylist, que es justamente el
> estado que el JWT prometía evitar. Acá revocar es un `UPDATE revoked_at` y
> surte efecto en la request siguiente, porque `authenticate` busca sobre el scope
> `active`.
>
> Además el JWT viaja en cada request (300-1500 bytes vs 48), sus claims son
> legibles en base64 por cualquiera que vea el token, y arrastra superficie
> criptográfica —`alg: none`, confusión RS256/HS256— que un token opaco no tiene.
>
> El costo del token opaco es **una query por request**, pero es un `find_by`
> sobre un índice único: menos de un milisegundo, y hasheamos el input y buscamos
> por digest, así que además no hay timing attack porque nunca comparamos el
> secreto en Ruby.
>
> *Cuándo elegiría JWT*: muchos servicios que necesitan validar sin llamar a un
> auth central, o federación entre organizaciones. Y ahí lo haría de vida corta
> (5-15 min) con refresh token opaco revocable, que es el patrón OIDC.

**4. "¿Por qué SHA-256 para el token y bcrypt para el password?"**

> Porque el stretching de bcrypt existe para compensar la **baja entropía** de un
> password humano: 20-30 bits, brute-forceable con diccionario. Un token que
> genero yo con `SecureRandom.urlsafe_base64(32)` tiene **256 bits**: no hay
> espacio que enumerar, así que no hay nada que compensar. Y como se valida en
> cada request, bcrypt a 100 ms me destruiría el throughput.
>
> Hay un segundo motivo, más fino: como busco por índice único sobre el digest,
> **nunca comparo el secreto en Ruby**, así que el timing es constante respecto
> del contenido. Con bcrypt tendría que traer el candidato primero y no tengo por
> qué campo buscarlo, porque el hash es salado.
>
> Regla corta: **secreto de baja entropía elegido por un humano → bcrypt/argon2;
> secreto aleatorio largo generado por la máquina → SHA-256.**

**5. "¿Cuándo devolvés 409 y cuándo 422? ¿Y por qué no 400?"**

> 400 es sintaxis: no pude parsear tu request, o falta un parámetro requerido.
> 422 es semántica: entendí perfecto el JSON, pero el contenido viola una regla
> de negocio —no hay stock, la orden no se puede cancelar en ese estado. 409 es
> estado: el contenido está bien, pero el servidor no lo permite *ahora* —perdiste
> el optimistic lock, hay una clave de idempotencia en vuelo, violaste un unique.
>
> La diferencia práctica es **qué hace el cliente después**: con 422 tiene que
> cambiar el body (reintentar igual falla siempre); con 409 puede releer y
> reintentar **sin cambiar nada** y funcionar. Y hay un tercero: 410, que dice
> "existía y ya no, no reintentes nunca" — acá es la reserva vencida.
>
> Distinguirlos importa operativamente: un 400 en el dashboard del cliente
> significa "tengo un bug en mi serializador", un 422 significa "el usuario pidió
> algo imposible". Si mandás todo como 400, el cliente no puede alertar sobre
> nada.

**6. "Tenés un listado con filtros y ordenamiento que vienen del usuario. ¿Cómo
lo hacés seguro?"**

> Allow-list, siempre. En este repo el `sort` es una **clave de un Hash
> congelado**, y si no matchea cae al default; el param nunca toca el SQL.
>
> El matiz que suele sorprender: Rails 8 tiene un guard
> (`ActiveRecord::UnknownAttributeReference`) que bloquea `order("name; DROP
> TABLE x")`, **pero acepta `"users.role"`** — el regex permite nombres de
> columna calificados con dirección. O sea que interpolar el param no te deja
> ejecutar SQL arbitrario, pero sí deja al cliente ordenar por cualquier columna
> de cualquier tabla del FROM, y eso es un oráculo de inferencia: ordenás por
> `password_digest` y extraés información sin necesidad de un UNION. Y `Arel.sql`
> desactiva el guard por completo, así que hay que tratarlo como un bloque
> `unsafe`.
>
> Dos cosas más en el mismo lugar: `sanitize_sql_like` para el `ILIKE` —sin eso
> un `%` te fuerza un seq scan y es un DoS de un carácter— y **desempate por `id`
> en todo `ORDER BY`**, porque sin él dos filas empatadas salen en orden distinto
> en páginas distintas y ves registros duplicados o te salteás otros.

**7. "¿Offset o cursor para paginar?"**

> Depende de si el usuario navega o consume. Offset para listados que un humano
> recorre —necesitás "página 5 de 12" y el total—; el costo es que la página N
> hace que Postgres genere y descarte N·limit filas, así que la página 5000 tarda
> segundos, y si alguien inserta mientras paginás se corre todo y ves filas
> repetidas.
>
> Cursor (keyset) para feeds y ledgers: `WHERE (occurred_at, id) < (?, ?)` con un
> índice compuesto en ese orden. Es O(log n) para cualquier página y es estable
> ante inserts porque el cursor apunta a una fila concreta. El precio es que no
> podés saltar a una página arbitraria ni dar el total sin un `COUNT(*)` caro —
> para un log infinito eso es irrelevante.
>
> Dos detalles de implementación que valen: el cursor va **opaco** (base64 de un
> JSON) para que el cliente no lo trate como contrato, y el timestamp adentro va
> con **microsegundos**; si truncás a segundos, dos filas del mismo segundo se
> pisan y te saltea filas.
>
> Y en los dos casos, **el `limit` se clampea en el código de la app**. En este
> repo el `max_limit` de Pagy quedó inerte por un cambio de nombre de la opción
> entre versiones (`:limit_max`, y sólo si requerís la extra), y `?limit=5000`
> devolvía 5000 filas. Lo arreglé con un `MAX_PAGE_SIZE` y un `clamp` propios en
> el controller base, más un test que lo fija. Es exactamente el tipo de config
> que falla en silencio: hay que cubrirla con un test, no con fe.

---

## Para seguir

- `docs/08-rate-limiting.md` — las dos capas de límites, algoritmos y el
  discriminador correcto.
- `docs/07-colas-jobs-y-mensajeria.md` — el patrón outbox completo del otro lado
  del webhook.
- `docs/06-concurrencia-transacciones-y-locking.md` — optimistic vs pessimistic,
  que es lo que hay detrás del 409.
- `docs/09-testing.md` — request specs, y por qué son el contrato ejecutable.
