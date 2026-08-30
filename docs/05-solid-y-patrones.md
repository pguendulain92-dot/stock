# SOLID y patrones de diseño en Rails

Acá tenés los cinco principios SOLID explicados con el código real de esta app
—no con el ejemplo del `Rectangle` y el `Square`—, el catálogo de patrones que el
proyecto efectivamente usa (con archivo y línea), una sección sobre **cuándo NO
aplicar el patrón**, y una sobre qué significa "código limpio" en Ruby, que no es
lo mismo que en Java.

Está escrito para vos, que venís de Spring + JPA. Cada principio tiene su
equivalente en Java y —lo importante— **dónde la analogía se rompe**, porque el
duck typing y los módulos cambian el costo de casi todas estas decisiones.

Todo el código citado sale del repositorio. Los comentarios del código son la
fuente de verdad; este documento los amplía y conecta.

---

## 1. El inventario real de la app

Antes de teorizar, los números. Las cinco primeras filas de la tabla salen de
correr esto (la última la conté a mano: `Money` y `Quantity`):

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
bin/rails runner 'Rails.application.eager_load!
  puts "services:    #{ApplicationService.descendants.size}"
  puts "queries:     #{ApplicationQuery.descendants.size}"
  puts "forms:       #{ApplicationForm.descendants.size}"
  puts "serializers: #{ApplicationSerializer.descendants.size}"
  puts "policies:    #{ApplicationPolicy.descendants.size}"'
```

| Capa | Clase base | Cuántas hay | Contrato público | Tu equivalente en Java |
|---|---|---|---|---|
| Casos de uso | `ApplicationService` | 12 | `.call(**kwargs) -> Result` | `@Service` + `@Transactional` |
| Lecturas | `ApplicationQuery` | 6 | `.call(**kwargs) -> Relation` | `@Repository` con `@Query` |
| Entrada compleja | `ApplicationForm` | 2 | `#save -> Result` | `@Valid` RequestDTO + Bean Validation |
| Salida JSON | `ApplicationSerializer` | 6 | `#as_json -> Hash` | DTO + Jackson |
| Autorización | `ApplicationPolicy` | 9 | un método por acción, booleano | `@PreAuthorize` / `AccessDecisionVoter` |
| Value objects | `Data.define` | 2 | inmutable, comparado por valor | `record` de Java 16+ |

Los 12 services, tal como los lista el runtime:

```text
Purchasing::ReceiveOrder     Stock::Issue                Stock::Reserve
Stock::Adjust                Stock::ItemResolver         Stock::Transfers::Dispatch
Stock::ApplyMovement         Stock::Receive              Stock::Transfers::Receive
Stock::CommitReservation     Stock::ReleaseReservation
Stock::ExpireReservations
```

**Dato que importa**: si corrés ese mismo script **sin** `eager_load!`, te
devuelve `0` en todo. Zeitwerk carga por demanda: una clase que nadie referenció
todavía **no existe** como constante. Volvemos sobre esto en OCP, porque destruye
el reflejo de "descubro los implementadores escaneando el classpath" que traés de
Spring.

---

## 2. SRP — Single Responsibility Principle

> Una clase, una razón para cambiar.

### 2.1 Cómo se viola típicamente en Rails

Rails te empuja a violarlo. El generador te da `models/`, `controllers/` y
`views/`, y todo lo demás **no existe hasta que vos lo creás**. Entonces la
lógica cae por gravedad en dos lugares:

- **El modelo gordo.** `StockItem#receive!` que bloquea la fila, valida reglas,
  escribe el ledger, emite el evento y manda un mail. Es el camino al God Model
  de 2000 líneas. Y como `ActiveRecord::Base` ya trae persistencia, validaciones,
  callbacks, asociaciones y serialización, el modelo arranca con cuatro
  responsabilidades encima antes de que escribas una línea.
- **El controller gordo.** `if @item.quantity_available < params[:quantity].to_i`
  dentro de una acción. La prueba objetiva de que está mal: no podés ejecutar esa
  regla desde `bin/rails runner`, desde un job ni desde un import CSV. La vas a
  duplicar, y las dos copias van a divergir.

### 2.2 El ejemplo real: un solo lugar escribe stock

`app/services/stock/apply_movement.rb` es **el único punto del sistema que escribe
`quantity_on_hand`** —el stock físico— y el único que escribe un asiento en el
ledger. Lo verifiqué grepeando: la única asignación a esa columna en todo `app/`
está en `apply_movement.rb:133`. (El modelo además expone primitivas que podrían
escribirla —`#apply_delta!` en `stock_item.rb:85` y `.atomically_decrement` en
`:115`—, pero hoy no las llama nadie en `app/`: sólo los specs.) Su `call` tiene
seis pasos y nada más:

```ruby
def call
  transactional do
    if (existing = replayed_movement)   # 1. idempotencia
      next success(existing)
    end

    item = lock_stock_item!             # 2. SELECT ... FOR UPDATE
    validate!(item)                     # 3. invariantes sobre el estado bloqueado

    apply_to(item)                      # 4. proyección
    movement = write_ledger_entry(item) # 5. asiento inmutable
    publish_event(item, movement)       # 6. outbox

    success(movement)
  end
end
```
<sub>`app/services/stock/apply_movement.rb:61`</sub>

La excepción hay que decirla, porque si no la afirmación es falsa:
`Stock::Reserve` y `Stock::ReleaseReservation` **sí** escriben directo
`quantity_reserved` (`reserve.rb:62`, `release_reservation.rb:37`), sin pasar por
`ApplyMovement` y sin asiento en el ledger. Es deliberado y coherente: reservar no
mueve mercadería, sólo la compromete; no hay nada físico que asentar. La regla
exacta es "una unidad no entra ni sale de un depósito sin pasar por
`ApplyMovement`", no "nadie toca una columna de cantidad".

Y los siete services de negocio que le pegan encima son **finitos**.
`Stock::Issue` completo, sin comentarios, es esto:

```ruby
def call
  return Result.failure(:invalid_quantity, "La cantidad debe ser positiva") unless @quantity.positive?

  transactional do
    resolved = ItemResolver.call(product: @product, warehouse: @warehouse, create_if_missing: false)
    fail!(resolved.error.code, resolved.error.message, **resolved.error.details) if resolved.failure?

    ApplyMovement.call(
      stock_item: resolved.value, kind: "issue",
      quantity: -@quantity,     # <- el signo lo pone el dominio, no el cliente
      user: @user, reference: @reference, reason: @reason,
      idempotency_key: @idempotency_key,
      event_recorder: @event_recorder, clock: @clock
    ).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
  end
end
```
<sub>`app/services/stock/issue.rb:22`</sub>

No hay locking, ni ledger, ni eventos: sólo lo que es específico de "sacar
mercadería". Esa es la única razón por la que este archivo cambiaría.

El beneficio concreto se ve cuando llega un requisito transversal. "Prohibir
movimientos sobre productos dados de baja" fue **una línea** en un solo archivo:

```ruby
fail!(:product_discarded, "El producto está dado de baja") if item.product.discarded?
```
<sub>`app/services/stock/apply_movement.rb:129` — y los 7 services que dependen de él (`Receive`, `Issue`, `Adjust`, `CommitReservation`, `Transfers::Dispatch`, `Transfers::Receive`, `Purchasing::ReceiveOrder`) la heredaron sin tocarse</sub>

### 2.3 Dónde SÍ va la lógica en el modelo

SRP no significa "modelo anémico". `app/models/stock_item.rb` tiene bastante
código, y está bien puesto:

| Va en el modelo | Ejemplo real | Va en el service |
|---|---|---|
| Lecturas derivadas | `#available`, `#below_reorder_point?`, `#valuation` (`stock_item.rb:58-69`) | Operaciones con lock + ledger + evento |
| Validaciones de forma | `#reserved_cannot_exceed_on_hand` (`:175`) | Reglas que dependen del caso de uso |
| Scopes reutilizables | `.in_stock`, `.needing_reorder` (`:47-52`) | Consultas con 6 filtros → query object |
| Primitivas de persistencia | `.atomically_decrement` (`:115`), `.find_or_provision!` (`:158`) | Orquestación de varias primitivas |

La regla que uso para decidir: **si el método necesita una transacción, es un
caso de uso**. Si sólo lee o valida forma, es del modelo.

### 2.4 El equivalente Java, y dónde se rompe

En Spring esto es natural: la `@Entity` de JPA es anémica *porque no puede ser
otra cosa* —la persistencia vive en el `EntityManager`, no en la entidad— y los
casos de uso viven en `@Service` con `@Transactional`.

**Acá se rompe la analogía, y es el error número uno del que llega desde Java:**

| | JPA / Hibernate (Data Mapper) | Active Record |
|---|---|---|
| Quién persiste | `EntityManager` / `Session` | El objeto mismo: `item.save!` |
| Contexto de persistencia | Sí (1er nivel de caché) | **No existe** |
| Dirty checking | Diferido al `flush` | **No hay**: `save!` emite el UPDATE ahí mismo |
| Entidades *detached* | Concepto central | **No existe** el concepto |
| Lazy loading de asociaciones | Transparente dentro de la sesión | `product.category` dispara **una query en ese instante** |
| Anemia del modelo | Sale gratis | Hay que imponerla a mano |

Consecuencias prácticas que te van a preguntar:

1. **No podés "juntar" escrituras.** En JPA modificás 50 entidades y el flush
   manda 50 UPDATEs al final, agrupados. En Active Record son 50 round-trips
   inmediatos, salvo que uses `update_all` / `insert_all!` explícitamente
   (`app/forms/stock_transfer_form.rb:80`).
2. **El N+1 es trivial de crear**, porque no hay sesión que memorice nada. Por eso
   los query objects de este repo siempre traen `includes` explícito.
3. **No hay proxy transaccional**, y eso te salva de un bug clásico de Spring: en
   Spring, llamar a un método `@Transactional` **desde el mismo bean** saltea el
   proxy y no abre transacción. En Ruby no hay proxy: `transactional do ... end`
   es un bloque, siempre corre. Pero tenés la trampa espejo:

```ruby
# ApplicationRecord.transaction ANIDADA se UNE a la de afuera por defecto.
# `raise ActiveRecord::Rollback` adentro NO revierte la externa: se lo traga.
# Y desde Rails 7, un `return` dentro del bloque HACE COMMIT de lo escrito.
```
Por eso `ApplicationService` no usa `return` ni `ActiveRecord::Rollback`: usa una
excepción propia que viaja hasta el `rescue` de `transactional`
(`app/services/application_service.rb:46` y `:68`).

---

## 3. OCP — Open/Closed Principle

> Abierto a la extensión, cerrado a la modificación.

### 3.1 Cómo se viola típicamente

El `case` que crece:

```ruby
# ❌ cada operación nueva edita un método ya testeado
def apply(kind, qty)
  case kind
  when "receipt" then ...
  when "issue"   then ...
  when "adjustment" then ...
  end
end
```

Cada agregado es un riesgo de regresión sobre código que ya funcionaba, y el
método se vuelve intocable.

### 3.2 El ejemplo real (1): agregar una operación es agregar una clase

Las 12 clases de `ApplicationService` son la aplicación literal de OCP. Agregar
"devolución a proveedor" es crear `app/services/stock/return_to_supplier.rb`,
llamar a `ApplyMovement` con `kind: "return"` y agregar una ruta. **Cero archivos
existentes modificados**, cero riesgo sobre los tests que ya pasan.

### 3.3 El ejemplo real (2): el registro de adapters del outbox

```ruby
class Publisher
  ADAPTERS = {
    "log"     => -> { LogAdapter.new },
    "noop"    => -> { NoopAdapter.new },
    "webhook" => -> { WebhookAdapter.new(url: ENV.fetch("OUTBOX_WEBHOOK_URL")) }
    # "kafka"    => -> { KafkaAdapter.new(...) }      # ruby-kafka / rdkafka
    # "rabbitmq" => -> { RabbitAdapter.new(...) }     # bunny
    # "sns"      => -> { SnsAdapter.new(...) }        # aws-sdk-sns
  }.freeze

  def self.build(name = ENV.fetch("OUTBOX_ADAPTER", "log"))
    ADAPTERS.fetch(name) { raise ArgumentError, "Adapter de outbox desconocido: #{name}" }.call
  end
end
```
<sub>`app/services/outbox/publisher.rb:17`</sub>

Tres detalles que valen en una entrevista:

- Los valores son **lambdas**, no instancias. Si fueran instancias,
  `WebhookAdapter.new(url: ENV.fetch(...))` se evaluaría al cargar la clase y
  reventaría el boot en cualquier entorno sin `OUTBOX_WEBHOOK_URL`. Con lambda,
  el costo se paga sólo si elegís ese adapter. Es *lazy initialization* a mano.
- `fetch` con bloque en vez de `[]`: una clave desconocida **explota con un
  mensaje útil** en vez de devolver `nil` y fallar 40 líneas después con
  `NoMethodError on nil`.
- `.freeze` sobre el hash: nadie le agrega un adapter en caliente desde otro
  archivo. En un servidor multi-thread eso sería una mutación compartida sin lock.

El consumidor no conoce ningún adapter concreto:

```ruby
def publisher = Outbox::Publisher.build
```
<sub>`app/jobs/outbox/publish_pending_job.rb:74`</sub>

Aclaración honesta: hoy la app **no** ejerce el registro. `OUTBOX_ADAPTER` no está
seteado en ningún entorno, así que `Publisher.build` siempre devuelve
`LogAdapter`. El valor de la estructura es que agregar Kafka mañana no toca ni el
job ni ningún service; no que haya tres adapters rotando en producción.

### 3.4 Otras tablas de datos que reemplazan condicionales

El repo usa la misma técnica en varios lugares. Todas son "agregá una fila, no
toques la lógica":

| Tabla | Archivo | Qué evita |
|---|---|---|
| `STATUS_FOR` (código de error → HTTP) | `app/controllers/concerns/api/error_handling.rb:47` | Un `case` de 17 ramas en cada controller |
| `SORTS` (nombre → cláusula ORDER BY) | `app/queries/products/search.rb:25` | Interpolar `params[:sort]` en SQL (inyección) |
| `TRANSITIONS` (estado → estados válidos) | `app/models/stock_transfer.rb:35`, `purchase_order.rb:27` | `if status == "draft" && ...` repartido |
| `MOVEMENT_STYLES` / `STATUS_STYLES` | `app/helpers/application_helper.rb:9` y `:20` | Clases de Tailwind duplicadas en las 9 vistas que usan los badges |
| `ROLE_RANK` (rol → nivel) | `app/models/user.rb:51` | Comparaciones de rol a mano en cada policy |

### 3.5 El equivalente Java, y dónde se rompe

En Spring esto sale casi gratis: declarás `interface EventPublisher`, marcás cada
implementación con `@Component`, y Spring te inyecta un
`Map<String, EventPublisher>` con todas, descubiertas por *classpath scanning*.
Sumás `@ConditionalOnProperty` y ya elegís por configuración.

**Dónde se rompe:** en Ruby **no hay classpath scanning**, y Zeitwerk carga por
demanda. Lo medí: `ObjectSpace.each_object(Class).select { |k| k < ApplicationService }`
devuelve **0** en un `bin/rails runner` sin `eager_load!`, y **12** con él. O sea:

- Un "auto-registro" del estilo `def self.inherited(sub) = REGISTRY << sub`
  **funciona en producción** (donde `config.eager_load = true` carga todo al
  bootear) y **falla en desarrollo y en tests** (donde la clase no existe hasta
  que alguien la nombra). Es una de las diferencias entre entornos más
  desconcertantes de Rails.
- Por eso el registro es un **hash explícito**. Es más "tipeo", pero es
  determinístico, se lee de un vistazo y no depende del modo de carga.

Corolario del mismo mecanismo, ya documentado en el repo: `Outbox::NullRecorder`
vive en **su propio archivo** justamente porque si estuviera dentro de
`recorder.rb`, la constante existiría sólo después de que alguien cargue
`Outbox::Recorder` (`app/services/outbox/null_recorder.rb:18-27`).

---

## 4. LSP — Liskov Substitution Principle

> Si `S` es subtipo de `T`, poder usar un `S` donde se espera un `T` sin que nada
> se entere.

### 4.1 Cómo se viola típicamente

Un service que a veces devuelve `Result`, a veces `true/false` y a veces levanta
excepción. El que llama no puede escribir un solo camino de manejo de error:
tiene que saber *cuál* service está llamando, y ahí perdiste la sustituibilidad.

### 4.2 El ejemplo real, ejecutado

Los 12 services responden `.call` y devuelven `Result`. Lo comprobé corriendo
esto contra la base de desarrollo con datos de seed:

```ruby
rec = Outbox::NullRecorder.new
ops = [
  [Stock::Receive, { product: p1, warehouse: w, quantity: 5 }],
  [Stock::Issue,   { product: p1, warehouse: w, quantity: 3 }],
  [Stock::Reserve, { product: p1, warehouse: w, quantity: 2 }],
  [Stock::Issue,   { product: p1, warehouse: w, quantity: 999_999 }]
]
ops.each do |klass, args|
  r = klass.call(**args, user: u, event_recorder: rec)
  puts format("%-26s -> %-8s %s", klass.name, r.class,
              r.ok? ? "OK #{r.value.class}" : "FAIL #{r.error.code}")
end
```

Salida real:

```text
producto=TOR-M5-20 deposito=BA-01
Stock::Receive             -> Result   OK StockMovement
Stock::Issue               -> Result   OK StockMovement
Stock::Reserve             -> Result   OK StockReservation
Stock::Issue               -> Result   FAIL insufficient_stock
```

El bucle no sabe qué clase está invocando. Eso es LSP, y es lo que permite que el
controller tenga **un solo** traductor de respuestas para toda la API:

```ruby
def render_result(result, success_status: :ok, serializer: nil)
  if result.ok?
    body = serializer && result.value ? serializer.new(result.value).as_json : result.value
    render json: { data: body }, status: success_status
  else
    status = STATUS_FOR.fetch(result.error.code, :unprocessable_content)
    render json: ErrorSerializer.from_result(result, status: Rack::Utils.status_code(status)), status:
  end
end
```
<sub>`app/controllers/concerns/api/error_handling.rb:67`</sub>

### 4.3 Los forms también, con otro nombre de método

`ApplicationForm#save` devuelve `Result` igual que los services:

```ruby
def save
  return Result.failure(:validation_failed, errors.full_messages.to_sentence,
                        errors: errors.to_hash(true)) unless valid?

  ApplicationRecord.transaction { persist! }
rescue ActiveRecord::RecordInvalid => e
  Result.failure(:validation_failed, e.record.errors.full_messages.to_sentence,
                 errors: e.record.errors.to_hash(true))
end
```
<sub>`app/forms/application_form.rb:30`</sub>

Se llama `save` y no `call` **a propósito**: un form object incluye
`ActiveModel::Model`, y `form_with` de Rails espera un objeto que responda como
un modelo (`to_key`, `to_param`, `errors`, `save`). El contrato con *Rails* pesa
más que la simetría con los services. Es duck typing puro: a `form_with` no le
importa la clase, le importa qué mensajes contesta.

### 4.4 El detalle honesto

`Stock::ExpireReservations` **no** usa `transactional` (procesa en lotes, con una
transacción por reserva, para no tener una transacción larga que frene el VACUUM)
y devuelve `Result.success(expired:, failed:)` — o sea, su `value` es un Hash y
no un registro de ActiveRecord (`app/services/stock/expire_reservations.rb:29`).

Sigue cumpliendo LSP porque el contrato es *"devuelve un `Result`"*, no *"devuelve
un `Result` con un AR adentro"*. Y `render_result` lo tolera porque `serializer:`
es opcional. Si el contrato hubiera sido más estricto, esta clase lo violaría: la
lección es que **el contrato tiene que estar escrito**, porque en Ruby no hay
firma que lo diga.

### 4.5 El equivalente Java, y dónde se rompe

En Java escribirías `interface UseCase<C, R> { Result<R> execute(C command); }` y
**el compilador** te garantiza LSP: no podés devolver otra cosa.

Dónde se rompe:

- **No hay compilador.** Lo más parecido a un método abstracto es esto, y falla en
  runtime, no al compilar:

```ruby
def call
  raise NotImplementedError, "#{self.class} debe implementar #call"
end
```
<sub>`app/services/application_service.rb:59` y `app/queries/application_query.rb:27`, `app/forms/application_form.rb:42`, `app/serializers/application_serializer.rb:37`</sub>

- **La red real son los tests.** Un doble "flexible" (`double`) responde
  cualquier cosa y te da verde en falso; por eso el proyecto usa `class_double`
  y `instance_double` (verificados contra la clase real) y un Null Object que es
  código de verdad.
- **A cambio ganás algo**: no necesitás que las clases compartan jerarquía para
  ser sustituibles. `Outbox::Recorder` y `Outbox::NullRecorder` **no tienen
  ninguna superclase en común** y son intercambiables. En Java necesitarías la
  interfaz declarada, o `Object` y reflection.

---

## 5. ISP — Interface Segregation Principle

> Nadie debería depender de métodos que no usa.

### 5.1 Cómo se viola típicamente en Rails

- Pasar el modelo entero de ActiveRecord a todos lados. Un colaborador que sólo
  necesita `product.sku` termina dependiendo de 40 columnas, 8 asociaciones y
  todo el ciclo de callbacks — y en el test tenés que crear la fila.
- Una clase base con 30 helpers que todas las subclases heredan.
- El "manager" con 15 métodos públicos.

### 5.2 El ejemplo real: la interfaz del Recorder es un método

```ruby
class Recorder
  def record(aggregate:, event_type:, payload: {}, metadata: {}, occurred_at: Time.current)
```
<sub>`app/services/outbox/recorder.rb:17`</sub>

Esa es **toda** la interfaz que ven los 11 services que emiten eventos (el
doceavo, `Stock::ItemResolver`, no emite ninguno y por eso no recibe recorder).
Y por eso implementarla completa cuesta siete líneas:

```ruby
class NullRecorder
  attr_reader :recorded

  def initialize = @recorded = []

  def record(aggregate:, event_type:, payload: {}, metadata: {}, occurred_at: Time.current)
    @recorded << { aggregate:, event_type:, payload:, metadata:, occurred_at: }
    nil
  end
end
```
<sub>`app/services/outbox/null_recorder.rb:28`</sub>

La regla operativa: **el tamaño de la interfaz es el costo de cada test**. Si el
doble es caro de escribir, la interfaz es demasiado grande.

Lo mismo con los adapters del publisher: `publish(message)`, un método. El
`NoopAdapter` agrega sólo un `attr_reader :published` para poder inspeccionar
(`app/services/outbox/publisher.rb:41`); es el que instancia el spec del job
(`spec/jobs/outbox_publish_pending_job_spec.rb:6`).

Y con los serializers: `#as_json` + `.collection`.

```ruby
def self.collection(objects, **options)
  objects.map { |o| new(o, **options).as_json }
end
```
<sub>`app/serializers/application_serializer.rb:33`</sub>

### 5.3 ISP aplicado a los datos, no sólo a los métodos

`ProductSerializer` no calcula la disponibilidad: la **recibe**.

```ruby
availability: options[:availability],
```
<sub>`app/serializers/product_serializer.rb:23`</sub>

El controller la calcula para los 25 productos de la página con **una** query
agregada y se la pasa (`app/controllers/api/v1/products_controller.rb:18-27` +
`app/queries/stock_items/availability.rb`). Si el serializer dependiera de
`product.stock_items`, dependería de una asociación que no necesita, y tendrías
25 queries por página. Depender de menos = ser más rápido, acá literalmente.

Contra-ejemplo bueno del mismo repo, en la otra dirección: `ApplyMovement` acepta
**o** un modelo **o** un id, y se queda sólo con el id:

```ruby
@stock_item_id = stock_item.is_a?(StockItem) ? stock_item.id : stock_item
```
<sub>`app/services/stock/apply_movement.rb:46`</sub>

Igual que `CommitReservation`, `ReleaseReservation`, `Dispatch` y `ReceiveOrder`.
El service **no depende del objeto que le pasaste**, porque lo va a releer con
`lock` adentro de la transacción de todos modos. Un objeto leído afuera del lock
está viejo por definición.

### 5.4 El equivalente Java, y dónde se rompe

En Java declarás `interface EventRecorder { void record(DomainEvent e); }` y listo:
el compilador te dice quién la implementa, el IDE te da "Go to implementations", y
si agregás un método rompés la compilación de todos los implementadores.

Dónde se rompe:

| | Java | Ruby |
|---|---|---|
| Dónde está declarada la interfaz | En un archivo `.java` | **En ningún lado.** Es el conjunto de mensajes que mandás |
| Quién la implementa | El IDE te lo dice | `grep -rn "def record"` |
| Agregar un parámetro | Error de compilación en todos | Silencio **hasta que se ejecuta esa rama** |
| Verificar en runtime | `instanceof` | `respond_to?(:record)` |

Ese "silencio" es exactamente el motivo por el que el proyecto usa un **Null
Object real** en vez de un mock: si mañana `record` recibe un keyword nuevo,
`NullRecorder` falla ruidosamente con `ArgumentError` en el primer test que lo
use; un `double(record: nil)` seguiría diciendo que sí a todo.

---

## 6. DIP — Dependency Inversion Principle

> Dependé de abstracciones, no de implementaciones. Y que las dependencias entren
> desde afuera.

### 6.1 Cómo se viola típicamente

```ruby
# ❌ dependencia dura, invisible desde la firma
def call
  Outbox::Recorder.new.record(...)   # ¿cómo lo testeo sin escribir en la DB?
  StockMovement.create!(occurred_at: Time.current)  # ¿cómo testeo el vencimiento?
end
```

### 6.2 El ejemplo real: keyword args con default

```ruby
def initialize(stock_item:, kind:, quantity:, reserved_delta: 0,
               user: nil, reference: nil, reason: nil, unit_cost_cents: nil,
               idempotency_key: nil, occurred_at: nil, metadata: {},
               event_recorder: Outbox::Recorder.new, clock: Time)
```
<sub>`app/services/stock/apply_movement.rb:42` — 11 de los 12 services siguen el mismo patrón; `Stock::ItemResolver` es el único sin dependencias inyectadas, porque no toca reloj ni eventos</sub>

Dos dependencias inyectadas, con default de producción:

- `event_recorder:` — cualquier objeto que responda `record(...)`.
- `clock:` — cualquier objeto que responda `current`. El default es la clase
  `Time` (que responde `Time.current` gracias a ActiveSupport).

En los tests entran los dobles:

```ruby
describe "inyección del reloj" do
  it "usa el reloj que le pasás (sin sleep, sin esperar)" do
    momento = Time.zone.local(2026, 1, 15, 10, 30)
    # Un doble VERIFICADO: si `Time` no respondiera `current`, el test fallaría.
    reloj = class_double(Time, current: momento)

    result = described_class.call(product:, warehouse:, quantity: 5, user:,
                                  event_recorder: recorder, clock: reloj)

    expect(result.value.occurred_at).to be_within(1.second).of(momento)
  end
end
```
<sub>`spec/services/stock/receive_spec.rb:118`</sub>

Y lo verifiqué de punta a punta: con `Outbox::NullRecorder` inyectado, las cuatro
operaciones del §4.2 generaron **3 eventos capturados en memoria** y **0 filas
nuevas en `outbox_events`**.

```text
eventos capturados por el NullRecorder: 3
["stock.receipt", "stock.issue", "stock.reserved"]
filas nuevas en outbox_events: 0
```

### 6.3 Por qué NO hace falta un container de DI en Ruby

En Spring necesitás el container por razones que en Ruby simplemente no aplican:

| Por qué Spring necesita container | Situación en Ruby |
|---|---|
| Instanciar sin `new` para poder sustituir | `new` es barato y sustituible: pasás otro objeto |
| Resolver el grafo por tipo | No hay tipos que resolver; pasás el objeto |
| Crear proxies para `@Transactional` / `@Cacheable` | Se hace con bloques (`transactional do`) y módulos |
| Configurar por perfil / entorno | `ENV.fetch("OUTBOX_ADAPTER", "log")` |
| Singletons gestionados | Constantes y `||=`; el proceso ya es el scope |

El "container" acá es **el valor por defecto del keyword arg**. Es código
normal, se lee en la firma, y no requiere XML, anotaciones ni reflection.

### 6.4 Qué perdés (esto es lo que te va a preguntar un entrevistador honesto)

1. **No hay verificación del grafo al bootear.** Spring falla en el arranque con
   `NoSuchBeanDefinitionException`. Acá, si el default de un service apunta a una
   clase mal escrita, te enterás en la **primera llamada en producción**. Mitigación
   real del repo: `config.eager_load = true` en producción
   (`config/environments/production.rb:10`), que al menos hace fallar el **deploy**
   y no la primera request. Sobre las otras redes: **el CI corría RuboCop,
   Brakeman, bundler-audit y RSpec, y no corría `zeitwerk:check`**. Eso se
   arregló: hoy hay un paso «Check Zeitwerk autoloading»
   (`bin/rails zeitwerk:check` en `.github/workflows/ci.yml`), que carga la app
   entera y adelanta al CI la clase de fallas de autoloading que antes aparecían
   recién en el deploy. Ojo igual con qué cubre: `zeitwerk:check` sólo verifica
   que cada archivo defina la constante que su nombre promete, **no** que la
   referencia exista. Un default mal escrito en un keyword arg lo sigue
   descubriendo la primera llamada.
2. **No hay scopes.** `event_recorder: Outbox::Recorder.new` construye **una
   instancia nueva por llamada**, porque los defaults se evalúan en cada
   invocación. Acá da igual (el `Recorder` no tiene estado), pero si mañana
   guardara un pool de conexiones o un buffer, estarías creando uno por
   operación y **nadie te avisa**. En Spring sería `@Scope("singleton")` y listo.
3. **No hay AOP declarativo.** Ni `@Transactional`, ni `@Retryable`, ni
   `@Cacheable`. Cada service escribe `transactional do` a mano. El lado bueno:
   no existe el bug de auto-invocación del proxy de Spring.
4. **El wiring está desparramado.** No hay un `ApplicationConfig` donde veas el
   grafo completo: está en 11 firmas de constructor. Cambiar el recorder por
   defecto son 11 ediciones. Cuando eso empieza a doler, la respuesta idiomática
   es una constante o una fábrica (que es exactamente lo que ya hace
   `Outbox::Publisher.build`), no meter un container.
5. **Nada impide saltear la inyección.** `Outbox::Recorder.new.record(...)` está
   escrito duro en `app/controllers/api/v1/purchase_orders_controller.rb:46`. Es
   una decisión razonable (esa acción no pasa por un service), pero es también la
   prueba de que la disciplina la sostiene el code review, no el compilador.

### 6.5 Resumen SOLID: Java vs este repo

| Principio | Cómo lo garantiza Java | Cómo lo garantiza este repo | Qué se pierde |
|---|---|---|---|
| SRP | Capas por convención del framework | Carpetas `services/` `queries/` `forms/` creadas a mano | Nada; hay que crearlas |
| OCP | Classpath scanning + `@ConditionalOnProperty` | Hash de lambdas congelado (`Publisher::ADAPTERS`) | Auto-descubrimiento (Zeitwerk es lazy) |
| LSP | El compilador y la interfaz | Clase base + `NotImplementedError` + tests | Chequeo estático; falla en runtime |
| ISP | `interface` explícita y chica | Duck typing + Null Objects reales | "Go to implementations"; hay que grepear |
| DIP | Container, `@Autowired`, scopes | Keyword args con default | Validación del grafo al bootear; scopes; AOP |

---

## 7. Los patrones que usa el repo

### 7.1 Service Object (Command)

**Qué es**: una clase, un método público, una operación de negocio.
**Dónde**: `app/services/` — 12 clases sobre `app/services/application_service.rb`.

```ruby
class << self
  def call(...) = new(...).call
end
```
<sub>`app/services/application_service.rb:55` — `(...)` es *argument forwarding*, de Ruby 2.7 en adelante (Ruby 3.0 sumó poder anteponerle argumentos: `def call(x, ...)`): reenvía posicionales, keywords y bloque sin enumerarlos</sub>

**Java**: `@Service` + `@Transactional`, o el `Command` del CQRS.
**Diferencia**: acá `call` es una convención, no una interfaz. Y `ApplicationService`
además centraliza la traducción excepción → `Result`:

```ruby
def transactional
  ApplicationRecord.transaction { yield }
rescue BusinessRuleViolation => e
  e.result
rescue ActiveRecord::RecordInvalid => e
  Result.failure(:validation_failed, ...)
rescue ActiveRecord::StaleObjectError
  Result.failure(:conflict, "El registro fue modificado por otra operación. Reintentá.")
rescue ActiveRecord::RecordNotUnique => e
  Result.failure(:duplicate, ...)
rescue ActiveRecord::LockWaitTimeout
  Result.failure(:locked, ...)
end
```
<sub>`app/services/application_service.rb:68` — este método **es** la definición de "qué es error de negocio y qué es bug" en esta app</sub>

### 7.2 Query Object

**Qué es**: una consulta compleja encapsulada en una clase que devuelve un
`ActiveRecord::Relation`.
**Dónde**: `app/queries/` — 6 clases.

```ruby
def apply_if(relation, value)
  value.present? ? yield(relation, value) : relation
end
```
<sub>`app/queries/application_query.rb:35` — evita el `relation = relation.where(...) if x.present?` repetido ocho veces</sub>

**La regla que lo hace valer la pena**: devolver `Relation`, no `Array`. Por eso
el controller puede componer *policy scope* + query object + paginación:

```ruby
scope = policy_scope(Product)
products = Products::Search.call(term: params[:q], ..., scope:)
pagy, records = paginate(products)
```
<sub>`app/controllers/api/v1/products_controller.rb:11`</sub>

Si `Search#call` hiciera `.to_a`, perderías la paginación en base y traerías la
tabla entera a memoria.

**Excepciones deliberadas**: `Availability` devuelve un Hash, `Reconciliation` un
Array de Hashes y `Valuation` un Hash de `Money`. Son **agregaciones**: ya no
queda nada que encadenar, y devolver una Relation con `group` obligaría al
llamador a saber cómo desarmarla.

**Java**: `@Repository` con `@Query`, o Criteria API / QueryDSL.
**Diferencia**: la Relation de ActiveRecord es perezosa y **componible después de
salir del método**, cosa que un `List<Product>` de Spring Data no es. Acercarte
con `Specification<T>` es posible pero mucho más verboso.

### 7.3 Form Object

**Qué es**: un objeto que valida una entrada que no mapea 1:1 con un modelo.
**Dónde**: `app/forms/` — `StockTransferForm`, `PurchaseOrderForm`.

Acepta **claves naturales** (SKU, código de depósito, CUIT del proveedor), que es
lo que un cliente de integración tiene a mano, no ids internos:

```ruby
class StockTransferForm < ApplicationForm
  attribute :source_warehouse_code, :string
  attribute :destination_warehouse_code, :string
  attr_accessor :lines, :requested_by

  validates :source_warehouse_code, :destination_warehouse_code, presence: true
  validate :warehouses_exist
  validate :warehouses_differ
  validate :lines_are_valid
```
<sub>`app/forms/stock_transfer_form.rb:6`</sub>

Y trae un detalle que separa a un form escrito con cuidado de uno escrito rápido:
el N+1 **dentro de la validación**, que nadie mira nunca.

```ruby
def products_by_sku
  @products_by_sku ||= begin
    skus = normalized_lines.filter_map { |l| l[:sku]&.to_s&.upcase }
    Product.kept.where(sku: skus).index_by(&:sku)
  end
end
```
<sub>`app/forms/stock_transfer_form.rb:32`</sub>

**Java**: `@Valid` sobre un RequestDTO con Bean Validation, más un mapper.
**Diferencia**: el form de Rails **también ejecuta** (`persist!`), y funciona con
`form_with` sin tener tabla, por duck typing (`ActiveModel::Model`). En Java el
DTO no persiste nada.

### 7.4 Policy (Strategy)

**Qué es**: una clase por recurso, un método por acción, que responde sí o no.
**Dónde**: `app/policies/` — 9 clases + `ApplicationPolicy`.

```ruby
def index?   = viewer?
def show?    = viewer?
def create?  = operator?
def update?  = operator?
def destroy? = manager?

private

def viewer?   = user&.active? && user.at_least?("viewer")
def operator? = user&.active? && user.at_least?("operator")
```
<sub>`app/policies/application_policy.rb:29`</sub>

El `&.` es deliberado: sin usuario, `nil` → falsy → denegado. **Fallar cerrado**
es la única postura defendible en autorización.

La clase interna `Scope` es la otra mitad — autorizar el `show` no sirve de nada
si el `index` lista todo:

```ruby
class Scope
  def resolve = scope.none   # por defecto NO se ve nada
end
```
<sub>`app/policies/application_policy.rb:47`</sub>

**El matiz de diseño más interesante del repo** está en
`app/policies/purchase_order_policy.rb:3-21`: la policy mira **sólo el rol**, y el
**estado** lo valida el controller o el service.

```ruby
class PurchaseOrderPolicy < ApplicationPolicy
  def create?  = operator?
  def submit?  = manager?      # <- NO lleva `&& record.draft?`
  def receive? = operator?
```

Porque son dos preguntas distintas con dos respuestas HTTP distintas:

- ¿tenés **derecho**? → `403 Forbidden`
- ¿el recurso está en un **estado** que lo permita? → `422 Unprocessable`

Si mezclás las dos, mandar dos veces la misma orden devuelve 403, y un 403 le
dice al cliente "nunca vas a poder" cuando la verdad es "ya está enviada". El
chequeo de estado vive donde corresponde:

```ruby
unless order.can_transition_to?("submitted")
  return render_error(:invalid_transition,
                      "Una orden en estado '#{order.status}' no se puede enviar.",
                      status: :unprocessable_content)
end
```
<sub>`app/controllers/api/v1/purchase_orders_controller.rb:39`</sub>

**Java**: `@PreAuthorize("hasRole('MANAGER')")` o un `AccessDecisionVoter`.
**Diferencia a favor de Pundit**: es un objeto normal, se testea sin levantar un
request (`spec/policies/policies_spec.rb`), y `verify_authorized` en un
`after_action` te avisa si te olvidaste de autorizar una acción
(`app/controllers/api/v1/base_controller.rb:117`). En Spring, olvidarte la
anotación no produce ningún error: el endpoint queda abierto y silencioso.

**Ese `after_action` estuvo sólo en la API**, y ahí quedaba un agujero real: un
controller HTML nuevo sin `authorize` no disparaba ninguna alarma. Ya está
corregido: el mismo callback vive ahora también en la UI web
(`after_action :verify_pundit_usage` en
`app/controllers/application_controller.rb`), con los controllers de `sessions`
y `passwords` excluidos porque son públicos por definición. Y las acciones que legítimamente no autorizan nada lo declaran
**explícito** en vez de quedar en gris: `skip_policy_scope` en
`DashboardController#index` y `skip_policy_scope` + `skip_authorization` en
`StockItemsController#low_stock`. Declararlo es mejor que saltear el callback:
queda escrito que la decisión se tomó.

### 7.5 Serializer

**Qué es**: un PORO que traduce un objeto de dominio a un Hash listo para JSON.
**Dónde**: `app/serializers/` — 6 + `ErrorSerializer`.

**Por qué existe** (respuesta corta y suficiente): `render json: product` serializa
**todas** las columnas. El día que agregás `supplier_secret_price`, se filtra sola
por la API pública. Es una fuga de datos por omisión.

Detalle que vale contar en una entrevista:

```ruby
# `lock_version` SE DEVUELVE A PROPÓSITO: el cliente lo manda de vuelta en el
# PATCH y así habilitamos optimistic locking end-to-end sobre HTTP.
lock_version: object.lock_version
```
<sub>`app/serializers/stock_item_serializer.rb:20`</sub>

**Java**: DTO + Jackson (con `@JsonIgnore`, que es *opt-out*: por omisión expone).
**Diferencia**: acá es *opt-in* explícito. Más tipeo, cero sorpresas.

### 7.6 Value Object

**Qué es**: objeto sin identidad, inmutable, comparado por valor.
**Dónde**: `app/models/value_objects/money.rb` y `quantity.rb`.

```ruby
class Money < Data.define(:cents, :currency)
  include Comparable

  def +(other) = combine(other) { |a, b| a + b }

  def *(factor)
    raise ArgumentError, "no se puede multiplicar dinero por dinero" if factor.is_a?(Money)
    with(cents: (BigDecimal(cents.to_s) * BigDecimal(factor.to_s)).round.to_i)
  end
```
<sub>`app/models/value_objects/money.rb:45`</sub>

`Data.define` (Ruby 3.2+) es **el `record` de Java 16+**: `==`, `hash`, `to_h`,
deconstrucción para pattern matching, sin setters y con todos los campos
obligatorios. Diferencia con `Struct`: `Struct` sí tiene setters.

Lo que un `Integer` pelado no puede hacer y esto sí: impedir que sumes USD con
EUR (`CurrencyMismatch`), centralizar el redondeo, y saber que CLP y JPY **no
tienen centavos** (`SUBUNITS`, `:46`). `Quantity` hace lo mismo con las unidades:
sumar 5 kg + 3 unidades levanta `UnitMismatch`.

Se conectan al modelo con una macro:

```ruby
class Product < ApplicationRecord
  include HasMoney
  has_money :cost
  has_money :price
```
<sub>`app/models/product.rb:24`</sub>

**Java**: `record Money(long cents, Currency currency)`, o el `@Embeddable` de JPA.
**Diferencia**: el `Data` de Ruby te da `with(...)` (copia con cambios) de fábrica,
y `include Comparable` te habilita `<`, `>`, `sort`, `min`, `clamp` definiendo un
solo método (`<=>`). En Java implementás `Comparable` y no te llevás los
operadores.

### 7.7 Result / Either (monádico)

**Qué es**: el error esperado es un **valor de retorno**, no una excepción.
**Dónde**: `app/lib/result.rb` (vive bajo `app/`, así que lo autocarga Zeitwerk).

La regla del proyecto:

| Tipo de falla | Ejemplo | Mecanismo |
|---|---|---|
| Esperada, de negocio | stock insuficiente, producto de baja, reserva vencida | `Result.failure` |
| Inesperada, bug o infra | la base se cayó, un `nil` imposible | Excepción, que suba y la vea el error tracker |

```ruby
def then_try
  return self if failure?
  yield(value)
end

def map
  return self if failure?
  Result.success(yield(value))
end
```
<sub>`app/lib/result.rb:66` y `:73` — `then_try` es el `flatMap` de `Either`; `map` es el `map`</sub>

**Precisión honesta**: el código de la app **no usa** `then_try` hoy; lo usa el
spec (`spec/lib/result_spec.rb:49`). Y hay una razón técnica, no un olvido: los
services encadenan **adentro de una transacción**, y ahí un `Result.failure` que
simplemente corta la cadena **no revierte nada** (la transacción anidada se une a
la de afuera). Hace falta que la excepción llegue hasta el `rescue`, y para eso
está `fail!`:

```ruby
ApplyMovement.call(...).tap { |r| fail!(r.error.code, r.error.message, **r.error.details) if r.failure? }
```
<sub>`app/services/stock/issue.rb:39`. Los otros seis que llaman a un sub-service hacen lo mismo; la mitad con una variable local en vez del `.tap`: `CommitReservation:61`, `Transfers::Dispatch:60` y `:68`, `Transfers::Receive:70`, `:79` y `:91`, `Purchasing::ReceiveOrder:57`</sub>

`then_try` sirve para componer **fuera** de una transacción: validaciones previas,
u orquestación de varios services independientes entre sí.

Otros dos detalles del `Result`:

```ruby
def initialize(ok:, value: nil, error: nil)
  @ok = ok; @value = value; @error = error
  freeze   # inmutable: nadie muta un Result después de creado
end

def deconstruct_keys(_keys) = { ok: @ok, value: @value, error: @error }
```
<sub>`app/lib/result.rb:49` y `:88`</sub>

`deconstruct_keys` habilita `case result in { ok: true, value: }` (pattern
matching de Ruby 3). Está implementado y testeado; el controller usa un `if`
porque tiene que mapear el código de error a un status HTTP igual.

**Java**: `Either<E, A>` de Vavr, o `Result` a mano. `Optional` no alcanza porque
no lleva el motivo del error.
**Diferencia**: en Java las excepciones *checked* al menos aparecen en la firma.
En Ruby **todas** son unchecked: nada te dice qué puede fallar. Por eso mover las
reglas de negocio a un valor de retorno es *más* importante en Ruby que en Java,
no menos.

### 7.8 Adapter

**Qué es**: una interfaz estable con implementaciones intercambiables.
**Dónde**: `app/services/outbox/publisher.rb` — `LogAdapter`, `NoopAdapter`,
`WebhookAdapter`, todos con `publish(message)`.

El `WebhookAdapter` es el único con lógica real, y trae dos cosas de seguridad
que conviene poder explicar:

```ruby
request["X-Stock-Timestamp"] = timestamp.to_s
# El timestamp entra en la firma para evitar REPLAY ATTACKS
request["X-Stock-Signature"] = sign("#{timestamp}.#{body}") if @secret
```
<sub>`app/services/outbox/publisher.rb:67`</sub>

**Java**: una `interface` + `@Component` por implementación, o el SPI
(`ServiceLoader`).
**Diferencia**: ya la vimos en OCP — sin classpath scanning, el registro es
explícito.

### 7.9 Null Object

**Qué es**: una implementación que cumple el contrato y no hace nada útil, para
evitar `if x.nil?` desparramado y para testear.
**Dónde**: `app/services/outbox/null_recorder.rb`.

Por qué un Null Object y no un `double`:

- **Es código real**: si el contrato cambia, este archivo falla. Un doble
  flexible seguiría diciendo que sí.
- **Sirve en producción**: un modo "sin eventos" para un import masivo de 500k
  filas, donde no querés generar 500k eventos de outbox.
- **Expresa la intención**: `Outbox::NullRecorder.new` se lee mejor que
  `double(record: nil)`.

Se lo nombra 16 veces, repartidas en 10 archivos de la suite: los cinco de
`spec/services/stock/`, más `spec/jobs/stock_jobs_spec.rb`,
`spec/queries/stock_queries_spec.rb`, `spec/integration/concurrency_spec.rb`,
`spec/requests/api/v1/endpoint_coverage_spec.rb` y
`spec/system/transfer_with_js_spec.rb` (`grep -rn NullRecorder spec/`).

**Java**: `Objects.requireNonNullElse(x, NoOpRecorder.INSTANCE)`, o el
`Collections.emptyList()` de siempre. Mismo patrón, mismo motivo.

### 7.10 Repository — y por qué en Rails casi nunca vale la pena

**Este repo NO tiene `app/repositories/`, y es una decisión.**

El argumento estándar a favor del Repository es "poder cambiar la persistencia".
En 15 años de Rails no vi a nadie cambiar Postgres por otra cosa sin reescribir
la app igual. Pero hay tres razones concretas para no ponerlo acá:

1. **Active Record ya *es* el repositorio.** `Product.find_by(sku:)`,
   `Product.kept.active`, `StockItem.lock.find(id)`. Envolver eso en
   `ProductRepository#find_by_sku` es una capa de reenvío pura.
2. **Un repositorio que devuelve colecciones mata la composición.** Si
   `ProductRepository#search(...)` devuelve `Array<Product>`, perdiste `includes`,
   paginación en base, `count` en SQL y cualquier `where` posterior. Ese es
   **exactamente** el problema que resuelve el Query Object devolviendo
   `Relation` (`app/queries/application_query.rb:20`). El Query Object es el 80%
   del Repository con el 20% del costo.
3. **El argumento de testeabilidad casi no aplica.** El "no quiero base en los
   tests unitarios" pesa mucho en JPA (levantar un contexto de Spring es caro).
   En Rails, con transacciones por ejemplo y factories, los tests con base corren
   en milisegundos, y la lógica que de verdad querés testear sin base ya está
   afuera del modelo: en los services, los value objects y el `Result`
   (`spec/lib/result_spec.rb` no toca la base).

**Cuándo sí lo pondría**: si el dominio se persiste en dos lugares (Postgres +
una API externa) y el caso de uso no debe saber en cuál está; o si estás haciendo
DDD estricto con agregados que no mapean 1:1 a tablas. Ninguno es el caso acá.

### 7.11 Decorator / Presenter

**Este repo tampoco tiene `app/presenters/`.** Lo que hay es:

- **Serializers** para la salida JSON (§7.5).
- **Helpers** para la salida HTML:

```ruby
def movement_badge(kind)
  tag.span(kind.humanize,
           class: "inline-flex rounded-full px-2 py-0.5 text-xs font-medium " \
                  "#{MOVEMENT_STYLES.fetch(kind, 'bg-slate-100 text-slate-700')}")
end

def stock_level_class(item)
  return "text-rose-600 font-semibold" if item.quantity_available <= 0
  return "text-amber-600 font-semibold" if item.below_reorder_point?

  "text-slate-900"
end
```
<sub>`app/helpers/application_helper.rb:31` y `:48`</sub>

**Cuándo pasaría a un Presenter/Decorator** (Draper, o un PORO propio): cuando
los helpers empiezan a recibir **siempre el mismo objeto** como primer argumento.
`stock_level_class(item)` es justamente el olor: un helper que siempre recibe un
`StockItem` está pidiendo ser un método de un `StockItemPresenter`. Con dos o tres
helpers así, no vale la pena; con quince, sí — porque los helpers de Rails son
**globales** (se mezclan todos en la vista) y a esa escala empiezan a chocarse los
nombres.

**Java**: `@JsonComponent` / un `ViewModel` de Spring MVC. Mismo razonamiento.

### 7.12 Concern (mixin) y sus riesgos

**Qué es**: composición por módulos. `ActiveSupport::Concern` agrega el bloque
`included do` (para correr macros de clase) y resuelve dependencias entre módulos.

Los dos del repo:

```ruby
module Discardable
  extend ActiveSupport::Concern

  included do
    scope :kept,      -> { where(discarded_at: nil) }
    scope :discarded, -> { where.not(discarded_at: nil) }
  end

  def discarded? = discarded_at.present?
```
<sub>`app/models/concerns/discardable.rb:25`</sub>

```ruby
module HasMoney
  extend ActiveSupport::Concern

  class_methods do
    def has_money(name, currency_column: :currency)
      cents_column = :"#{name}_cents"

      define_method(name) do
        ValueObjects::Money.new(cents: public_send(cents_column) || 0,
                                currency: public_send(currency_column) || "USD")
      end
```
<sub>`app/models/concerns/has_money.rb:22` — metaprogramación cotidiana en Ruby; en Java necesitarías un annotation processor o generar bytecode</sub>

**Los riesgos, que son reales:**

| Riesgo | Qué pasa | Mitigación |
|---|---|---|
| Colisión de nombres | Dos módulos definen `#status`; gana el último incluido, en silencio | Prefijos, y `Model.ancestors` para depurar |
| Un `included do` con efectos | Agrega scopes, callbacks y validaciones que **no se ven** en el modelo | Que el concern haga **una** cosa |
| El "cajón de sastre" | Partir un modelo de 2000 líneas en 5 concerns de 400 sigue siendo un modelo de 2000 líneas, ahora más difícil de leer | Extraer a **otra clase** (service, query, value object), no a otro módulo del mismo objeto |
| Acoplamiento invisible | El concern asume columnas (`discarded_at`) que el modelo puede no tener | Documentarlo, y que falle ruidosamente |
| Dependencias circulares | A incluye B que incluye A | `ActiveSupport::Concern` las detecta y avisa |

**La prueba para saber si un concern está bien**: ¿el módulo se puede describir sin
nombrar el modelo que lo incluye? `Discardable` sí ("cualquier cosa con
`discarded_at`"). `ProductStuff` no.

**Java**: `interface` con métodos `default`, o herencia. Diferencias que importan:
Ruby no tiene herencia múltiple pero **sí** módulos, y `include` los inserta en la
cadena de ancestros — o sea que sí podés hacer `super` desde un módulo hacia la
clase, cosa que un `default method` de Java no permite. Y un módulo puede
**agregar métodos de clase** (`class_methods do`), que una interfaz de Java no.

Una colisión de nombres real, aunque no viene de un concern sino de un `enum`, y
que ilustra el mismo riesgo:

```ruby
# `committed!` YA EXISTE en ActiveRecord (lo usa el manejo de transacciones).
# Solución: prefijo. => `status_held?`, `status_committed!`
enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status
```
<sub>`app/models/stock_reservation.rb:22`</sub>

### 7.13 Transactional Outbox

**Qué es**: la solución al *dual write*. No podés escribir en Postgres y publicar
en el broker atómicamente; entonces escribís el evento **en la misma transacción**
y un relay lo publica después.

**Dónde**: `Outbox::Recorder` (escribe) → tabla `outbox_events` →
`Outbox::PublishPendingJob` (relay) → `Outbox::Publisher` (adapter).

```ruby
def self.claim_batch(limit: 500)
  pending
    .where(attempts: ...MAX_ATTEMPTS)
    .order(:id)
    .limit(limit)
    .lock("FOR UPDATE SKIP LOCKED")
end
```
<sub>`app/models/outbox_event.rb:27` — `SKIP LOCKED` es LA primitiva de colas en SQL: N workers hacen la misma query y cada uno se lleva un lote distinto, sin coordinación externa</sub>

Y el detalle del `Recorder` que la mayoría no conoce:

```ruby
ActiveRecord.after_all_transactions_commit do
  next unless Rails.cache.write("outbox/publish_scheduled", 1,
                                expires_in: 2.seconds, unless_exist: true)
  Outbox::PublishPendingJob.perform_later
```
<sub>`app/services/outbox/recorder.rb:47`</sub>

`after_all_transactions_commit` (Rails 7.2+) espera a la transacción **más
externa**. Un `after_commit` de modelo dentro de una transacción anidada se
dispara antes, y encolarías un job para datos que todavía pueden hacer rollback.
El SETNX del cache **debouncea**: 500 eventos de un lote encolan **un** job, no 500.

**Java**: Debezium / CDC, o el `@TransactionalEventListener(phase = AFTER_COMMIT)`
de Spring. Diferencia: `@TransactionalEventListener` publica **en memoria** después
del commit — si el proceso muere entre el commit y el publish, el evento se pierde
sin dejar rastro. El outbox lo tiene **durable en la tabla**: at-least-once de
verdad. (Y por eso el consumidor debe deduplicar por `event_id`: *exactly-once
delivery* no existe.)

### 7.14 Máquina de estados explícita

**Qué es**: los estados y las transiciones válidas, como datos.

```ruby
STATUSES = %w[draft in_transit received cancelled].freeze

TRANSITIONS = {
  "draft"      => %w[in_transit cancelled],
  "in_transit" => %w[received cancelled],
  "received"   => [],
  "cancelled"  => []
}.freeze

def can_transition_to?(new_status) = TRANSITIONS.fetch(status, []).include?(new_status.to_s)
```
<sub>`app/models/stock_transfer.rb:20` y `:35`; lo mismo en `purchase_order.rb:16` y `:27` con 5 estados</sub>

**Por qué a mano y no con `aasm` / `state_machines`**: para 4 estados y 4
transiciones (y 5 estados con 7 transiciones en `PurchaseOrder`), la gema es más
peso conceptual que ayuda —DSL propio, callbacks implícitos, otra cosa que
aprender para leer el modelo—. Lo que importa es que las transiciones sean
**explícitas y testeadas**, y eso lo tenés con un hash congelado.

**Cuándo cambiaría de opinión**: cuando necesites callbacks por transición,
guardas condicionales, o un historial de transiciones auditables. Ahí la gema paga.

Detalle de diseño que ya vimos: `can_transition_to?` **no** se llama desde la
policy (§7.4). El guard lo invoca el controller o el service, y devuelve 422.

**Java**: Spring State Machine, o un `enum` con métodos abstractos por constante
(que es más elegante que esto, hay que decirlo). Diferencia: el `enum` de Java te
da exhaustividad en el `switch`; acá `TRANSITIONS.fetch(status, [])` con default
te cubre el caso de un estado desconocido sin explotar.

### 7.15 Resumen

| Patrón | Dónde | Equivalente Java | Cuándo NO |
|---|---|---|---|
| Service Object (Command) | `app/services/` (12) | `@Service` + `@Transactional` | Cuando es un método de 3 líneas sin transacción |
| Query Object | `app/queries/` (6) | `@Repository` + `@Query` | Un filtro simple: usá un scope |
| Form Object | `app/forms/` (2) | `@Valid` RequestDTO | La entrada mapea 1:1 al modelo |
| Policy (Strategy) | `app/policies/` (9) | `@PreAuthorize` | Nunca: la autorización siempre merece su clase |
| Serializer | `app/serializers/` (6) | DTO + Jackson | Nunca en una API pública |
| Value Object | `value_objects/money.rb`, `quantity.rb` | `record` / `@Embeddable` | Un `Integer` sin invariantes ni unidad |
| Result / Either | `app/lib/result.rb` | `Either` de Vavr | Fallas inesperadas: ahí va excepción |
| Adapter | `outbox/publisher.rb` | `interface` + SPI | Hay una sola implementación y no va a haber otra |
| Null Object | `outbox/null_recorder.rb` | `NoOp` singleton | La interfaz tiene 10 métodos (arreglá eso primero) |
| Repository | **no está** | `@Repository` | Casi siempre en Rails: AR ya lo es (§7.10) |
| Decorator / Presenter | **no está** (helpers) | `ViewModel` | Menos de ~10 métodos de presentación por modelo |
| Concern (mixin) | `models/concerns/` (2) | `interface` con `default` | Para partir un God Model: extraé a otra clase |
| Transactional Outbox | `outbox/` + `outbox_events` | Debezium / CDC | No hay consumidores externos todavía |
| Máquina de estados | `TRANSITIONS` en 2 modelos | Spring State Machine | Más de ~6 estados con callbacks: usá gema |

---

## 8. Cuándo NO aplicar el patrón

El over-engineering en Rails tiene una forma muy reconocible: un service object
de tres líneas que sólo reenvía a un método del modelo.

```ruby
# ❌ Esto no aporta nada. Suma un archivo, un test, una indirección y un
#    `require` mental, para no hacer nada que el modelo no haga solo.
class Products::Deactivate < ApplicationService
  def initialize(product:) = @product = product
  def call = Result.success(@product.update!(active: false))
end
```

```ruby
# ✅ El modelo, y listo.
product.update!(active: false)
```

**El criterio operativo que uso**, y que se corresponde con lo que hay en el repo:

| Necesitás… | Entonces |
|---|---|
| Una transacción que abarque más de un `save` | Service object |
| Bloquear filas, o tomarlas en un orden determinado | Service object |
| Emitir un evento de dominio | Service object |
| Coordinar dos o más modelos | Service object |
| Devolver un error de negocio con código, para que el controller lo mapee a HTTP | Service object |
| Nada de lo anterior | Método del modelo, o directo en el controller |

Y acá están los lugares del repo donde **deliberadamente no** se aplicó un patrón:

- **`StockItem#valuation`** (`stock_item.rb:69`) es `product.cost * on_hand`. No
  hay service de valuación de un ítem: es una lectura derivada.
- **`Product#margin` y `#margin_ratio`** (`product.rb:75`) son aritmética pura
  sobre `Money`. No merecen una clase.
- **`StockMovement.discrepancies`** (`stock_movement.rb:64`) es
  `def self.discrepancies(...) = StockItems::Reconciliation.call(...)`: un atajo
  de una línea hacia el query object, para que quien busque en el modelo lo
  encuentre. La lógica está en el query object; el modelo sólo pone el nombre.
- **Los scopes se quedan en el modelo.** `Product.kept.active`,
  `StockItem.needing_reorder`, `StockReservation.expired_now`. Un query object
  para `where(active: true)` sería ridículo. El corte está en "seis filtros
  opcionales + joins + agregación" (`Products::Search`), no en un `where`.
- **No hay `PurchaseOrderRepository`** (§7.10) ni `ProductPresenter` (§7.11).
- **No hay una gema de máquina de estados** para 4 estados (§7.14).

El costo real de un patrón de más no es el archivo: es que la próxima persona
tiene que **abrir tres archivos** para entender qué pasa cuando apretás un botón.
Esa es la métrica.

---

## 9. Código limpio en Ruby

Ruby tiene convenciones que no existen en Java y que un revisor espera ver.

### 9.1 Nombres

| Convención | Significa | Ejemplo real |
|---|---|---|
| `snake_case` para métodos y variables | — | `quantity_on_hand` |
| `CamelCase` para clases, `SCREAMING` para constantes | — | `StockItem`, `MAX_ATTEMPTS` |
| `?` al final | devuelve un booleano | `#discarded?`, `#below_reorder_point?`, `#terminal?` |
| `!` al final | **la versión peligrosa de un par**, no "muta" | `#save!` vs `#save`, `Result#value!` |
| `_` prefijo | argumento que no se usa | `def deconstruct_keys(_keys)` |
| `@` | variable de instancia | `@stock_item_id` |

El `!` es el que más se malinterpreta viniendo de otros lenguajes. **No significa
"muta el objeto"**: significa "hay un par de métodos y este es el que sorprende"
—normalmente porque levanta excepción en vez de devolver `false` o `nil`—.
`Array#flatten!` muta *y* devuelve `nil` si no hubo cambios. `Result#value!`
(`app/lib/result.rb:81`) es el caso puro en este repo: **no muta nada** (el
`Result` está congelado), y el `!` está sólo porque levanta `Result::Failure` en
vez de devolverte el error como valor. Y `StockItem.find_or_provision!` (`:158`)
sí escribe, pero el `!` está por el `create!` / `find_by!` que pueden explotar, no
por la escritura.

Nombres que se leen bien en este repo: `find_or_provision!`,
`atomically_decrement`, `lock_items_in_order`, `replayed_movement`,
`can_transition_to?`. Cada uno dice qué hace y qué esperar.

### 9.2 Métodos cortos y *endless methods*

Ruby 3 permite `def x = expresión` para métodos de una línea. El repo lo usa mucho
y hace que un modelo se lea como una tabla:

```ruby
def available = quantity_available.to_i
def can_fulfil?(amount) = available >= amount.to_i
def below_reorder_point? = available <= reorder_point
def out_of_stock? = available <= 0
def valuation = product.cost * on_hand
```
<sub>`app/models/stock_item.rb:58`</sub>

Cuándo **no** usarlo: si el cuerpo no entra cómodo en una línea, o si hay efectos
laterales. `def call = new(...).call` está bien; un `def call = transactional { ... }`
de 40 caracteres, no.

### 9.3 Guard clauses

Salir temprano, en vez de anidar. Es la regla de estilo más rentable de todas.

```ruby
def call
  return Result.failure(:invalid_quantity, "El conteo no puede ser negativo") if @counted_quantity.negative?
  return Result.failure(:reason_required, "Un ajuste de inventario requiere un motivo") if @reason.blank?

  transactional do
    ...
```
<sub>`app/services/stock/adjust.rb:30`</sub>

```ruby
def apply_term(relation)
  return relation if @term.blank?
  ...
```
<sub>`app/queries/products/search.rb:56`</sub>

En Ruby además tenés el modificador `if`/`unless` al final de la línea, que hace
que el guard se lea como una frase. La contra: usado con condiciones largas se
vuelve ilegible. Regla práctica: si la línea pasa de ~100 caracteres, volvé al
`if` de bloque.

### 9.4 Tell, don't ask

Pedile al objeto que haga algo, en vez de sacarle los datos y decidir vos.

```ruby
# ❌ ask
if item.quantity_on_hand - item.quantity_reserved >= cantidad

# ✅ tell
if item.can_fulfil?(cantidad)
```
<sub>`app/models/stock_item.rb:64`</sub>

Lo mismo con `#terminal?` (`stock_reservation.rb:43`), que encapsula
`committed? || released? || expired?` y evita que cada llamador arme la condición.
Y con `Money#+`, que valida la moneda **adentro**: quien suma no tiene que
acordarse de chequearla.

### 9.5 Ley de Demeter y `delegate`

"Hablá con tus amigos, no con los amigos de tus amigos." El síntoma es el tren de
puntos: `reservation.stock_item.product.sku`.

Ruby lo resuelve con `delegate` de ActiveSupport:

```ruby
delegate :product, :warehouse, to: :stock_item
```
<sub>`app/models/stock_reservation.rb:39`</sub>

Ahora `reservation.product.sku` en vez de `reservation.stock_item.product.sku`.
Y el `to_s` del modelo lo aprovecha: `"#{quantity} x #{product.sku} (#{status})"`.

Opciones útiles: `delegate :name, to: :category, allow_nil: true` (devuelve `nil` en
vez de explotar) y `prefix: true` (genera `category_name`).

**Cuidado con dos cosas:**

- `delegate` es azúcar sintáctica, **no** elimina el acoplamiento ni la query. Si
  `stock_item` no está precargado, `reservation.product` sigue disparando dos
  queries. Demeter es de diseño; el N+1 es de performance. Son problemas distintos.
- Delegar 15 métodos es una señal de que ese objeto quería ser otra cosa.

El equivalente Java es escribir el método a mano (`public String getSku() { return
stockItem.getProduct().getSku(); }`) o Lombok `@Delegate`. Acá es una línea
declarativa.

### 9.6 Evitar el `nil`

`nil` es el `null` de Ruby y produce el mismo `NoMethodError: undefined method
'foo' for nil` que en Java produce el NPE. Las herramientas:

| Herramienta | Para qué | Ejemplo real |
|---|---|---|
| Null Object | eliminar el `if nil?` de raíz | `Outbox::NullRecorder` |
| `&.` (safe navigation) | encadenar sin explotar | `user&.active? && user.at_least?("viewer")` (`application_policy.rb:42`) |
| `fetch` en vez de `[]` | fallar ruidosamente ante clave desconocida | `ADAPTERS.fetch(name) { raise ... }` (`publisher.rb:27`) |
| `fetch` con default | valor por omisión explícito | `TRANSITIONS.fetch(status, [])` |
| `.compact` | sacar los `nil` de un Hash o Array antes de serializar | `app/serializers/product_serializer.rb:26` |
| `.presence` | `""` y `"   "` se vuelven `nil` | `@idempotency_key = idempotency_key.presence` (`apply_movement.rb:54`) |
| `Integer(x)` en vez de `.to_i` | entrada inválida explota en vez de dar `0` | `app/controllers/api/v1/stock_operations_controller.rb:94` |

Ese último merece énfasis porque es un bug de datos silencioso:
`"abc".to_i` devuelve `0`, y `"10 unidades".to_i` devuelve `10` — que es peor,
porque parece que funcionó. `Integer("abc")` levanta `ArgumentError`.

Diferencia con Java: **no hay `Optional` idiomático** ni `@NonNull`. En Ruby el
`nil` se combate con diseño (Null Object, defaults) y con fallar temprano, no con
tipos.

### 9.7 `freeze` e inmutabilidad

```ruby
# frozen_string_literal: true
```

Es la primera línea de casi todo el código del repo: **178 de los 194 archivos
`.rb`**. Los 16 que no lo tienen son los que genera Rails y nadie retoca: 12 de
`config/` (`application.rb`, `boot.rb`, `puma.rb`, los `environments/`…) y los
cuatro `db/*schema.rb`. Las migraciones **sí** lo tienen, y en `app/` y `lib/`
**no queda ninguno sin el comentario**.

**Esa inconsistencia estuvo viva en este repo y se corrigió.** Cuando se verificó
esta documentación faltaba en 23 de 188 archivos, y seis de esos estaban en
`app/`: `sessions_controller.rb`, `passwords_controller.rb`, el concern
`authentication.rb` —que corre en **cada** request de la UI—, los dos mailers y
`application_cable/connection.rb`. O sea: no era sólo boilerplate de arranque,
era código de la aplicación. Así se detecta y así se verifica que quedó limpio:

```bash
for f in $(find app lib -name '*.rb'); do
  head -1 "$f" | grep -q frozen_string_literal || echo "$f"
done
# => sin salida
```

Importa justamente por lo que decía el conteo: el comentario es **por archivo**,
así que que lo tuviera el 88% no protegía al 12% restante. Los 16 que quedan son
archivos de configuración y schemas generados, donde no hay literales calientes
en un camino de request.

Qué hace: congela los literales de string de ese archivo. Menos objetos, menos GC,
y **una mutación accidental explota** en vez de corromper algo lejano. En Ruby 3.3
todavía no es el default, así que el comentario mágico sigue haciendo falta.

Los 20 usos de `.freeze` en `app/` son casi todos constantes de configuración
(`ADAPTERS`, `TRANSITIONS`, `SORTS`, `STATUS_FOR`, `SUBUNITS`, `UNITS`,
`ROLE_RANK`, `KINDS`, `MOVEMENT_STYLES`, `DEFAULT_PRELOAD`…) y están congeladas
por la misma razón por la que en Java usarías
`Map.of(...)` / `List.copyOf(...)`: en un servidor **multi-thread** como Puma, una
constante mutable es estado compartido sin lock.

Ojo con el matiz: `freeze` es **superficial**. `ARRAY.freeze` congela el array, no
los elementos. Para tablas de configuración anidadas, congelá también los valores
(o usá `Data`/`Struct` inmutables, como `Result::Error` y `Money`).

Y el ejemplo del repo donde la inmutabilidad es del objeto entero:

```ruby
def initialize(ok:, value: nil, error: nil)
  ...
  freeze   # nadie muta un Result después de creado
end
```
<sub>`app/lib/result.rb:53`; hay un test que lo verifica: `spec/lib/result_spec.rb:25`</sub>

### 9.8 Qué mide realmente RuboCop

El repo usa el preset oficial de Rails 8:

```yaml
# .rubocop.yml
inherit_gem: { rubocop-rails-omakase: rubocop.yml }
```

Corrí el análisis y lo desarmé:

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
bundle exec rubocop
# => 194 files inspected, no offenses detected
```

```text
cops totales: 803
cops habilitados: 45
```

Y el desglose por departamento:

| Departamento | Cops disponibles | Habilitados |
|---|---|---|
| `Style` | 300 | 12 |
| `Layout` | 100 | 27 |
| `Lint` | 159 | 4 |
| `Metrics` | 10 | **0** |
| `Rails` | 138 | **0** |
| `Naming` | 19 | **0** |
| `Performance` | 52 | 1 |

**Los 10 cops de `Metrics` están apagados.** Todos: `AbcSize` (max 17),
`MethodLength` (max 10), `ClassLength` (max 100), `CyclomaticComplexity` (max 7),
`PerceivedComplexity` (max 8), `ParameterLists` (max 5)…

O sea: **RuboCop con el preset omakase no mide complejidad, mide formato.** Un
método de 300 líneas con complejidad ciclomática 40 pasa limpio. Los 12 cops de
`Style` habilitados son cosas como `StringLiterals` (comillas dobles),
`HashSyntax` y `TrailingCommaInHashLiteral`.

Esto es una decisión de DHH, y tiene su lógica: las métricas automáticas de
complejidad generan discusiones improductivas y `# rubocop:disable` por todos
lados; el juicio sobre si un método es demasiado largo es de la persona que
revisa. Pero tenés que **saberlo**, porque:

> "RuboCop está verde" **no** quiere decir "el código está bien diseñado".
> Quiere decir "el formato es consistente".

Comparación honesta con Java:

| Herramienta | Java | Acá | Qué mide |
|---|---|---|---|
| Formato / estilo | Checkstyle, Spotless | **RuboCop** (45 cops) | Comillas, comas, indentación |
| Bugs y patrones peligrosos | SpotBugs, Error Prone | **Brakeman** (`bin/brakeman --no-pager`: 79 checks, 0 warnings) | SQLi, XSS, mass assignment, redirect abierto, `ValidationRegex` (el `^`/`$` que en Ruby son fin de **línea**, no de string — ver `app/models/product.rb:32-47`) |
| Complejidad / deuda | PMD, SonarQube | **nada activado** | — |
| Vulnerabilidades en dependencias | OWASP dependency-check | **bundler-audit** | CVEs del `Gemfile.lock` |
| Cobertura | JaCoCo | **SimpleCov** (line + branch) | — |
| N+1 | ninguna estándar | **Bullet** (rompe los ejemplos marcados `:n_plus_one`) — ver el asterisco de abajo | — |

**El asterisco de Bullet, que es la lección más cara de esta tabla.** Esa red
figuraba en la tabla, pero **estuvo colgada y sin atar durante todo el
proyecto**: la gema estaba sólo en `group :development` del Gemfile, así que en
test la constante `Bullet` no existía, los guards `if defined?(Bullet)` de
`spec/support/bullet.rb` daban `false`, y los ejemplos marcados `:n_plus_one`
pasaban en verde **hubiera o no un N+1**. Un chequeo verde que no verifica nada
es peor que no tener chequeo, porque te da confianza y te saca las ganas de
mirar.

Así quedó arreglado:

- La gema pasó a `group :development, :test` (`Gemfile`).
- La configuración (`Bullet.enable`, `Bullet.raise`) se movió de
  `spec/support/bullet.rb` a un `config.after_initialize` de
  `config/environments/test.rb`, porque `Bullet.enable = true` **aplica los
  parches sobre ActiveRecord en el momento de la asignación**: desde un
  `before(:suite)` de RSpec llega tarde para algunos ganchos y la detección
  queda muda.
- `spec/support/bullet.rb` se quedó sólo con el ciclo
  `start_request`/`end_request` y con el helper `detectando_n_plus_one`, que
  envuelve **nada más que la consulta a auditar** (si creás los registros dentro
  del request de Bullet quedan marcados como "imposibles" y no reporta nada).
- `spec/n_plus_one_guard_spec.rb` testea **la herramienta**, no el código: un
  control positivo que arma un N+1 a propósito y exige que Bullet lo levante.
  Es la regla general — cuando una herramienta de test puede desactivarse en
  silencio, escribí un test que verifique que está activa.
- El detector de eager loading **innecesario** (`unused_eager_loading`) quedó
  opt-in con `BULLET_UNUSED=1`, porque da falsos positivos cuando un camino
  precarga para el caso feliz y corta antes por una validación. El de N+1 sigue
  siempre activo: sus hallazgos son bugs reales.

Y apenas la red empezó a atajar aparecieron N+1 de verdad. Uno de ellos explica
el método privado `serialize` de `Api::V1::PurchaseOrdersController`: el
serializer recorre las líneas tocando `line.product`, y la precarga se hace con
`ActiveRecord::Associations::Preloader` **en el momento de serializar** en vez de
buscar con `includes`, porque los caminos de error (422, 403) cortan antes de
serializar y ahí el eager loading se pagaría sin usarse.

Si quisieras las métricas, activarías `Metrics` en `.rubocop.yml` con umbrales
propios, o sumarías `rubocop-rspec` (que está en el `Gemfile` pero **no** está
requerido en `.rubocop.yml`: el reporte muestra 0 cops de RSpec cargados).

---

## Errores que ves en producción

| # | Síntoma | Causa real | Arreglo |
|---|---|---|---|
| 1 | Una transferencia falló a mitad y quedaron líneas commiteadas | Alguien llamó a un sub-service y **no** cortó con `fail!`. La transacción anidada se **une** a la externa: que el hijo devuelva `Result.failure` no revierte nada | Todo llamado a un sub-service termina en un `fail!` si el hijo devolvió failure, sea con `.tap` (`app/services/stock/issue.rb:39`) o con variable local (`transfers/dispatch.rb:60`) |
| 2 | Se escribió stock sin pasar por `ApplyMovement` y `SUM(movements) != quantity_on_hand` | Alguien hizo `item.update!(quantity_on_hand: n)` desde un script o la consola | `StockItems::Reconciliation` lo detecta; lo corre `Stock::ReconcileBalancesJob`. Si devuelve una sola fila, hay un bug |
| 3 | Un `Result.failure` de un service viaja al cliente como 500 | El código de error no está en `STATUS_FOR` y cae en el default | Agregá la fila en `app/controllers/concerns/api/error_handling.rb:47`. El default es 422, así que el síntoma más común es "422 donde debería ser 404 o 409" |
| 4 | `NameError: uninitialized constant Outbox::NullRecorder` en desarrollo, pero en producción anda | La clase estaba anidada en otro archivo. Zeitwerk carga por demanda; `eager_load` en producción la salvaba | Un archivo por constante (`app/services/outbox/null_recorder.rb:18`). `zeitwerk:check` **no** lo detecta |
| 5 | Un "auto-registro por herencia" (`self.inherited`) encuentra 0 clases | Mismo mecanismo: sin `eager_load!`, las subclases no existen todavía. Lo medí: 0 sin, 12 con | Registro explícito, como `Publisher::ADAPTERS` |
| 6 | Enviar dos veces la misma orden devuelve **403** y el usuario no entiende nada | El estado se chequeó dentro de la policy (`manager? && record.draft?`) | Policy = rol (403). Estado = service/controller (422 `invalid_transition`). Ver `app/policies/purchase_order_policy.rb:3-21` |
| 7 | Un endpoint nuevo quedó abierto para cualquiera durante meses | Se olvidaron el `authorize` | `verify_authorized` / `verify_policy_scoped` en un `after_action` (`base_controller.rb:117`). En dev explota; en producción loguea `security.authorization_missing` |
| 8 | `AbstractController::ActionNotFound` en endpoints que antes andaban | Un callback con `only: %i[index]` en la clase base, heredado por controllers sin `index`. Cambió en Rails 7.1 | Un callback que decide adentro (`verify_pundit_usage`) |
| 9 | Un test da verde y en producción falta un parámetro | Un `double(record: nil)` acepta cualquier firma | Null Object real (`Outbox::NullRecorder`) o `instance_double` / `class_double`, que son verificados |
| 10 | Un listado de 200 productos tarda segundos | N+1 de **agregación**; `includes` no lo arregla | Precalcular con `StockItems::Availability` y **pasárselo** al serializer (`product_serializer.rb:23`) |
| 11 | `Money` de USD sumado con EUR y el total no cierra | Alguien operó con `cents` crudo en vez del value object | La aritmética vive en `Money`: `assert_same_currency!` levanta `CurrencyMismatch` (`money.rb:109`) |
| 12 | `quantity_available` "no se actualiza" en el objeto en memoria | Es una **columna generada** de Postgres: se lee, no se escribe. Y Rails **no** la marca readonly (`StockItem.readonly_attributes` devuelve `[]`): si le asignás un valor, `save!` devuelve `true` sin excepción y el UPDATE omite la columna — falla en silencio | `reload` después de escribir (`apply_movement.rb:139`). El comentario de `stock_item.rb:30-38` lo explica |
| 13 | Un `"10 unidades"` entró como cantidad `10` y nadie se enteró | `.to_i` parsea el prefijo y descarta el resto | `Integer(...)` con `rescue ArgumentError, TypeError` (`stock_operations_controller.rb:94`) |
| 14 | Se agregó un keyword a `record(...)` y explotó recién en producción | La "interfaz" no está declarada en ningún lado; nadie compila | Null Object real + un spec compartido de contrato para todos los implementadores |
| 15 | RuboCop verde y un método de 200 líneas con complejidad 40 | El preset omakase tiene los **10 cops de `Metrics` apagados** | Saberlo. Activá `Metrics` con umbrales propios si lo querés, y no confundas "lint verde" con "diseño correcto" |
| 16 | Un adapter nuevo del outbox rompe el boot en staging | El valor del registro era una instancia, no una lambda: `ENV.fetch` se evaluó al cargar la clase | Lambdas en `ADAPTERS` (`publisher.rb:17`), evaluación perezosa |

---

## Cómo responder esto en una entrevista

**"¿Cómo aplicás SOLID en Rails, si el framework te empuja a modelos gordos?"**

> Con capas que Rails no te da y hay que crear: `services/` para casos de uso,
> `queries/` para lecturas complejas, `forms/` para entradas que no mapean 1:1,
> `policies/` para autorización y `serializers/` para la salida. En esta app son
> 12 services, 6 queries, 2 forms, 9 policies y 6 serializers. El modelo se queda
> con lecturas derivadas, validaciones de forma, scopes y primitivas de
> persistencia. Mi regla para decidir: **si el método necesita una transacción, es
> un caso de uso, no del modelo**.
>
> **Trade-off**: más archivos y más indirección. Para un CRUD chico es
> over-engineering: ahí un `update!` en el controller está bien. El corte lo pongo
> cuando aparece una transacción, un lock, un evento o más de un modelo.

**"¿Por qué service objects y no lógica en el modelo, como dice Rails?"**

> Porque `ActiveRecord::Base` **ya tiene** persistencia, validaciones, callbacks y
> serialización adentro: el modelo arranca con cuatro responsabilidades. Es la
> diferencia con JPA, donde la entidad es anémica porque la persistencia vive en el
> `EntityManager`. Al ser Active Record y no Data Mapper, la disciplina la tengo
> que poner yo.
>
> El ejemplo concreto: `Stock::ApplyMovement` es el único lugar del sistema que
> mueve stock físico y escribe el ledger (las reservas, que sólo comprometen,
> tocan `quantity_reserved` aparte). Cuando pidieron "prohibir movimientos sobre
> productos dados de baja", fue **una línea en un archivo** y los 7 services que
> dependen de él la heredaron sin tocarse. Si la lógica estuviera en el modelo y los
> controllers, hubiera sido buscar en 40 archivos.

**"Vos venís de Spring. ¿Cómo hacés inyección de dependencias sin container?"**

> Con keyword arguments con valor por defecto. Los services reciben
> `event_recorder: Outbox::Recorder.new` y `clock: Time`; en los tests entra un
> `Outbox::NullRecorder` y un `class_double(Time, current: momento)`. No hace falta
> container porque en Ruby los objetos son valores: `new` es barato, no hay que
> resolver por tipo, no hay proxies que crear y el default es código normal.
>
> **Lo que pierdo, y lo tengo presente**: no hay verificación del grafo al bootear
> (Spring te falla en el arranque, acá te enterás en la primera llamada), no hay
> scopes —`Outbox::Recorder.new` se instancia **en cada llamada**, que acá da igual
> porque no tiene estado, pero si tuviera un pool sería un bug silencioso—, no hay
> AOP declarativo, y el wiring está desparramado en 11 constructores en vez de en
> un `ApplicationConfig`.

**"¿Por qué `Result` y no excepciones?"**

> Porque en Ruby **todas** las excepciones son unchecked: nada en la firma te dice
> qué puede fallar, y un `rescue` sin tipo se come todo. Entonces separo: falla
> esperada de negocio —stock insuficiente, reserva vencida— es un `Result.failure`,
> que es un valor; falla inesperada —la base se cayó, un `nil` imposible— es
> excepción, que suba y la vea el error tracker.
>
> Eso me da una interfaz uniforme: los 12 services y los 2 forms devuelven
> `Result`, y el controller tiene **un solo** traductor a HTTP con un mapa de
> código de error a status. Es LSP en la práctica.
>
> **Trade-off**: es más verboso —hay que chequear el `Result` en cada llamada— y en
> un flujo transaccional no alcanza con `then_try`, porque cortar la cadena no
> revierte la transacción: hay que levantar una excepción interna para que el
> rollback ocurra. Eso está resuelto en `ApplicationService#fail!`.

**"¿Usarías el patrón Repository en Rails?"**

> Casi nunca, y puedo defenderlo. Active Record **ya es** el repositorio:
> `Product.find_by(sku:)`, scopes, relations. Envolverlo es una capa de reenvío. Y
> hay un costo concreto: un repositorio que devuelve `Array` te mata `includes`,
> la paginación en base y cualquier composición posterior. Por eso uso **Query
> Objects que devuelven `ActiveRecord::Relation`**: te dan el 80% del Repository al
> 20% del costo, y el controller puede seguir componiendo policy scope + búsqueda
> + paginación sobre el mismo objeto.
>
> Lo pondría si el mismo agregado se persistiera en dos backends distintos y el
> caso de uso no tuviera que saber en cuál. No es el caso de esta app.

**"¿Qué pasa si un service nuevo devuelve otra cosa? ¿Quién lo impide?"**

> Nadie, y esa es la respuesta honesta: en Ruby no hay compilador. Lo que tengo es
> una clase base cuyo `call` levanta `NotImplementedError`, tests por cada service
> que verifican el contrato, y dobles **verificados** (`instance_double`,
> `class_double`) que fallan si la firma real no coincide. Para el `Recorder`, en
> vez de un mock uso un Null Object que es **código real**: si mañana agrego un
> keyword a `record`, ese archivo falla ruidosamente; un `double(record: nil)`
> seguiría diciendo que sí a todo y me daría verde en falso.
>
> Y aclaro algo que se malinterpreta seguido: **RuboCop no me cubre esto**. Con el
> preset omakase de Rails, de 803 cops hay 45 habilitados y los 10 de `Metrics`
> están apagados. RuboCop mide formato, no diseño ni complejidad. Para lo demás
> están Brakeman, bundler-audit, Bullet y los tests.

---

## Para seguir

- `docs/01-arquitectura.md` — el flujo completo de una request, el patrón
  proyección + ledger y cómo agregar una operación nueva paso a paso.
- `docs/03-base-de-datos-y-activerecord.md` — locks, columnas generadas,
  índices parciales y las trampas de Active Record.
- Los comentarios de `app/services/application_service.rb`, `app/lib/result.rb`,
  `app/queries/application_query.rb` y `app/policies/application_policy.rb`: son
  la fuente de verdad de todo lo de acá.
