# Testing: todos los tipos de test, con ejemplos reales

Vas a encontrar acá el mapa completo de la suite de este repo: qué es RSpec y en
qué se diferencia de Minitest (y de JUnit), la anatomía exacta de un spec, los
**trece tipos de test** que conviven en `spec/` con el archivo real de cada uno,
FactoryBot contra fixtures y contra los Object Mothers de Java, dobles de test y
cuándo **no** mockear, cómo se comporta la base de datos adentro de un test,
tiempo congelado, HTTP externo, cobertura, tests flakey, velocidad, un ciclo
red-green-refactor sobre una regla de stock de verdad, y qué corre el CI.

Todos los números de este documento salieron de correr la suite en esta máquina
(Ruby 3.3.6, Rails 8.1.3.1, PostgreSQL 16.13, rspec-rails 8.0.4 sobre rspec-core
3.13.6): **338 ejemplos, 0 fallas, ~16 s**. Cada ruta que se cita existe; si algo
no está implementado en el repo lo digo explícitamente en vez de inventarlo.

Está escrito para vos, que venís de JUnit 5 + Mockito + AssertJ + Testcontainers.
Cada sección marca dónde la analogía con Java **se rompe**, porque ahí es donde
la gente pierde el tiempo.

---

## 0. Mapa: dónde vive cada cosa

| Qué | Archivo | Qué mirar |
|---|---|---|
| Config sin Rails | `spec/spec_helper.rb` | SimpleCov, `verify_partial_doubles`, orden aleatorio |
| Config con Rails | `spec/rails_helper.rb` | transactional fixtures, includes, `Current.reset` |
| Flags por defecto | `.rspec` | `--require spec_helper`, `--format documentation` |
| Factories | `spec/factories/{users,catalog,stock}.rb` | traits, secuencias, `after(:build)` |
| Unitario puro | `spec/lib/result_spec.rb` | monada `Result`, pattern matching |
| Value Object | `spec/models/value_objects/money_spec.rb` | semántica de valor, inmutabilidad |
| Modelo | `spec/models/product_spec.rb` | shoulda-matchers + CHECK constraints |
| Servicio (el corazón) | `spec/services/stock/receive_spec.rb` | DI del recorder y del reloj |
| Query object | `spec/queries/stock_queries_spec.rb:34` | contar queries para probar el "1 en vez de N" |
| Policy (matriz) | `spec/policies/policies_spec.rb:22` | rol × acción generado en un loop |
| Serializer | `spec/serializers/serializers_spec.rb` | contrato del JSON |
| Form object | `spec/forms/stock_transfer_form_spec.rb` | validación del input |
| Request (HTTP real) | `spec/requests/api/v1/stock_operations_spec.rb` | 401/403/404/422, idempotencia |
| Smoke de rutas | `spec/requests/api/v1/endpoint_coverage_spec.rb:99` | recorre TODAS las rutas de la API buscando 5xx |
| Rate limiting | `spec/requests/api/v1/rate_limiting_spec.rb` | las dos capas |
| Job | `spec/jobs/outbox_publish_pending_job_spec.rb` | `have_enqueued_job`, poison message |
| Sistema (browser) | `spec/system/transfer_with_js_spec.rb` | Capybara + Chromium headless |
| Concurrencia | `spec/integration/concurrency_spec.rb` | threads y conexiones reales |
| N+1 | `spec/support/bullet.rb:20` | `Bullet.raise = true` |
| Helper de threads | `spec/support/concurrency.rb:25` | `run_concurrently` |
| Driver del browser | `spec/support/capybara.rb:104` | `rack_test` vs `cuprite` |
| HTTP externo bloqueado | `spec/support/webmock.rb:25` | `disable_net_connect!(allow_localhost: true)` |
| Cassettes de VCR | `spec/support/vcr.rb:28` | `hook_into :webmock`, filtrado de secretos |
| CI | `.github/workflows/ci.yml:92` | job `test` con servicios Postgres/Redis |

---

## 1. RSpec vs Minitest

Rails trae **Minitest** de fábrica. Este proyecto usa **RSpec** (`rspec-rails ~> 8.0`
en el `Gemfile`). No es una cuestión de gusto: son dos filosofías.

| | Minitest | RSpec |
|---|---|---|
| Viene con Rails | ✅ | ❌ (una gema más) |
| Tamaño (medido en las gemas instaladas) | ~5.000 líneas | ~29.000: rspec-core 14.300 + rspec-expectations 8.000 + rspec-mocks 7.000 |
| Sintaxis | `assert_equal a, b` / `test "..." do` | `expect(a).to eq(b)` / `it "..." do` |
| Estructura | clases y métodos Ruby comunes | DSL anidable (`describe` / `context`) |
| Setup perezoso | no (asignás en `setup`) | `let` memorizado y perezoso |
| Dobles | `Minitest::Mock`, o mocha | `rspec-mocks` con verifying doubles |
| Matchers de Rails | `assert_response`, `assert_difference` | `have_http_status`, `change`, `contain_exactly` |
| Orden por defecto | aleatorio | aleatorio (`spec_helper.rb:52`) |
| Velocidad de boot | más rápido | ~0,2-0,3 s extra por proceso |

**Por qué RSpec acá, concretamente:**

1. **`let` perezoso.** En `spec/services/stock/receive_spec.rb:14-21` hay cuatro
   `let` (`user`, `product`, `warehouse`, `recorder`) y cada ejemplo materializa
   sólo los que toca. En Minitest lo escribís en `setup` y se crea todo siempre,
   o armás métodos memorizados a mano. Con 57 ejemplos de servicio eso se nota.
2. **Metadata.** `:concurrency`, `:n_plus_one`, `js: true` no son comentarios:
   son *tags* que disparan hooks globales (desactivar transacciones, prender
   Bullet, cambiar de driver de browser). Minitest no tiene un equivalente
   declarativo tan directo.
3. **shoulda-matchers.** `it { is_expected.to validate_presence_of(:sku) }`
   funciona en los dos, pero el `subject` implícito de RSpec lo hace una línea.
4. **Los mensajes de `describe`/`context` son documentación ejecutable.** Con
   `--format documentation` (está en `.rspec`) la salida de la suite es
   literalmente la especificación del dominio en castellano.

**Cuándo elegiría Minitest:** una gema o un servicio chico, un equipo que ya
tiene alergia a los DSL, o cuando el tiempo de boot importa muchísimo (CLI,
Lambdas). Para una app de dominio con reglas de negocio densas como ésta, RSpec
gana.

> **Analogía Java y dónde se rompe.** Minitest ≈ JUnit 5 pelado; RSpec ≈ JUnit +
> AssertJ + Mockito + un DSL de BDD tipo Spock. La diferencia que sorprende: en
> Java elegís el *runner* y las librerías por separado y todas conviven; en Ruby
> RSpec **reemplaza** el framework entero, incluido el runner (`rspec`, no `rake
> test`). No podés tener specs de RSpec y tests de Minitest corriendo en el mismo
> comando sin cirugía. Y `rspec-mocks` es parte del paquete, no un Mockito
> aparte.

---

## 2. Anatomía de un spec

### 2.1 `describe`, `context`, `it`

```ruby
RSpec.describe Stock::Receive do        # sujeto del spec (una clase, o un string)
  describe "camino feliz" do            # agrupa por comportamiento
    context "cuando el depósito está inactivo" do   # agrupa por condición
      it "devuelve un failure" do       # UN ejemplo = UNA aserción de sentido
        # ...
      end
    end
  end
end
```

`describe` y `context` son **el mismo método**. La convención es: `describe` para
"qué cosa", `context` para "bajo qué condición" (y arrancá el `context` con
"cuando" / "si"). En JUnit 5 el equivalente es `@Nested` + `@DisplayName`, sólo
que acá anidar no cuesta una clase interna.

`RSpec.describe Stock::Receive` (con la constante, no el string) habilita
`described_class`, que es lo que usan casi todos los specs de este repo:

```ruby
# spec/models/api_token_spec.rb
subject(:token) { described_class.issue!(user:, name: "integración", scopes: %w[stock:read]) }
```

Ventaja real: si renombrás la clase, no tenés que tocar 40 líneas del spec.

### 2.2 `subject`

```ruby
# spec/models/product_spec.rb:7 — subject IMPLÍCITO
subject { build(:product) }
it { is_expected.to validate_presence_of(:sku) }   # is_expected == expect(subject)
```

```ruby
# spec/services/stock/transfers/transfer_flow_spec.rb — subject NOMBRADO
subject(:despachar) do
  Stock::Transfers::Dispatch.call(transfer:, user:, event_recorder: recorder)
end
```

Regla que uso: **`subject` implícito sólo para one-liners con matchers**
(`it { is_expected.to ... }`). Para cualquier otra cosa, `subject(:nombre)` o
directamente un `let`. Un `subject` anónimo referenciado como `subject` a mitad
de un ejemplo largo es ilegible.

### 2.3 `let` vs `let!`

```ruby
let(:product)  { create(:product) }      # PEREZOSO: se ejecuta la primera vez que lo nombrás
let!(:item)    { create(:stock_item) }   # EAGER: equivale a `before { item }`
```

`let` es **memorizado por ejemplo**: dentro de un mismo `it` lo llamás cinco
veces y se evalúa una sola; en el ejemplo siguiente se evalúa de nuevo desde cero.

La trampa está documentada en el propio repo, en `spec/serializers/serializers_spec.rb`:

```ruby
it "serializa colecciones" do
  product          # `let` es PEREZOSO: sin esta línea el primero no existe
  create(:product) # y el test contaría 1 en vez de 2. Trampa clásica de RSpec.
  expect(described_class.collection(Product.all).size).to eq(2)
end
```

Y en `spec/services/stock/reservations_spec.rb`:

```ruby
it "el disponible no se mueve durante el commit (ya se descontó al reservar)" do
  reservation   # forzamos la creación de la reserva (let es perezoso)
  ...
end
```

Cuándo va cada uno:

- **`let`** por defecto. Si el ejemplo no lo usa, no paga el `INSERT`.
- **`let!`** cuando el objeto tiene que existir *antes* de la acción para que la
  acción lo encuentre: `let!(:item)` en los specs de `Stock::Issue`, los tres
  productos de `spec/queries/products_search_spec.rb`, los items de
  `StockItems::LowStock`.

> **Java.** No hay equivalente directo. `@BeforeEach` es siempre eager. Lo más
> parecido a `let` es un campo con inicialización perezosa a mano, o `Supplier<T>`
> memorizado. Y ojo con una diferencia grande: JUnit crea **una instancia nueva
> de la clase de test por método** (`PER_METHOD` es el default), así que los
> campos ya vienen limpios. RSpec también instancia un `ExampleGroup` nuevo por
> ejemplo, así que la garantía es la misma — pero **el estado global no se
> resetea solo** (ver §9.3).

### 2.4 `before` / `after` / `around`

```ruby
before { sign_in_as(user) }                       # spec/system/stock_operations_spec.rb:11

before do                                         # spec/rails_helper.rb:75
  Current.reset
  Rails.cache.clear
end

around do |example|                               # spec/requests/api/v1/rate_limiting_spec.rb:70
  Rack::Attack.enabled = true
  example.run
  Rack::Attack.enabled = false
end
```

`before(:each)` (el default) corre por ejemplo; `before(:suite)` una vez por
proceso (SimpleCov, Bullet, el lint de factories). **`before(:context)` /
`before(:all)` no aparece en esta suite a propósito**: los objetos que creás ahí
viven fuera de la transacción del ejemplo y no se revierten, así que ensucian los
tests siguientes y generan fallas dependientes del orden.

`around` es el único que puede *envolver* al ejemplo. Se usa cuando hay que
restaurar estado global sí o sí (el `Rack::Attack.enabled` de arriba) o cambiar
cómo corre el ejemplo — que es exactamente lo que hace `spec/support/concurrency.rb:54`:

```ruby
config.around(:each, :concurrency) do |example|
  self.use_transactional_tests = false
  example.run
  # TRUNCATE ... RESTART IDENTITY CASCADE
end
```

> **Java.** `before` ≈ `@BeforeEach`, `before(:suite)` ≈ `@BeforeAll` (pero de
> toda la corrida, no de la clase), `around` ≈ una `TestRule` / `Extension` de
> JUnit 5. La diferencia: `around` es una lambda inline de tres líneas, no una
> clase que implementa una interfaz.

### 2.5 `shared_examples` y `shared_context`

**En este repo no se usan** — lo digo derecho porque es fácil escribir un
documento con ejemplos que no existen. Vale la pena que los conozcas igual,
porque en una entrevista salen.

```ruby
# Definición (típicamente en spec/support/shared_examples/*.rb)
RSpec.shared_examples "un service que devuelve Result" do
  it { expect(subject).to be_a(Result) }
  it "no lanza excepciones por reglas de negocio" do
    expect { subject }.not_to raise_error
  end
end

# Uso
RSpec.describe Stock::Receive do
  subject { described_class.call(product:, warehouse:, quantity: 1, user:) }
  it_behaves_like "un service que devuelve Result"   # crea un grupo anidado
  include_examples "un service que devuelve Result"  # inyecta en ESTE grupo
end
```

```ruby
RSpec.shared_context "con un token de manager" do
  let(:user)    { create(:user, :manager) }
  let(:headers) { { "Authorization" => "Bearer #{ApiToken.issue!(user:, name: "s", scopes: ApiToken::SCOPES).plaintext }" } }
end

RSpec.describe "API", type: :request do
  include_context "con un token de manager"
end
```

Diferencia entre `it_behaves_like` e `include_examples`: el primero crea un grupo
anidado (los `let` que definas adentro no pisan los de afuera), el segundo mete
todo en el grupo actual y **puede colisionar**. Usá `it_behaves_like`.

En esta suite el rol de "shared examples" lo cumplen dos cosas más simples:

1. **Un loop de Ruby común** para la matriz de policies (`spec/policies/policies_spec.rb:30`):
   genera 20 ejemplos con nombre propio sin ningún DSL adicional.
2. **Helpers en `spec/support/`** (`ApiHelpers`, `AuthHelpers`,
   `ConcurrencyHelpers`) incluidos por tipo de spec en `spec/rails_helper.rb:54-58`.

Mi opinión: los shared examples son la forma más rápida de hacer una suite
ilegible. Cuando falla `un service que devuelve Result` no sabés en qué archivo
está el `it`. Usalos sólo para contratos genuinamente polimórficos (todas las
implementaciones de una interfaz), no para ahorrar tipeo.

> **Java.** `shared_examples` ≈ una clase abstracta de test que heredan las
> implementaciones, o `@TestFactory` / `@ParameterizedTest`. `shared_context` ≈
> una `@Nested` con `@BeforeEach` común, o una `Extension`.

### 2.6 Metadata y tags

Esto es lo que en Java sería `@Tag` + un `Extension` que reacciona a ese tag,
pero acá es un hash arbitrario:

| Tag | Dónde se declara | Qué dispara |
|---|---|---|
| `:concurrency` | `spec/integration/concurrency_spec.rb:20` | `spec/support/concurrency.rb:54-64`: incluye `ConcurrencyHelpers`, apaga transactional tests, hace `TRUNCATE` al final |
| `:n_plus_one` | `spec/queries/products_search_spec.rb:64` | `spec/rails_helper.rb:63-70`: `Bullet.start_request` / `end_request` |
| `js: true` | `spec/system/transfer_with_js_spec.rb:20` | `spec/support/capybara.rb:108`: cambia el driver a `cuprite` |
| `type: :request` | inferido por carpeta | `infer_spec_type_from_file_location!` (`rails_helper.rb:48`) |
| `:focus` / `fit` | ad hoc | `filter_run_when_matching :focus` (`spec_helper.rb:42`) corre sólo eso |

```bash
bundle exec rspec --tag concurrency          # sólo los de threads
bundle exec rspec --tag ~concurrency         # todo MENOS esos (~ = negación)
bundle exec rspec --tag type:request
bundle exec rspec spec/models/product_spec.rb:120   # un ejemplo por número de línea
bundle exec rspec --only-failures            # sólo lo que falló la vez pasada
bundle exec rspec --seed 12345               # reproducir un orden exacto
```

`--only-failures` funciona porque `spec_helper.rb:43` define
`example_status_persistence_file_path = "tmp/rspec_examples.txt"`. Sin eso, RSpec
no tiene dónde guardar qué falló. Es el equivalente de `mvn -Dsurefire.rerunFailingTestsCount`,
pero sin re-correr todo primero.

El `infer_spec_type_from_file_location!` es importante y silencioso: es lo que
hace que un archivo en `spec/requests/` tenga `get`/`post`, uno en `spec/system/`
tenga `visit`/`click_button`, y uno en `spec/jobs/` tenga `have_enqueued_job`. Si
ponés un request spec en `spec/services/` no anda y el error es críptico
(`undefined method 'post'`).

---

## 3. La pirámide, el trofeo, y qué proporción tiene sentido en Rails

La pirámide clásica (muchos unitarios, pocos de integración, poquísimos E2E) fue
pensada para un mundo donde levantar la base costaba minutos. En Rails la base de
test está a 1 ms y el framework entero bootea en 1,9 s, así que el punto óptimo
se corre hacia el medio: es el **trofeo de tests** de Kent C. Dodds (poco
estático, algo unitario, **mucho de integración**, poco E2E).

Lo que la suite tiene de verdad, medido con `rspec --dry-run` por carpeta:

| Carpeta | Ejemplos | % | Tiempo | Qué cubre |
|---|---:|---:|---:|---|
| `spec/models` | 92 | 27 % | ~1,2 s | validaciones, scopes, constraints, Value Objects |
| `spec/services` | 57 | 17 % | ~3,5 s | **reglas de negocio** |
| `spec/requests` | 52 | 15 % | ~4,8 s | contrato HTTP, auth, idempotencia, rate limit |
| `spec/policies` | 33 | 10 % | 0,57 s | matriz de autorización |
| `spec/queries` | 28 | 8 % | ~1,3 s | query objects, N+1, keyset pagination |
| `spec/lib` | 18 | 5 % | 0,13 s | `Result` (unitario puro) |
| `spec/jobs` | 18 | 5 % | ~0,7 s | outbox, jobs de mantenimiento |
| `spec/serializers` | 11 | 3 % | ~0,4 s | contrato del JSON |
| `spec/system` | 11 | 3 % | ~4,6 s | browser real |
| `spec/forms` | 10 | 3 % | ~0,5 s | validación de input |
| `spec/integration` | 8 | 2 % | ~2,0 s | concurrencia con threads |
| **Total** | **338** | | **16,1 s** | |

(Los tiempos por carpeta se midieron corriendo cada una por separado, así que
suman algo más que la corrida completa; los porcentajes redondean a 98 %.)

Leelo así: **el 3 % de los ejemplos (los 11 de sistema) se lleva casi el 30 % del
tiempo**. Eso no es un problema — es el precio correcto por cubrir Turbo +
Stimulus + Chromium. Lo que sí sería un problema es tener 60 system tests
probando reglas de negocio que un spec de servicio cubre 20 veces más rápido.

La regla operativa en este repo:

- Una **regla de negocio nueva** se prueba en `spec/services/`. Punto.
- El **contrato HTTP** de esa regla (status code, forma del error) se prueba una
  vez en `spec/requests/`, sin repetir los casos de negocio.
- El **flujo del usuario** se prueba en `spec/system/` sólo si depende del browser.
- Todo lo que se pueda probar sin base de datos (`Result`, `Money`, `Quantity`,
  las policies con `build_stubbed`) se prueba sin base de datos.

> **Java.** Es la misma discusión de "unit tests con Mockito vs `@SpringBootTest`
> con Testcontainers", pero con una diferencia decisiva: **el contexto de Rails se
> bootea una sola vez y no hay `@DirtiesContext`**. En Spring, un
> `@SpringBootTest` mal escrito invalida el cache del ApplicationContext y te
> agrega 20 s por clase; en Rails ese costo no existe, así que la excusa
> tradicional para mockear el repositorio (evitar levantar el contexto) se cae.
> Acá los specs de servicio pegan contra Postgres de verdad y tardan 60 ms.

---

## 4. Los tipos de test, uno por uno

### 4.1 Unitario puro (sin base de datos)

`spec/lib/result_spec.rb` — 18 ejemplos, ~0,1 s de ejecución.

```ruby
describe "#then_try (composición monádica)" do
  it "CORTA la cadena en el primer fallo y no ejecuta lo siguiente" do
    ejecutado = false

    final = described_class.success(1)
                           .then_try { described_class.failure(:boom, "explotó") }
                           .then_try { ejecutado = true; described_class.success(99) }

    expect(final).to be_failure
    expect(ejecutado).to be(false)   # <- esto es lo importante del patrón
  end
end
```

Fijate qué prueba: no que `then_try` devuelva algo, sino que **el bloque
siguiente no se ejecuta**. Eso es lo que hace que el patrón sirva.

Y los Value Objects (`spec/models/value_objects/money_spec.rb`):

```ruby
it "compara por VALOR, no por identidad (semántica de Value Object)" do
  a = described_class.new(cents: 100, currency: "USD")
  b = described_class.new(cents: 100, currency: "USD")

  expect(a).to eq(b)
  expect(a.hash).to eq(b.hash)   # -> sirve como clave de Hash y en un Set
  expect(a).not_to equal(b)      # -> son objetos distintos
end
```

Los tres matchers son distintos y confunden a todo el mundo:

| Matcher | Método Ruby | Java |
|---|---|---|
| `eq(x)` | `==` | `equals()` |
| `eql(x)` | `eql?` (igualdad estricta de tipo: `1.eql?(1.0)` es `false`) | `equals()` sin coerción |
| `equal(x)` / `be(x)` | `equal?` (misma referencia) | `==` |

En Java `assertEquals(a, b)` usa `equals()` y `assertSame(a, b)` la referencia.
En Ruby es al revés de lo que la intuición dice: **`equal` es identidad**.

**Detalle honesto**: estos specs requieren `rails_helper`, no `spec_helper`,
porque las clases viven bajo `app/` y las autocarga Zeitwerk. Está comentado en
`spec/lib/result_spec.rb:3-7`. Correrlos solos igual bootea Rails (~1,7 s de
carga), pero la *ejecución* es de 0,13 s para los 18 ejemplos de `spec/lib` y de
0,12 s para los 19 de `spec/models/value_objects`. Si quisieras el boot de 50 ms,
tendrías que mover `Result` a `lib/` y requerirlo a mano.

### 4.2 De modelo, con shoulda-matchers

`spec/models/product_spec.rb`, `stock_item_spec.rb`, `user_spec.rb`,
`api_token_spec.rb`, `sequence_counter_spec.rb` — 92 ejemplos.

```ruby
subject { build(:product) }

it { is_expected.to validate_presence_of(:sku) }
it { is_expected.to validate_length_of(:name).is_at_most(200) }
it { is_expected.to validate_inclusion_of(:unit).in_array(described_class::UNITS) }
it { is_expected.to validate_uniqueness_of(:sku).case_insensitive }
it { is_expected.to belong_to(:category).optional }
it { is_expected.to have_many(:suppliers).through(:product_suppliers) }
```

Configurado en `spec/support/shoulda.rb`. **Advertencia real**:
`validate_uniqueness_of` **hace un INSERT** para probar la unicidad (necesita una
fila existente contra la cual chocar). Es de los pocos matchers que tocan la base
y por eso el `subject` tiene que ser guardable. Está anotado en
`spec/models/product_spec.rb:15-17`.

Lo que estos specs prueban de más y que casi nadie escribe:

```ruby
# spec/models/product_spec.rb:40 — anclas del regex
it "rechaza un salto de línea con payload (anclas \\A y \\z, no ^ y $)" do
  expect(build(:product, sku: "VALIDO\n<script>alert(1)</script>")).not_to be_valid
end
```

En Ruby `^` y `$` son **principio y fin de línea**, no de string. En Java
`Pattern` sin `MULTILINE` los trata como principio y fin de la entrada, así que
esta clase de bug **no existe en Java** y es exactamente por eso que un javero
no la busca. Acá hay que usar `\A` y `\z`.

Y la red que las validaciones no atrapan:

```ruby
# spec/models/product_spec.rb:105 — el CHECK constraint frena lo que AR no
it "rechaza un costo negativo aunque saltees las validaciones" do
  product = create(:product)
  expect { product.update_column(:cost_cents, -1) }
    .to raise_error(ActiveRecord::StatementInvalid, /products_cost_check/)
end
```

`update_column` saltea validaciones **y** callbacks: va directo al `UPDATE`. Es
el camino por el que se cuela la basura en producción (imports, rake tasks,
consola). Probar que el constraint de Postgres lo frena es probar la última red.

> **Java.** `validate_presence_of` ≈ verificar `@NotNull` con un `Validator`
> programático. Pero acá se rompe la analogía: en JPA las anotaciones de
> Bean Validation se ejecutan en el `flush` por el provider, mientras que en
> ActiveRecord las validaciones corren en `save` y **se saltean con un montón de
> métodos** (`update_column`, `update_all`, `insert_all`, `save(validate: false)`,
> `touch`). No hay ningún equivalente a `@PrePersist` obligatorio. Por eso los
> CHECK constraints de la base no son opcionales en Rails.

### 4.3 De servicio: el corazón de la suite

57 ejemplos en `spec/services/`. Es donde vive la lógica de negocio y donde
conviene invertir.

```ruby
# spec/services/stock/receive_spec.rb
let(:recorder) { Outbox::NullRecorder.new }

def receive(quantity, **options)
  described_class.call(product:, warehouse:, quantity:, user:,
                       event_recorder: recorder, **options)
end

it "emite el evento de dominio con el estado resultante" do
  receive(50)

  evento = recorder.recorded.last
  expect(evento[:event_type]).to eq("stock.receipt")
  expect(evento[:payload]).to include(quantity: 50, quantity_on_hand: 50, product_sku: product.sku)
end
```

Tres cosas que hacen bueno a este spec:

1. **Inyección de dependencias sin container.** `Stock::Receive#initialize`
   (`app/services/stock/receive.rb:13-15`) recibe `event_recorder:` y `clock:`
   con valores por defecto. El spec le pasa `Outbox::NullRecorder`
   (`app/services/outbox/null_recorder.rb:28`), que acumula en memoria. Sin
   Spring, sin Guice, sin `@MockBean`: son argumentos con nombre.
2. **Prueba el efecto observable, no la implementación.** No verifica que se
   llamó a `record`; verifica *qué evento quedó*.
3. **Prueba la invariante del dominio.**

```ruby
it "mantiene la invariante ledger == proyección" do
  receive(30)
  receive(20)
  expect(StockItems::Reconciliation.call).to be_empty
end
```

Ese `Reconciliation.call` compara la proyección (`stock_items.quantity_on_hand`)
contra el `SUM` del ledger (`stock_movements`). Aparece en el spec de `Receive`,
en el de `Adjust`, en el de transferencias, en el de request de órdenes de compra
y en el de concurrencia. **Un invariante probado en cinco lugares vale más que
cincuenta assertions puntuales.**

El caso de `Stock::Issue` que separa un sistema de stock que anda de uno que no:

```ruby
# spec/services/stock/issue_spec.rb:35
it "RESPETA LO RESERVADO: no podés sacar stock comprometido con otro" do
  item.update!(quantity_reserved: 90)   # disponible = 10

  result = issue(50)   # hay 100 físicos, pero sólo 10 disponibles

  expect(result).to be_failure
  expect(result.error.code).to eq(:insufficient_available_stock)
  expect(item.reload.quantity_on_hand).to eq(100)
end
```

Y el `reload` de la última línea no es adorno: `quantity_available` es una
**columna generada de Postgres**, así que el objeto en memoria no la ve cambiar.

> **Lo que un javero asume mal, y es la trampa número uno.** En JPA hay un
> `EntityManager` con contexto de persistencia: modificás la entidad, el dirty
> checking detecta el cambio y el `UPDATE` sale en el `flush`/commit. **En
> ActiveRecord no existe nada de eso.** Cada `save!` es un `UPDATE` inmediato,
> no hay first-level cache que devuelva la misma instancia para el mismo id
> (`Product.find(1)` dos veces son **dos objetos distintos** con dos `SELECT`),
> y no hay `flush` diferido. Consecuencias directas en los tests: (a) hay que
> `reload` explícito para ver lo que escribió otro objeto —fijate cuántos
> `item.reload` hay en esta suite—; (b) el spec de optimistic locking de
> `spec/models/product_spec.rb:120` funciona justamente porque `find` dos veces
> da dos objetos y no una entidad compartida; (c) no existe el equivalente del
> `LazyInitializationException`, pero sí el N+1 silencioso, que es peor porque no
> te avisa (§4.12).

### 4.4 De query object

`spec/queries/stock_queries_spec.rb` y `products_search_spec.rb` — 28 ejemplos.

El test que justifica que el query object exista:

```ruby
# spec/queries/stock_queries_spec.rb:34
it "resuelve TODO con UNA sola query, sin importar cuántos productos" do
  queries = contar_queries { described_class.call(product_ids: [ p1.id, p2.id ]) }
  expect(queries).to eq(1)
end

def contar_queries
  count = 0
  sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
    count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:cached]
  end
  yield
  ActiveSupport::Notifications.unsubscribe(sub)
  count
end
```

`ActiveSupport::Notifications` es el bus de instrumentación de Rails: cada query
publica un evento `sql.active_record` con el SQL, el nombre y si vino de cache.
No hace falta ninguna gema. Es el equivalente conceptual de un `StatementInspector`
de Hibernate o de `datasource-proxy`, pero viene de fábrica y lo suscribís en
tres líneas.

El mismo truco se usa para verificar el **orden de bloqueo** que evita deadlocks
(`spec/services/stock/transfers/transfer_flow_spec.rb:150`):

```ruby
lock_query = queries.find { |q| q.include?("FOR UPDATE") && q.include?("stock_items") }
expect(lock_query).to match(/ORDER BY.*id/i)
```

No podés observar un lock directamente, pero **sí podés probar el mecanismo que
lo hace seguro**.

Y las pruebas de seguridad de `Products::Search`:

```ruby
# spec/queries/products_search_spec.rb:40
it "escapa los comodines de LIKE en vez de interpretarlos" do
  resultados = described_class.call(term: "%")
  expect(resultados).to be_empty   # "%" se busca literalmente, no matchea nada
end

it "acepta sólo criterios de una ALLOW-LIST" do
  expect { described_class.call(sort: "name; DROP TABLE products").to_a }.not_to raise_error
  expect(Product.count).to eq(3)
end
```

`ORDER BY` es el agujero clásico de SQL injection en cualquier ORM: los binds
protegen el `WHERE`, no el nombre de la columna del `ORDER BY`. En Java te pasa
igual con JPQL dinámico o con `Sort.by(userInput)` de Spring Data.

### 4.5 De policy: la matriz rol × acción

`spec/policies/policies_spec.rb` — 33 ejemplos en 0,56 s, **sin tocar la base**
(usa `build_stubbed`).

```ruby
matriz = {
  show?:    %i[admin manager operator viewer],
  receive?: %i[admin manager operator],
  issue?:   %i[admin manager operator],
  adjust?:  %i[admin manager],            # ajustar inventario toca la contabilidad
  reserve?: %i[admin manager operator]
}

matriz.each do |accion, roles_permitidos|
  %i[admin manager operator viewer].each do |rol|
    permitido = roles_permitidos.include?(rol)

    it "#{rol} #{permitido ? 'PUEDE' : 'NO puede'} #{accion}" do
      policy = described_class.new(send(rol), item)
      expect(policy.public_send(accion)).to eq(permitido)
    end
  end
end
```

Veinte ejemplos generados por un doble loop de Ruby común. En la salida con
`--format documentation` leés literalmente la política de acceso:
`operator NO puede adjust?`. Es mejor documentación que cualquier wiki, y falla
apenas alguien afloja un permiso.

Los tres tests que salvan de bugs reales de seguridad:

```ruby
it "un usuario INACTIVO no puede nada, aunque sea admin"
it "sin usuario (anónimo) no puede nada: deny by default"
it "nadie puede cambiarse el rol a sí mismo, ni siquiera un admin"   # escalada de privilegios
it "el Scope base devuelve NADA: si te olvidás de implementarlo, no filtra de menos"
```

> **Java.** Es lo que en Spring Security probarías con `@WithMockUser` y
> `mockMvc.perform(...).andExpect(status().isForbidden())` — o sea, **sobre HTTP**.
> Acá la política es un objeto plano y se prueba sin servidor: 33 ejemplos en
> medio segundo contra los ~8 s que costaría el mismo barrido por MockMvc. Ésa es
> la ventaja concreta de sacar la autorización del framework y ponerla en un POJO.

### 4.6 De serializer

`spec/serializers/serializers_spec.rb` — 11 ejemplos, puro Ruby.

```ruby
it "expone sólo los campos del contrato" do
  json = described_class.new(product).as_json

  expect(json.keys).to contain_exactly(
    :id, :sku, :name, :unit, :active, :discarded, :cost, :price, :created_at, :updated_at
  )
end

it "NO filtra columnas internas aunque existan en el modelo" do
  json = described_class.new(product).as_json
  expect(json).not_to have_key(:lock_version)
  expect(json).not_to have_key(:discarded_at)
end
```

`contain_exactly` sobre `keys` es un **test de contrato**: si mañana alguien
agrega una clave al serializer, el test falla y hay que decidir a conciencia si
eso es un cambio de contrato. Es lo más cerca que se llega a un schema de
OpenAPI sin generarlo.

Detalle que confunde y está anotado en el spec: `errors.to_hash(true)` devuelve
claves **símbolo**; al pasar por `render json:` se vuelven strings. Por eso en
los request specs se lee `response.parsed_body.dig("error", "code")` (string) y
acá `json.dig(:error, :code)` (símbolo).

### 4.7 De form object

`spec/forms/stock_transfer_form_spec.rb` — 10 ejemplos. Prueba la validación del
**input**, que no es la del modelo:

```ruby
it "rechaza un SKU inexistente indicando el NÚMERO DE LÍNEA" do
  result = build_form(lines: [ { sku: "P-1", quantity: 1 }, { sku: "NO-EXISTE", quantity: 1 } ]).save
  expect(result.error.message).to include("línea 2").and include("NO-EXISTE")
end

it "busca TODOS los SKUs con una sola query, no uno por línea" do
  lineas = 20.times.map { { sku: "P-1", quantity: 1 } }
  # ... cuenta queries que toquen "products"
  expect(queries).to eq(1)   # sin el memo + index_by serían 20
end
```

El `.and` encadenado (`include("línea 2").and include("NO-EXISTE")`) es un
matcher compuesto de RSpec: falla mostrando cuál de las dos partes no se cumplió.
En AssertJ sería `assertThat(msg).contains("línea 2", "NO-EXISTE")`.

### 4.8 De request: la API end-to-end sobre HTTP

52 ejemplos en `spec/requests/` (18 de operaciones de stock, 13 de órdenes de
compra, 12 de reservas, 8 de rate limiting y 1 de smoke). Ejercitan **router +
middlewares + auth + controller + service + base + serializer**, sin browser.

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

Y el que prueba que las claves de idempotencia están **scopeadas por usuario**
(si no, un cliente envenena la cache de otro).

**El ejemplo más rentable de toda la carpeta es uno solo**, en
`spec/requests/api/v1/endpoint_coverage_spec.rb:99`: recorre
`Rails.application.routes.routes`, filtra las que empiezan con `/api/v1/`, las
ejecuta todas con un token de admin y falla si alguna devuelve 5xx. No verifica
lógica —para eso están los otros specs—, verifica que ninguna ruta reviente.
Existe por un bug real: `GET /api/v1/reservations` tiraba 500 para cualquier
request porque faltaba `StockReservationPolicy`, y ningún test ejecutaba esa
acción. Se actualiza solo: si mañana agregás un endpoint, aparece en la lista sin
que nadie tenga que acordarse.

**Punto de precisión sobre el alcance**: un request spec de Rails levanta el
`ActionDispatch::Integration::Session`, que llama a la aplicación Rack **completa,
middlewares incluidos**. La prueba de que los middlewares corren de verdad está
en el spec de rate limiting: `get "/.env"` devuelve 403 porque lo corta
`Rack::Attack`, que es middleware. Lo que **no** hay es un socket TCP ni un
servidor real: es in-process.

> **Java.** MockMvc es el análogo más cercano, con dos diferencias que importan.
> (1) MockMvc por defecto **no pasa por los filtros de servlet** salvo que los
> registres explícitamente (`.addFilters(...)` o `springSecurity()`); acá los
> middlewares están siempre. (2) MockMvc suele venir acompañado de `@MockBean`
> para el repositorio; acá la base es real y la transacción del test revierte
> todo. Si querés el equivalente a `TestRestTemplate` con puerto real, eso es un
> system test (§4.10).

Regla de oro, escrita en el encabezado del propio spec: los request specs prueban
**el contrato HTTP** (status, forma del JSON, cabeceras, permisos). La lógica de
negocio va en los specs de servicio. Duplicarla acá multiplica el tiempo de la
suite por diez sin agregar cobertura.

### 4.9 De job

18 ejemplos en `spec/jobs/`. Con `type: :job` se incluye `ActiveJob::TestHelper`
(`spec/rails_helper.rb:56`), que trae `have_enqueued_job`, `perform_enqueued_jobs`
y el adapter `:test`.

```ruby
# spec/jobs/outbox_publish_pending_job_spec.rb:69
it "se re-encola solo si llenó el lote (drena rápido después de un pico)" do
  crear_eventos(3)

  expect { described_class.perform_now(batch_size: 3) }
    .to have_enqueued_job(described_class)
end

it "NO se re-encola si el lote no estaba lleno" do
  crear_eventos(1)

  expect { described_class.perform_now(batch_size: 100) }
    .not_to have_enqueued_job(described_class)
end
```

`perform_now` ejecuta el job en línea; `perform_later` sólo lo encola en el
adapter de test y `have_enqueued_job` lo verifica. Los dos ejemplos juntos
prueban la **regla de backpressure**, no la mecánica de la cola.

El test de *poison message* es el que más valor tiene en producción:

```ruby
it "un evento que falla NO frena a los demás" do
  malo = create(:outbox_event, event_type: "boom")
  crear_eventos(2)

  allow(publisher).to receive(:publish).and_call_original
  allow(publisher).to receive(:publish)
    .with(hash_including(event_type: "boom")).and_raise(StandardError, "el broker lo rechazó")

  described_class.perform_now

  expect(OutboxEvent.published.count).to eq(2)
  expect(malo.reload.attempts).to eq(1)
  expect(malo.last_error).to include("el broker lo rechazó")
end
```

Fijate el patrón: `and_call_original` primero (comportamiento real por defecto) y
después un stub **con `with(...)`** para un caso puntual. Es lo mismo que
`doCallRealMethod()` + `doThrow().when(mock).publish(argThat(...))` en Mockito,
pero sin tener que declarar el orden.

Y el de la ventana de silencio, con viaje en el tiempo
(`spec/jobs/stock_jobs_spec.rb:81`):

```ruby
it "vuelve a alertar cuando pasa la ventana de silencio" do
  described_class.perform_now

  travel_to(described_class::SILENCE_WINDOW.from_now + 1.minute) do
    expect { described_class.perform_now }.to change(OutboxEvent, :count).by(1)
  end
end
```

### 4.10 De sistema: Capybara con Chromium headless

11 ejemplos en `spec/system/`, ~4,6 s. Toda la configuración está en
`spec/support/capybara.rb`, que es el archivo más comentado de la suite porque
es donde más gente se traba.

Dos drivers, elegidos por tag:

```ruby
config.before(:each, type: :system) { driven_by :rack_test }                    # línea 104
config.before(:each, type: :system, js: true) do                                # línea 108
  driven_by :cuprite, screen_size: [ 1400, 1000 ], options: cuprite_options
end
```

| Driver | Browser | JS | Velocidad medida acá |
|---|---|---|---|
| `:rack_test` | no hay, parsea HTML | ❌ | 8 ejemplos en ~1,5 s |
| `:cuprite` | Chromium via CDP | ✅ | 3 ejemplos en ~3,2 s (~1,1 s c/u) |
| `:selenium` | Chrome via chromedriver | ✅ | no se usa (ver abajo) |

**Por qué cuprite y no selenium**: Selenium habla W3C WebDriver y necesita el
binario `chromedriver`, cuya versión **mayor** tiene que coincidir con la del
Chrome instalado. Acá hay Chromium 141.0.7390 y ChromeDriver 147.0.7727, así que
Selenium directamente no arranca — y ése es el "el CI se rompió solo" número uno
en cualquier proyecto, porque Chrome se autoactualiza y el driver queda viejo.
Cuprite habla Chrome DevTools Protocol directo y elimina el problema de raíz.

**La trampa grande de Rails 8**, documentada en `spec/support/capybara.rb:32-55`:
`driven_by :cuprite` **re-registra el driver**, pisando cualquier
`Capybara.register_driver(:cuprite)` que hayas escrito. En Rails 8,
`ActionDispatch::SystemTesting::Driver#registerable?` devuelve true para
`[:selenium, :cuprite, :rack_test, :playwright]`. El síntoma es desconcertante:

```text
Browser did not produce websocket url within 10 seconds
```

10 s es el default de Ferrum, o sea que tu `process_timeout:` nunca llegó. Y una
vez que falla el primero, **fallan todos**, porque el `Capybara.reset_sessions!`
posterior a cada ejemplo reintenta arrancar el browser. La forma correcta es
pasar todo por `options:`, que es lo que hace el repo.

Otra sutileza: `driven_by` **muta** el hash de opciones (le hace `delete(:name)`),
así que hay que pasarle una copia (`def cuprite_options = CUPRITE_OPTIONS.dup`).
Con el hash congelado tirás `FrozenError`; sin congelar, el segundo ejemplo
arranca con otra configuración.

`js_errors: true` hace fallar el test si el browser tira una excepción de
JavaScript. Sin eso, un error de JS silencioso rompe la UI en producción y
ningún test se entera.

Y el test que sí necesita JS de verdad:

```ruby
# spec/system/transfer_with_js_spec.rb:36
it "el controller de Stimulus agrega líneas al formulario" do
  visit new_stock_transfer_path

  expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 1)

  click_button "+ Agregar línea"
  # Sin sleep: `have_css` con count espera solo hasta que se cumpla.
  expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 2)
end
```

> **Java.** Es Selenium/Playwright con `@SpringBootTest(webEnvironment = RANDOM_PORT)`.
> La diferencia dolorosa: en Spring, un test así con `@Transactional` **no
> revierte**, porque el servidor corre en otro thread con otra conexión. En Rails
> pasa exactamente lo mismo (§7.2), y por eso Rails 5+ hace que los system tests
> compartan la conexión entre el thread del test y el del servidor. Lo mismo que
> ya sabés, con otro nombre.

### 4.11 De concurrencia: threads reales, conexiones separadas

8 ejemplos en `spec/integration/concurrency_spec.rb`, ~2 s. Son los tests que
separan un sistema de stock que funciona de uno que vende 14 unidades de las 10
que tiene.

```ruby
# spec/support/concurrency.rb:25
def run_concurrently(count)
  barrier = Concurrent::CyclicBarrier.new(count)
  results = Array.new(count)
  errors = Array.new(count)

  threads = Array.new(count) do |i|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        barrier.wait   # arrancan todos lo más cerca posible en el tiempo
        results[i] = yield(i)
      rescue StandardError => e
        errors[i] = e
      end
    end
  end

  threads.each(&:join)
  ActiveRecord::Base.connection_handler.clear_active_connections!
  { results:, errors: errors.compact }
end
```

Cuatro decisiones, cada una por una razón:

1. **`CyclicBarrier`** para que arranquen juntos. Sin barrera, el primer thread
   ya terminó cuando arranca el octavo y no hay contención.
2. **`with_connection`** para que cada thread tome su propia conexión del pool.
   Por eso `config/database.yml:101` pone `max_connections: 15` en test: con 5,
   el sexto thread espera y el test falla con `ConnectionTimeoutError`.
3. **`rescue` por thread.** Una excepción en un thread sin `join` se **pierde en
   silencio** en Ruby. Sin ese rescue, un test de concurrencia da verde con todo
   roto.
4. **`clear_active_connections!`** al final, o el pool se agota y el *test
   siguiente* falla por timeout de checkout. Ese sí que es un flakey difícil.

El test estrella:

```ruby
it "NUNCA deja el stock en negativo y sólo prosperan los que caben" do
  item = StockItem.create!(product:, warehouse:, quantity_on_hand: 10)

  # 8 threads intentan sacar 3 unidades cada uno = 24 pedidas sobre 10.
  resultado = run_concurrently(8) do
    Stock::Issue.call(product:, warehouse:, quantity: 3, user:,
                      event_recorder: Outbox::NullRecorder.new)
  end

  expect(resultado[:results].compact.count(&:ok?)).to eq(3)      # 3 x 3 = 9
  expect(item.reload.quantity_on_hand).to eq(1)
  expect(item.quantity_on_hand).to be >= 0                       # LA invariante
end
```

Y el de deadlocks cruzados (`spec/integration/concurrency_spec.rb:146`): dos
transferencias que tocan los mismos dos productos en orden inverso. El bloqueo
ordenado vive en `app/services/stock/transfers/dispatch.rb:99-101`
(`.where(...).order(:id).lock` → `SELECT ... FOR UPDATE ORDER BY id`). Sin ese
`order(:id)`, eso es un deadlock garantizado. Ojo con no confundirlo con
`ApplyMovement#lock_stock_item!` (`app/services/stock/apply_movement.rb:102-104`),
que bloquea **una sola fila** y por eso no necesita orden.

**Por qué esto necesita `use_transactional_tests = false`**: la transacción del
ejemplo nunca commitea, y un thread nuevo con otra conexión **no ve** datos de
una transacción ajena sin commitear. El test daría verde sin haber ejercitado un
solo lock. Ese falso verde es peor que no tener test. Por eso el tag
`:concurrency` apaga las transacciones y limpia con `TRUNCATE ... RESTART
IDENTITY CASCADE` (`spec/support/concurrency.rb:54-64`).

> **Java, y acá está el malentendido más caro.** "El GVL de Ruby me protege de
> las races" es falso. El GVL garantiza que sólo un thread ejecute bytecode de
> Ruby a la vez, pero **la extensión `pg` lo libera mientras espera a la base**:
> dos threads tienen dos conexiones y dos transacciones concurrentes de verdad.
> Todo el problema de locking existe igual que en la JVM. Lo que sí cambia es el
> paralelismo de CPU (en CRuby no lo hay), y por eso el paralelismo real son
> procesos, no threads.

### 4.12 De N+1, con Bullet haciendo fallar la suite

```ruby
# spec/queries/products_search_spec.rb:64
describe "prevención de N+1", :n_plus_one do
  it "trae la categoría con includes" do
    create_list(:product, 5, :with_category)

    # Con Bullet.raise = true, si esto generara N+1 el test ROMPE.
    described_class.call.to_a.each { |p| p.category&.name }
  end
end
```

La configuración (`spec/support/bullet.rb`):

```ruby
Bullet.enable = true
Bullet.raise = true                        # <- el N+1 rompe el test
Bullet.unused_eager_loading_enable = true  # detecta el problema INVERSO
```

Dos cosas que valen:

- **`raise = true`** es la única forma efectiva de que los N+1 no vuelvan. Un log
  de warnings lo lee nadie.
- **`unused_eager_loading`** detecta el problema opuesto: hiciste `includes` de
  algo que después no usaste. Es una query y memoria desperdiciadas.

Y una decisión que hay que defender: **Bullet se activa sólo en los ejemplos
marcados con `:n_plus_one`** (hooks en `spec/rails_helper.rb:63-70`), no
globalmente. Razón: en muchos specs unitarios el "N+1" es intencional (probás un
método que consulta), y activarlo global genera falsos positivos que la gente
termina silenciando con un `Bullet.enable = false`… y ahí perdés la herramienta.

> **Java.** El N+1 de Hibernate te avisa de otra forma: `LazyInitializationException`
> cuando la sesión ya cerró, o el `hibernate.generate_statistics` +
> `assertThat(statistics.getQueryCount())`. **En ActiveRecord no hay lazy loading
> exception**: la asociación se carga cuando la tocás, sin importar dónde estés,
> y no hay sesión que cerrar. Es más cómodo y por eso los N+1 pasan sin que nadie
> se entere. Bullet es la red que reemplaza a esa excepción.

### 4.13 De rate limiting

`spec/requests/api/v1/rate_limiting_spec.rb` — 8 ejemplos, dos capas.

```ruby
# Capa 2: ActionController#rate_limit (nativo de Rails 8, por token)
it "corta EXACTAMENTE al superar el límite de reportes (20/min)" do
  20.times do
    get "/api/v1/reports/reconciliation", headers: headers
    expect(response).to have_http_status(:ok)
  end

  get "/api/v1/reports/reconciliation", headers: headers
  expect(response).to have_http_status(:too_many_requests)
end
```

```ruby
# Capa 1: Rack::Attack (middleware, antes de Rails)
around do |example|
  Rack::Attack.enabled = true
  example.run
  Rack::Attack.enabled = false
end

it "NUNCA limita el health check (si lo limitás, el balanceador te saca de rotación)" do
  400.times { get "/up" }
  expect(response).to have_http_status(:ok)
end
```

Tres cosas de infraestructura de test que esto obligó a resolver, y que son la
causa número uno de flakiness en specs de rate limiting:

1. **`Rack::Attack` viene apagado en test** (`config/environments/test.rb:72`).
   Si lo dejás prendido, los contadores se comparten entre ejemplos y cualquier
   spec que haga muchas requests empieza a recibir 429 al azar.
2. **El cache es `:memory_store`, no `:null_store`** (`config/environments/test.rb:35`).
   El default de Rails en test es `:null_store`, y con eso `store.increment`
   devuelve `nil`, la comparación nunca supera el límite y **tus tests de rate
   limiting dan verde sin probar nada**. Es un falso verde particularmente cruel.
3. **`Rails.cache.clear` antes de cada ejemplo** (`spec/rails_helper.rb:77`) más
   el `Rack::Attack.cache.store.clear` del `before` local.

El ejemplo más valioso del archivo es un test de regresión de un bug real:

```ruby
it "los distintos rate_limit NO comparten contador (name: distinto)" do
  15.times { get "/api/v1/reports/reconciliation", headers: headers }
  # Con el bug, en la request 11 ya devolvía 429.
  expect(response).to have_http_status(:ok)
end
```

Sin `name:` en cada `rate_limit`, la clave de cache es la misma para el límite
global de `BaseController` y el de `ReportsController`: comparten contador, cada
request lo incrementa dos veces y el límite de 20 corta en 10.

---

## 5. FactoryBot

### 5.1 Factories, traits, secuencias, asociaciones

```ruby
# spec/factories/users.rb:18-35
factory :user do
  sequence(:email_address) { |n| "user#{n}@stock.test" }
  name { Faker::Name.name }
  password { "password123" }
  role { "operator" }
  active { true }

  trait(:admin)    { role { "admin" } }
  trait(:manager)  { role { "manager" } }
  trait(:operator) { role { "operator" } }
  trait(:viewer)   { role { "viewer" } }
  trait(:inactive) { active { false } }
end
```

```ruby
# spec/factories/stock.rb:4-21
factory :stock_item do
  association :product        # crea el producto asociado si no se lo pasás
  association :warehouse
  quantity_on_hand { 100 }
  quantity_reserved { 0 }
  reorder_point { 10 }
  reorder_quantity { 50 }

  trait(:empty) { quantity_on_hand { 0 } }
  trait(:low) do
    quantity_on_hand { 5 }
    reorder_point { 20 }
  end
  trait(:with_reservations) do
    quantity_on_hand { 100 }
    quantity_reserved { 40 }
  end
end
```

Puntos finos que están en el repo y que se preguntan:

- **`sequence` en vez de Faker para lo único.** Con `Faker::Internet.email` a
  secas, tarde o temprano dos emails colisionan y tenés un flakey imposible de
  reproducir. Está comentado en `spec/factories/users.rb:19-22`.
- **Todo es un bloque.** `quantity_on_hand { 100 }` y no `quantity_on_hand 100`.
  El bloque se evalúa en el momento de construir, así que `expires_at { 30.minutes.from_now }`
  se calcula por objeto, no al cargar el archivo.
- **`after(:build)` para replicar callbacks** (`spec/factories/stock.rb:30-37`):
  la factory de `stock_movement` copia `product_id`/`warehouse_id` desde el
  `stock_item`, igual que hace el callback del modelo. Sin eso, los movimientos
  creados por la factory tendrían ids de otro producto y los reportes darían
  incoherente.
- **Traits que se combinan**: `create(:user, :manager, active: false)`.

### 5.2 `build` vs `create` vs `build_stubbed`

| Método | Toca la base | Tiene id | Asociaciones |
|---|---|---|---|
| `build` | no | `nil` | las **construye** (y `create` si son `association`) |
| `create` | **sí** (`INSERT`) | real | las crea |
| `build_stubbed` | no | id falso | stubbeadas, sin queries |

Números reales, medidos en esta máquina con `bin/rails runner` (200 iteraciones
dentro de una transacción con rollback):

```text
build:          0,36 ms/objeto
build_stubbed:  0,50 ms/objeto
create:         2,83 ms/objeto        ->  create/build_stubbed = 5,6x

stock_item (con 2 asociaciones):
build_stubbed:  1,16 ms/objeto
create:         7,37 ms/objeto        ->  6,4x
```

O sea: **cada `create` que podés evitar te ahorra entre 5 y 6 veces su costo**, y
la diferencia crece con la cantidad de asociaciones. Por eso
`spec/policies/policies_spec.rb` usa `build_stubbed` para los cinco usuarios de la
matriz y corre 33 ejemplos en 0,56 s, y por eso `spec/models/product_spec.rb:57`
usa `build_stubbed` para todo lo que es aritmética de dinero.

Trampa de `build_stubbed`: el objeto **finge estar persistido** (`persisted?` es
`true`, tiene id), pero cualquier query real explota. Si el código bajo test hace
`producto.stock_items.sum(...)`, `build_stubbed` te tira
`ActiveRecord::RecordNotFound` o directamente devuelve vacío. La regla: usalo
cuando el test es sobre **el objeto en memoria**, no sobre sus relaciones en la base.

`create_list` para volumen:

```ruby
create_list(:product, 5, :with_category)   # spec/queries/products_search_spec.rb:66
create_list(:outbox_event, n)              # spec/jobs/outbox_publish_pending_job_spec.rb:10
```

### 5.3 Factories vs fixtures vs Object Mothers

| | Fixtures (YAML) | FactoryBot | Object Mother (Java) |
|---|---|---|---|
| Dónde viven los datos | archivos globales | en el test que los usa | clase estática `TestData.aProduct()` |
| Velocidad | ✅ se cargan una vez | ❌ `INSERT` por objeto | n/a |
| Legibilidad del test | ❌ hay que ir al YAML | ✅ declara lo que necesita | ✅ |
| Acople entre tests | ❌ alto (estado global) | ✅ ninguno | ✅ |
| Cambio de schema | ❌ tocás todos los YAML | ✅ tocás una factory | ✅ |
| Variaciones | duplicar filas | `trait` | métodos `withX()` (builder) |

El comentario de `spec/factories/users.rb:3-16` lo resume: **factories por
defecto, `build_stubbed` siempre que puedas**. Este repo no tiene ni un fixture:
`spec/fixtures/` existe (`rails_helper.rb:35` declara ese path, que es la
convención por defecto) pero adentro sólo está `vcr_cassettes/.keep`, el
directorio de cassettes que configura `spec/support/vcr.rb:29`. Ni un `.yml` de
fixtures.

> **Java.** FactoryBot ≈ Object Mother + Test Data Builder en una sola cosa, con
> dos ventajas que en Java hay que escribir a mano: (1) las **asociaciones se
> resuelven solas** (pedís un `stock_item` y aparecen producto y depósito); (2)
> los **traits se combinan** sin explosión combinatoria de métodos
> (`aManagerUserThatIsInactive()` vs `create(:user, :manager, :inactive)`). La
> desventaja es la misma que en Java: es facilísimo crear de más sin darte cuenta,
> y ahí se te va la suite.

### 5.4 El lint de factories, y un bug real que encontré escribiendo esto

```ruby
# spec/support/factory_bot.rb:10-15 (tal cual está hoy)
config.before(:suite) do
  if ENV["LINT_FACTORIES"]
    DatabaseCleanerStub = nil   # <- línea muerta: database_cleaner no está en el proyecto
    FactoryBot.lint(traits: true)
  end
end
```

Esa constante `DatabaseCleanerStub` no hace nada y se puede borrar; la dejo a la
vista porque el resto del documento cita el archivo y no quiero que el código
pegado difiera del real.

`FactoryBot.lint` construye **todas** las factories y verifica que produzcan
objetos válidos. Con `traits: true`, además construye cada trait por separado. El
CI lo corre en un step propio (`.github/workflows/ci.yml:152-155`).

**Corrí ese comando y falla.** Ésta es la salida real:

```bash
$ LINT_FACTORIES=1 bundle exec rspec spec/lib

FactoryBot::InvalidFactoryError:
  The following factories are invalid:

  * stock_movement+transfer_out - Quantity debe ser negativa para un movimiento de salida (transfer_out)
  * stock_movement+scrap        - Quantity debe ser negativa para un movimiento de salida (scrap)
  * stock_reservation+committed - PG::CheckViolation: viola "stock_reservations_committed_at_present"
  * stock_reservation+released  - PG::CheckViolation: viola "stock_reservations_released_at_present"
  * stock_reservation+expired   - PG::CheckViolation: viola "stock_reservations_released_at_present"
```

Lo interesante es que **esos traits no están escritos en ningún lado**. En
`spec/factories/stock.rb` la factory `stock_reservation` sólo define
`:expired_soon` y `:already_expired`. ¿De dónde salen `committed`, `released`,
`expired`?

De **`FactoryBot.automatically_define_enum_traits`**, que en factory_bot 6.6.0
(la versión del `Gemfile.lock`) viene en `true` por defecto: por cada `enum` de
ActiveRecord, FactoryBot inyecta un trait con el nombre de cada valor, en tiempo
de compilación de la factory. Lo verifiqué forzando el compile:

```ruby
FactoryBot.factories.find(:stock_reservation).tap(&:compile).defined_traits.map(&:name)
# => ["already_expired", "committed", "expired", "expired_soon", "held", "released"]
```

Y `StockReservation` declara
`enum :status, STATUSES.index_by(&:itself), validate: true, prefix: :status`
en `app/models/stock_reservation.rb:22`. El trait auto-generado pone
`status: "committed"` **y nada más**, así que viola el CHECK
`stock_reservations_committed_at_present`, que exige `committed_at` no nulo. El
CHECK está bien; el trait fantasma, no.

Las dos formas de arreglarlo, las dos verificadas corriendo:

```ruby
# Opción A: no lintear traits auto-generados
FactoryBot.automatically_define_enum_traits = false
FactoryBot.lint(traits: true)          # -> OK

# Opción B: lintear sólo las factories base
FactoryBot.lint                        # -> OK
```

Recomiendo la A: perdés el azúcar de `create(:stock_reservation, :committed)`
—que igual estaba roto— y conservás el lint de los traits que sí escribiste a
mano. Un efecto colateral menos obvio de la opción A: hoy `stock_movement` tiene
el trait `issue` **dos veces** (el escrito a mano y el del enum), y el auto-generado
podría pisar al tuyo según el orden de compilación.

---

## 6. Dobles de test

### 6.1 El zoológico

```ruby
double("cualquier cosa", foo: 1)      # doble suelto: acepta lo que le declares
instance_double(Klass, foo: 1)        # VERIFICADO contra métodos de INSTANCIA
class_double(Klass, foo: 1)           # VERIFICADO contra métodos de CLASE
object_double(objeto_real, foo: 1)    # verificado contra ESE objeto
spy                                   # doble que registra todo y responde nil
allow(x).to receive(:m)               # stub: "si te llaman, devolvé esto"
expect(x).to receive(:m)              # mock: "TE VAN A LLAMAR" (falla si no)
expect(x).to have_received(:m)        # verificación a posteriori (con spy o allow)
```

**Verifying doubles** es la línea que separa una suite confiable de una que miente:

```ruby
# spec/spec_helper.rb:38
mocks.verify_partial_doubles = true
```

Con esto activado, si stubbeás un método que **no existe** en la clase real, el
test falla. Sin esto: refactorizás un método, el doble sigue respondiendo el
nombre viejo, el test pasa en verde y producción explota. Es lo más parecido que
tenemos a que el compilador te avise.

El único doble verificado del repo, y está bien elegido:

```ruby
# spec/services/stock/receive_spec.rb:119-126
it "usa el reloj que le pasás (sin sleep, sin esperar)" do
  momento = Time.zone.local(2026, 1, 15, 10, 30)
  # Un doble VERIFICADO: si `Time` no respondiera `current`, el test fallaría.
  reloj = class_double(Time, current: momento)

  result = described_class.call(product:, warehouse:, quantity: 5, user:,
                                event_recorder: recorder, clock: reloj)

  expect(result.value.occurred_at).to be_within(1.second).of(momento)
end
```

> **Java.** Mockito verifica los tipos **en compilación** porque Java es tipado:
> `when(mock.foo())` no compila si `foo` no existe. En Ruby eso no existe, y
> `instance_double`/`class_double` recuperan aproximadamente esa garantía **en
> tiempo de test**. Es la diferencia más importante de esta sección: **si venís de
> Mockito, `double(...)` a secas es un downgrade de seguridad que no tenías**.
> Usá siempre `instance_double`. Y `verify_partial_doubles = true` es el
> equivalente de los *strict stubs* de Mockito 2+.

### 6.2 `allow` vs `expect`, y `have_received`

```ruby
allow(x).to receive(:m).and_return(1)   # permiso, no obligación
expect(x).to receive(:m)                # obligación: si no lo llaman, falla
```

`expect(...).to receive` es un **mock con expectativa previa**: mezcla el arrange
con el assert y hace que el test se lea al revés. Prefiero el patrón spy:

```ruby
allow(recorder).to receive(:record)     # arrange
subject.call                            # act
expect(recorder).to have_received(:record).with(hash_including(event_type: "stock.receipt"))  # assert
```

**En este repo `have_received` no se usa nunca**, y es a propósito: el
`Outbox::NullRecorder` es un Null Object real que **acumula** los eventos, así que
las aserciones son sobre datos, no sobre llamadas:

```ruby
evento = recorder.recorded.last
expect(evento[:event_type]).to eq("stock.receipt")
```

El comentario de `app/services/outbox/null_recorder.rb:11-16` explica el porqué:
es **código real**, así que si el contrato de `record` cambia, el archivo rompe;
un doble "flexible" seguiría respondiendo cualquier cosa.

### 6.3 Cuándo mockear y cuándo NO

La regla: **no mockees lo que no te pertenece; mockeá en los bordes.**

| Situación | ¿Mockear? | Por qué |
|---|---|---|
| ActiveRecord / Postgres | **No** | La base está a 1 ms y es lo que puede fallar de verdad |
| Otro service tuyo | **No** (salvo aislar un fallo) | Perdés la integración, que es lo valioso |
| Un HTTP externo | **Sí** | WebMock (§9.1) |
| El reloj | **Sí**, o `travel_to` | Determinismo |
| Un broker de mensajes | **Sí** | `Outbox::Publisher::NoopAdapter` |
| Una race condition imposible de provocar | **Sí**, con cuidado | Ver abajo |

Los tres lugares donde el repo **sí** mockea, y los tres están justificados:

```ruby
# 1) spec/jobs/outbox_publish_pending_job_spec.rb:8 — el borde de infraestructura
before { allow(Outbox::Publisher).to receive(:build).and_return(publisher) }

# 2) spec/services/stock/reservations_spec.rb:150 — forzar un fallo aislado
allow(Stock::ReleaseReservation).to receive(:call).and_call_original
allow(Stock::ReleaseReservation).to receive(:call)
  .with(hash_including(reservation: a)).and_return(Result.failure(:boom, "falló"))

# 3) spec/models/stock_item_spec.rb:85 — simular una carrera perdida
allow(described_class).to receive(:find_by).and_return(nil, otro)
allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
allow(described_class).to receive(:find_by!).and_return(otro)
```

El caso (3) merece una nota: es el único mock **del sujeto bajo test**, que es
normalmente un olor. Se justifica porque simula una race condition que sólo
ocurriría con un timing preciso entre dos procesos, y el objetivo es cubrir el
`rescue ActiveRecord::RecordNotUnique`. Fijate además que el mismo escenario está
cubierto **de verdad**, con threads, en `spec/integration/concurrency_spec.rb`
("no crea filas duplicadas para el mismo par producto/depósito"). Un mock para el
camino de código, un test real para el comportamiento: ésa es la combinación
correcta.

`and_return(nil, otro)` es el equivalente de
`when(x.find()).thenReturn(null).thenReturn(otro)` de Mockito: valores sucesivos
por invocación.

---

## 7. La base de datos adentro de un test

### 7.1 Transactional fixtures

```ruby
# spec/rails_helper.rb:45
config.use_transactional_fixtures = true
```

Cada ejemplo corre dentro de una transacción que se revierte al terminar. El
rollback es O(1); truncar tablas es O(filas). Con 338 ejemplos y ~6.700 queries
reales por corrida (~10.400 eventos `sql.active_record` si contás también
`SCHEMA` y `TRANSACTION`), la diferencia es de segundos.

Cómo funciona por dentro: Rails abre una transacción antes del ejemplo y hace
`ROLLBACK` después. Las transacciones que abra tu código adentro se implementan
como **savepoints** (`SAVEPOINT active_record_1`), no como transacciones nuevas
del motor. Tres consecuencias prácticas, y la primera es la que más gente tiene
al revés:

1. Los callbacks `after_commit` **sí se disparan** — es la creencia equivocada
   más repetida de esta sección. Rails abre la transacción del ejemplo con
   `joinable: false`, así que la transacción que abre tu código no se fusiona con
   ella: es una frontera de commit real (implementada como savepoint) y al
   liberarse corren `after_commit` y `ActiveRecord.after_all_transactions_commit`
   —lo verifiqué con las dos en esta suite—. Lo que **no** hay es durabilidad: el
   rollback del final borra todo igual, y otra conexión no ve nada. La creencia
   viene de Rails 4, donde efectivamente no corrían y existía la gema
   `test_after_commit`; desde Rails 5 está resuelto. Este repo usa
   `ActiveRecord.after_all_transactions_commit` en
   `app/services/outbox/recorder.rb:47`.
2. Un `raise ActiveRecord::Rollback` en una transacción anidada **no revierte la
   de afuera** — es la trampa que documenta `app/services/application_service.rb:36-44`,
   y por eso el repo usa una excepción propia (`BusinessRuleViolation`).
3. `SequenceCounter` puede probar "sin huecos ante un rollback"
   (`spec/models/sequence_counter_spec.rb`) justamente porque el savepoint anidado
   se comporta como una transacción real.

### 7.2 Por qué rompen con los system tests y con los threads

Ésta es **la** pregunta de entrevista de esta sección.

Una transacción sin commitear es visible **sólo** para su propia conexión. Si el
código bajo test corre en otro thread con otra conexión —un thread que vos
lanzaste, o el servidor Puma que Capybara levanta para el browser— ese thread
**no ve nada**.

- **System tests**: Rails resuelve esto solo desde 5.1 haciendo que el servidor
  comparta la conexión del test. Por eso `spec/system/*.rb` funciona con
  transactional fixtures prendidas. (Es el mismo problema por el que en Spring un
  `@Transactional` + `@SpringBootTest(webEnvironment = RANDOM_PORT)` no revierte:
  ahí Spring **no** lo resuelve por vos.)
- **Threads propios**: Rails no puede resolverlo, así que hay que apagarlo a
  mano. Es lo que hace `spec/support/concurrency.rb:54-64`.

### 7.3 DatabaseCleaner

**No está en este proyecto** (ni en el `Gemfile` ni en el `Gemfile.lock`); lo
menciono porque es lo que vas a ver en el 80% de los repos Rails y hay que saber
qué hace.

```ruby
# La configuración canónica, si la necesitaras
DatabaseCleaner.strategy = :transaction                     # default: rápido
DatabaseCleaner.strategy = :truncation, { except: %w[ar_internal_metadata] }  # para JS
DatabaseCleaner.clean_with(:truncation)                     # una vez, al arrancar
```

Existió porque hasta Rails 5.0 los system tests con JS necesitaban `:truncation`
sí o sí. Desde 5.1, con la conexión compartida, **la mayoría de los proyectos ya
no lo necesitan**. Este repo confirma esa hipótesis: 11 system tests, 3 de ellos
con Chromium real, funcionando con transactional fixtures y un `TRUNCATE` manual
sólo para los 8 ejemplos de concurrencia. Menos una gema.

> **Java.** El default de Spring (`@Transactional` en el test + rollback) es
> idéntico a las transactional fixtures. `DatabaseCleaner` con `:truncation` ≈
> `@Sql(scripts = "cleanup.sql", executionPhase = AFTER_TEST_METHOD)` o un
> `@DirtiesContext` con Testcontainers reiniciando la base.

### 7.4 Tests en paralelo

La infraestructura está: `config/database.yml:95` usa
`database: stock_test<%= ENV["TEST_ENV_NUMBER"] %>`, que es la convención de
`parallel_tests` y de `rails test:prepare`. **La gema `parallel_tests` no está
instalada**, así que hoy la suite corre en un solo proceso.

Con 16 s de reloj no hace falta. El cálculo para decidir cuándo sí: paralelizar
tiene un costo fijo de N boots de Rails (1,9 s cada uno acá) más N bases que
crear. Con 4 procesos eso son ~8 s de overhead: sólo conviene cuando la suite
pasa de ~60 s.

Y ojo con dos cosas que rompen al paralelizar y que este repo tiene:

- **El cache en memoria** (`:memory_store`) es por proceso: está bien, cada
  proceso tiene el suyo.
- **Los tests de concurrencia hacen `TRUNCATE`** de todas las tablas. Si dos
  procesos compartieran base, se destrozarían. Con `TEST_ENV_NUMBER` cada uno
  tiene la suya, así que está cubierto.

> **Java.** `parallel_tests` ≈ `forkCount` de Surefire. La diferencia: Surefire
> forkea la **JVM** y comparten la misma base salvo que hagas algo; acá cada
> proceso tiene **su propia base** por convención de nombre. Es más seguro y más
> caro.

---

## 8. Tiempo: `travel_to`, `freeze_time`, y por qué `sleep` nunca

```ruby
# spec/rails_helper.rb:55
config.include ActiveSupport::Testing::TimeHelpers
```

```ruby
travel_to Time.zone.local(2026, 5, 1) do
  expect(SequenceCounter.next_reference("PO")).to eq("PO-2026-000001")
end

freeze_time do            # congela en el instante actual
  # ...
end

travel 3.days             # sin bloque: hay que llamar a travel_back
travel_back
```

Los usos reales:

```ruby
# spec/models/sequence_counter_spec.rb — el contador se reinicia por año
travel_to(Time.zone.local(2026, 12, 31)) { described_class.next_reference("TR") }
travel_to(Time.zone.local(2027, 1, 1)) do
  expect(described_class.next_reference("TR")).to eq("TR-2027-000001")
end

# spec/jobs/stock_jobs_spec.rb:81 — la ventana de silencio de las alertas
travel_to(described_class::SILENCE_WINDOW.from_now + 1.minute) do
  expect { described_class.perform_now }.to change(OutboxEvent, :count).by(1)
end

# spec/queries/stock_queries_spec.rb — movimientos con timestamps distintos para paginar
5.times do |i|
  travel_to(Time.zone.local(2026, 1, 1, 12, i)) { Stock::Receive.call(...) }
end
```

**Por qué `sleep` nunca:**

1. Es **lento por definición**: `sleep 1` cuesta 1 segundo, siempre, aunque la
   condición se cumpla en 5 ms.
2. Es **flakey por definición**: cuando el CI está cargado, 1 s no alcanza y el
   test falla al azar. Y la reacción natural (subirlo a 3 s) hace la suite tres
   veces más lenta sin arreglar nada.
3. En un test de tiempo **no prueba lo que creés**: si querés verificar que algo
   vence a los 30 minutos, `sleep 1800` no es una opción, así que igual vas a
   necesitar `travel_to`.

`travel_to` mockea `Time.now`, `Date.today` y `Time.current` a nivel proceso. **No
mockea `NOW()` de Postgres**: si tu código usa un default de la base o un
`CURRENT_TIMESTAMP` en SQL, `travel_to` no lo afecta. Ésa es la limitación que
sorprende, y por eso `Stock::Receive` recibe un `clock:` inyectable
(`app/services/stock/receive.rb:15`): es la forma limpia de controlarlo desde
donde sea.

**El único `sleep` de toda la suite** está acá, y está bien:

```ruby
# spec/integration/concurrency_spec.rb — optimistic locking
resultado = run_concurrently(2) do |i|
  copia = Product.find(producto.id)
  sleep 0.05   # ensanchamos la ventana a propósito para forzar el choque
  ...
end
```

No es una espera: es **ensanchar deliberadamente la ventana de carrera** para que
el choque ocurra. Distinto propósito, distinto juicio.

En los system tests el `sleep` es doblemente innecesario porque los matchers de
Capybara **ya reintentan** hasta `Capybara.default_max_wait_time` (5 s,
`spec/support/capybara.rb:97`):

```ruby
click_button "+ Agregar línea"
# Sin sleep: `have_css` con count espera solo hasta que se cumpla.
expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 2)
```

> **Java.** `travel_to` ≈ inyectar un `Clock` fijo (`Clock.fixed(...)`) o usar
> `@MockBean Clock`. La diferencia: en Java tenés que haber diseñado la clase para
> recibir un `Clock`; `travel_to` funciona **retroactivamente sobre todo el
> proceso**, sin tocar el código. Y `sleep` vs esperas de Capybara ≈ `Thread.sleep`
> vs Awaitility: la misma discusión, la misma respuesta.

---

## 9. HTTP externo, cobertura, flakiness y velocidad

### 9.1 WebMock y VCR

Las dos gemas están en el `Gemfile` (`webmock ~> 3.24`, `vcr ~> 6.3`, resueltas
en el lock a 3.26.4 y 6.4.0) y **están cableadas**: `spec/support/webmock.rb` y
`spec/support/vcr.rb` los carga `rails_helper` con el glob de `spec/support/`.
Lo que todavía no existe es un solo spec que las use, porque esta app no llama a
ningún servicio externo: el `Outbox::Publisher` se prueba con un `NoopAdapter`
real, que es mejor que un stub de HTTP. O sea: la red ya está cerrada, falta la
integración que la justifique.

El bloqueo es esto (`spec/support/webmock.rb:3` y `:25-29`):

```ruby
require "webmock/rspec"

WebMock.disable_net_connect!(
  allow_localhost: true,                  # Capybara levanta Puma en 127.0.0.1
  allow: [ "127.0.0.1", "localhost" ]     # y el CDP de Chromium habla por ahí
)
```

Ahí está el valor real: **si un test intenta salir a internet, falla**. Sin eso,
la suite depende de la red y de un tercero, y se vuelve flakey por razones que no
controlás. Lo comprobé pidiendo `https://example.com` dentro de un ejemplo: la
request no sale.

**Detalle que confunde al debuggear**: como `spec/support/vcr.rb:30` hace
`config.hook_into :webmock`, VCR se pone *encima* de WebMock, y una request no
stubbeada levanta `VCR::Errors::UnhandledHTTPRequestError`, **no**
`WebMock::NetConnectNotAllowedError`. Si buscás el nombre equivocado en el
mensaje de error, perdés diez minutos.

Con la red cerrada, el stub explícito sigue funcionando igual:

```ruby
stub_request(:post, "https://erp.proveedor.com/orders")
  .with(body: hash_including(reference: "PO-2026-000001"))
  .to_return(status: 201, body: { id: "abc" }.to_json,
             headers: { "Content-Type" => "application/json" })
```

VCR va un paso más allá: graba la interacción real una vez en un YAML
("cassette") y la reproduce después. La config real
(`spec/support/vcr.rb:28-49`), con lo que importa:

```ruby
VCR.configure do |config|
  config.cassette_library_dir = Rails.root.join("spec/fixtures/vcr_cassettes").to_s
  config.hook_into :webmock
  config.configure_rspec_metadata!   # habilita `it "...", :vcr do`
  config.ignore_localhost = true     # nunca grabar el server de Capybara

  # FILTRADO DE SECRETOS: sin esto, commiteás tu API key en un YAML.
  config.filter_sensitive_data("<AUTHORIZATION>") { |i| i.request.headers["Authorization"]&.first }
  config.filter_sensitive_data("<API_KEY>") { ENV.fetch("EXTERNAL_API_KEY", nil) }

  config.default_cassette_options = {
    record: :once,                       # graba si no existe; si existe, sólo reproduce
    match_requests_on: %i[method uri],
    allow_playback_repeats: true
  }
end
```

Hoy `spec/fixtures/vcr_cassettes/` tiene sólo un `.keep`: ningún ejemplo está
marcado con `:vcr` todavía.

El filtrado no es opcional: VCR graba **headers y body completos**, incluida la
`Authorization`, y el YAML queda adentro de `spec/`, donde nadie lo mira.

`match_requests_on: %i[method uri]` es el default de este repo y tiene una
consecuencia: si tu API manda datos distintos en cada llamada (timestamps,
nonces) y necesitás discriminar por body, hay que agregar `:body` y normalizarlo,
o el cassette matchea de más.

Cuándo cada uno: **WebMock** cuando vos definís la respuesta (casos de error,
timeouts, 500); **VCR** cuando la respuesta real es compleja y no querés
escribirla a mano. El riesgo de VCR es que el cassette envejece y tu test valida
un contrato que el proveedor ya cambió — mitigalo re-grabando periódicamente
(`record: :all` en una corrida manual).

Y hay un tercer tag propio, `:external_http` (`spec/support/webmock.rb:34-36`):
los ejemplos marcados así se **saltean** salvo que corras con `ALLOW_NET=1`.
Deberían ser cero; el tag existe para poder auditar los que no lo son.

> **Java.** WebMock ≈ WireMock con stubs programáticos; VCR ≈ WireMock en modo
> *record & playback* (`--proxy-all` + `--record-mappings`). La diferencia
> operativa: WireMock levanta un **servidor HTTP real** en un puerto y le
> apuntás la config; WebMock **intercepta a nivel de librería** (Net::HTTP,
> HTTParty, Faraday) sin abrir ningún socket. Por eso WebMock puede decir "toda
> conexión saliente es un error", que WireMock no puede.

### 9.2 Cobertura con SimpleCov

```ruby
# spec/spec_helper.rb:8-26 — TIENE que ir antes que cualquier código de la app
require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  add_filter "/spec/"
  add_group "Services", "app/services"
  # ...
  minimum_coverage line: 70, branch: 45
end if ENV["COVERAGE"]
```

Si cargás SimpleCov después del código de la app, **las líneas ya ejecutadas no
quedan registradas** y la cobertura sale muy por debajo de la real. Por eso está
en la primera línea de `spec_helper.rb`, que a su vez está en `.rspec` como
`--require spec_helper`.

Corriendo `COVERAGE=1 bundle exec rspec` en esta máquina:

```text
Line coverage:   1862 / 2105 (88,45 %)
Branch coverage:  346 / 547  (63,25 %)
Finished in 21,4 seconds         # contra 16,1 s sin cobertura: +33 %
```

**Line vs branch**, con un ejemplo del repo:

```ruby
# app/services/stock/receive.rb:29
return Result.failure(:invalid_quantity, "...") unless @quantity.positive?
```

Un solo test con `quantity: 10` marca esa **línea** como cubierta. Pero la rama
"quantity no positiva" nunca se ejecutó. Con `enable_coverage :branch`, SimpleCov
te muestra que falta. Por eso la diferencia entre 88 % de línea y 63 % de rama es
información, no ruido: **te está diciendo que hay 201 caminos condicionales sin
probar** (547 − 346).

**Por qué el 100 % no es la meta**, y el umbral está en 70/45:

- Poner 100 % obliga a escribir tests basura para tapar líneas triviales
  (`attr_reader`, `to_s`, guardas de `nil`), y esos tests después hay que
  mantenerlos.
- La cobertura mide **qué se ejecutó**, no **qué se verificó**. Un spec que llama
  al método y no hace ninguna aserción da 100 % de cobertura y cero valor.
- Poner 0 hace que la métrica no sirva de nada.

Qué sí conviene mirar:

1. **La tendencia**: que baje entre PRs es señal de alarma; el valor absoluto no
   dice mucho.
2. **La cobertura por grupo**: `add_group "Services"` existe justamente para
   poder mirar si el corazón del dominio está cubierto, sin que el promedio lo
   diluya con vistas y helpers.
3. **Los archivos en 0 %**: casi siempre es código muerto o un archivo que nadie
   probó nunca. Es el hallazgo más rentable de un reporte de cobertura.
4. **Las ramas faltantes** en los servicios: cada `unless` sin probar es un
   camino de error que va a aparecer en producción.

> **Java.** SimpleCov ≈ JaCoCo, con la misma distinción line/branch y el mismo
> `minimum_coverage` ≈ `<rule>` de `jacoco-maven-plugin`. Diferencia técnica: JaCoCo
> instrumenta bytecode; SimpleCov usa `Coverage`, el módulo nativo de Ruby. Y una
> diferencia cultural: en Ruby nadie mide *mutation coverage* de rutina, aunque
> existe (`mutant`); en Java tenés PIT y es más común.

### 9.3 Tests flakey: causas y arreglos

| Causa | Síntoma | Arreglo |
|---|---|---|
| **Orden** | pasa solo, falla en suite (o al revés) | ya corre en `:random` (`spec_helper.rb:52`); reproducí con `--seed N` y aislá con `--bisect` |
| **Estado global** | falla el ejemplo *siguiente* | `Current.reset` + `Rails.cache.clear` (`rails_helper.rb:75-78`); `around` para restaurar (`Rack::Attack.enabled`) |
| **Tiempo** | falla a las 23:59, o el 1° de enero | `travel_to` / `freeze_time`; nunca `Time.now` en una aserción |
| **Aleatoriedad** | falla 1 de cada 50 | `sequence` en vez de Faker para lo único; `Kernel.srand config.seed` ya está |
| **Concurrencia** | falla con el CI cargado | `CyclicBarrier`, `rescue` por thread, `clear_active_connections!` |
| **Esperas en el browser** | falla sólo en CI | matchers de Capybara (reintentan), nunca `sleep`; subir `process_timeout` |
| **Pool de conexiones** | `ConnectionTimeoutError` en un test *no* concurrente | el test anterior no devolvió conexiones; `max_connections: 15` |
| **Cache compartido** | 429 al azar en specs de API | `Rails.cache.clear` en el `before` global |
| **Dependencia de red** | falla cuando el proveedor está caído | `WebMock.disable_net_connect!` |

El flujo de diagnóstico, en orden:

```bash
bundle exec rspec                        # anota la seed que imprime al final
bundle exec rspec --seed 47251           # reproducí exactamente ese orden
bundle exec rspec --bisect --seed 47251  # RSpec busca el subconjunto mínimo que falla
bundle exec rspec --only-failures        # itera sólo sobre lo roto
```

`--bisect` es la herramienta más subestimada de RSpec: hace una búsqueda binaria
sobre los ejemplos y te dice **"estos dos specs juntos fallan"**. Encontrar un
acople de estado a mano puede llevar una tarde; con `--bisect` son dos minutos.

Y la regla cultural: **un test flakey es un bug, no una molestia**. La respuesta
correcta nunca es reintentar (`rspec-retry`); es entender qué estado se filtró.
Un `retry` convierte un test que a veces detecta un bug real de concurrencia en
un test que nunca detecta nada.

### 9.4 Velocidad: qué hace lenta una suite Rails

Medido acá, con `PROFILE=1 bundle exec rspec` (que activa
`config.profile_examples = 10`, `spec_helper.rb:47`):

```text
Top 10 más lentos: 6,41 s = 34,8 % del tiempo total
  1,52 s  spec/system/transfer_with_js_spec.rb:49        (transferencia completa con Chromium)
  0,96 s  spec/system/transfer_with_js_spec.rb:83
  0,74 s  spec/requests/api/v1/endpoint_coverage_spec.rb:99  (recorre todas las rutas)
  0,69 s  spec/system/transfer_with_js_spec.rb:36
  0,65 s  spec/requests/api/v1/rate_limiting_spec.rb:98  (400 requests a /up)
  ...
Finished in 16,09 seconds (files took 1,85 seconds to load)
```

Los cinco costos, en orden de impacto:

1. **Boot de Rails: ~1,9 s.** Es fijo por proceso. Con `bootsnap` (está en el
   `Gemfile`) ya está optimizado. En CI, `config.eager_load = ENV["CI"].present?`
   (`config/environments/test.rb:16`) lo empeora a propósito, para detectar
   errores de autoload que en desarrollo no aparecen. Es el trade-off correcto.
2. **Los system tests: ~4,6 s por 11 ejemplos.** Chromium arranca una vez y se
   reusa, pero cada `visit` es un round-trip real.
3. **`create` de FactoryBot.** ~6.700 queries en toda la corrida. Cada `create`
   evitable son ~2,8 ms (§5.2).
4. **bcrypt.** Ver abajo.
5. **SimpleCov: +33 %** (16,1 s → 21,4 s). Por eso está detrás de
   `if ENV["COVERAGE"]` y sólo se activa en CI.

**El costo de bcrypt, con números medidos en esta máquina:**

```ruby
BCrypt::Password.create("x", cost: 4)   # 1,2 ms      <- lo que usa el entorno test
BCrypt::Password.create("x", cost: 12)  # 243 ms      <- lo que usa producción
# ratio: ~200x
```

Rails setea `ActiveModel::SecurePassword.min_cost = true` en el entorno de test
(lo verifiqué: `min_cost` es `true`, y `BCrypt::Engine.cost` global es 12). Eso
baja el cost a `BCrypt::Engine::MIN_COST`, que es 4.

La suite hace **171 `INSERT INTO users`** (lo conté instrumentando
`sql.active_record` en una corrida completa). La cuenta:

- Con cost 4: 171 × 1,2 ms ≈ **0,2 s**.
- Con cost 12: 171 × 243 ms ≈ **41,5 s**.

O sea que sin `min_cost`, esta suite pasaría de 16 s a casi 60 s: **más del
triple, y el 70 % del tiempo sería hashear passwords**. Es la optimización
más rentable de cualquier suite Rails, y viene gratis. El bug clásico es
sobreescribirla con `config.active_model.secure_password_min_cost = false` o
setear `BCrypt::Engine.cost` en un initializer sin condicionarlo por entorno.

> **Java.** Es exactamente el mismo problema con `BCryptPasswordEncoder(12)` en
> los tests de Spring Security, y la solución también es la misma: un
> `PasswordEncoder` con strength baja (o `NoOpPasswordEncoder`) en el perfil de
> test. La diferencia es que Rails lo hace **por vos** y en Spring hay que
> acordarse.

Cómo medir, en orden de utilidad:

```bash
PROFILE=1 bundle exec rspec              # top 10 de ejemplos y de grupos
bundle exec rspec --dry-run              # ¿cuántos ejemplos hay? (338)
bundle exec rspec spec/services          # tiempo por capa
```

---

## 10. TDD en la práctica sobre este dominio

El ciclo sobre una regla real: **"no se puede egresar stock que está reservado
para otro"**. Es la regla que hoy vive en
`app/services/stock/apply_movement.rb:122-127` y que prueba
`spec/services/stock/issue_spec.rb:35`.

### Rojo

Escribís el test primero, con el vocabulario del negocio, **antes de saber cómo
se implementa**:

```ruby
# spec/services/stock/issue_spec.rb
it "RESPETA LO RESERVADO: no podés sacar stock comprometido con otro" do
  item.update!(quantity_reserved: 90)   # 100 físicos, disponible = 10

  result = issue(50)

  expect(result).to be_failure
  expect(result.error.code).to eq(:insufficient_available_stock)
  expect(item.reload.quantity_on_hand).to eq(100)   # intacto
end
```

```bash
$ bundle exec rspec spec/services/stock/issue_spec.rb:35

Failures:
  1) Stock::Issue RESPETA LO RESERVADO
     Failure/Error: expect(result).to be_failure
       expected `#<Result ok=true>.failure?` to return true, got false
```

Falla por la razón correcta: hoy el egreso pasa. Ese detalle importa — un test
que falla con `NoMethodError` no te dice nada.

### Verde

Lo mínimo que lo pone en verde, en `validate!`:

```ruby
# app/services/stock/apply_movement.rb:106
def validate!(item)
  new_on_hand  = item.quantity_on_hand + quantity
  new_reserved = item.quantity_reserved + reserved_delta

  # ... (la regla de stock físico ya existía, líneas 110-115)

  # LA invariante del dominio: no podés comprometer más de lo que tenés.
  if new_reserved > new_on_hand
    fail!(:insufficient_available_stock,
          "Disponible insuficiente: quedarían #{new_on_hand} en mano con #{new_reserved} reservados",
          available: item.quantity_available, requested: quantity.abs)
  end
end
```

```bash
$ bundle exec rspec spec/services/stock/issue_spec.rb
7 examples, 0 failures
```

### Refactor

Ahora que hay red, se puede mejorar sin miedo. Tres refactors que este código ya
tiene y que sólo son seguros con el test escrito:

1. **Mover la validación a `ApplyMovement`** en vez de duplicarla en `Issue`,
   `CommitReservation` y `Transfers::Dispatch`. La regla queda en un solo lugar y
   los tres services la heredan por composición.
2. **Devolver `details` accionables** (`available:`, `requested:`) para que la API
   pueda responder un 422 útil. Esto se probó primero acá y después, una sola
   vez, en `spec/requests/api/v1/stock_operations_spec.rb`.
3. **Confirmar que la transacción revierte**, con una aserción que sólo se puede
   escribir después (`spec/services/stock/issue_spec.rb:28-33`):

```ruby
it "rechaza sacar más de lo que hay" do
  result = issue(500)
  expect(result.error.code).to eq(:insufficient_stock)
  expect(result.error.details).to include(requested: 500)
  expect(item.reload.quantity_on_hand).to eq(100)   # intacto
end
```

### Cerrar el ciclo: los casos borde y la invariante

TDD no termina en verde. Los tres tests que se escriben **después** y que son los
que realmente atrapan bugs:

```ruby
it "permite sacar exactamente lo disponible (caso borde)" do
  item.update!(quantity_reserved: 90)   # disponible = 10
  expect(issue(10)).to be_ok
  # ...
  expect(item.quantity_available).to eq(0)
end
```

```ruby
# spec/integration/concurrency_spec.rb — la misma regla, bajo concurrencia
it "no se puede reservar dos veces la misma unidad" do
  # 6 threads reservando 4 sobre 10
  expect(exitosos).to eq(2)
  expect(item.quantity_reserved).to be <= item.quantity_on_hand
end
```

```ruby
# La invariante global, que no depende de ningún caso particular
expect(StockItems::Reconciliation.call).to be_empty
```

Ese último es el que más veces salvó este diseño: no prueba un escenario, prueba
que **la ecuación contable cierra** después de cualquier secuencia de operaciones.

Y la última red, que TDD no te da: los **CHECK constraints**
(`on_hand_non_negative`, `reserved_lte_on_hand`). Probados en
`spec/models/stock_item_spec.rb:32-45` con `update_column`, o sea salteando toda
la lógica de la app. Si mañana alguien escribe un rake task que toca la tabla
directo, Postgres lo frena.

---

## 11. CI

### Qué corre, en qué orden

`.github/workflows/ci.yml` define **cuatro jobs en paralelo**:

| Job | Qué corre | Por qué está separado |
|---|---|---|
| `scan_ruby` | `bin/brakeman`, `bin/bundler-audit` | falla rápido y no necesita base |
| `scan_js` | `bin/importmap audit` | idem |
| `lint` | `bin/rubocop -f github` | idem, con cache propio |
| `test` | `bundle exec rspec` + lint de factories | necesita Postgres + Redis + Chrome |

Ponerlos en paralelo hace que un error de estilo te avise en 40 s en vez de
esperar los 4 minutos de la suite. En Maven sería la diferencia entre un
`mvn verify` monolítico y jobs separados para `checkstyle`, `spotbugs`,
`dependency-check` y `test`.

El job `test`, con lo que importa:

```yaml
services:
  postgres:
    image: postgres:16
    options: >-
      --health-cmd="pg_isready -U postgres"     # CRÍTICO
      --health-interval=10s
  redis:
    image: redis:7
    options: >-
      --health-cmd="redis-cli ping"

env:
  RAILS_MAX_THREADS: 15    # pool > threads: los specs de concurrencia lo necesitan

steps:
  - uses: ruby/setup-ruby@v1
    with: { bundler-cache: true }               # cachea las gemas
  - run: bin/rails db:test:prepare              # carga db/schema.rb, no migra una por una
  - run: bundle exec rspec
    env: { COVERAGE: "1", CHROME_BIN: /usr/bin/google-chrome }
  - run: bundle exec rspec spec/lib             # con LINT_FACTORIES: "1"
  - uses: actions/upload-artifact@v4            # coverage, if: always()
  - uses: actions/upload-artifact@v4            # tmp/capybara, if: failure()
```

Cuatro decisiones que valen para cualquier CI de Rails:

1. **El `--health-cmd` no es opcional.** Sin él, el job arranca antes de que
   Postgres acepte conexiones y falla de forma intermitente. Es el "en mi máquina
   anda" más común de GitHub Actions.
2. **`bundler-cache: true`** cachea las gemas entre corridas. Es el 80 % del
   tiempo de un CI de Rails la primera vez. RuboCop tiene además su propio cache
   con `actions/cache@v4` y una clave derivada de `Gemfile.lock` + `.rubocop.yml`.
3. **`db:test:prepare` carga `db/schema.rb`**, no corre las migraciones una por
   una. Es mucho más rápido y además **detecta si alguien commiteó una migración
   sin regenerar el schema**.
4. **Artefactos de fallo.** El `coverage/` va con `if: always()`; los screenshots
   de Capybara (`tmp/capybara/`) con `if: failure()`. Debuggear un system test que
   sólo falla en CI sin el screenshot es adivinar.

### Cómo cachear, en orden de impacto

| Qué | Cómo | Ahorro típico |
|---|---|---|
| Gemas | `bundler-cache: true` | 1-3 min |
| RuboCop | `actions/cache` sobre `RUBOCOP_CACHE_ROOT` | 20-60 s |
| Schema | `db:test:prepare` (no `db:migrate`) | segundos a minutos |
| Boot | `bootsnap` (ya está) | ~1 s por proceso |
| Assets | `tmp/cache/assets` si usás Tailwind CLI | 10-30 s |

### Una nota sobre `bin/ci`

Rails 8.1 trae `ActiveSupport::ContinuousIntegration`: `bin/ci` corre lo que
declara `config/ci.rb`. Hoy ese archivo tiene setup, RuboCop y los tres escaneos
de seguridad, **pero no un step de tests** (`rails new --skip-test` no lo genera,
porque no sabe qué framework vas a usar). Los tests están sólo en el workflow de
GitHub Actions. Si querés que `bin/ci` sea de verdad "todo el CI en local", el
paso que falta es:

```ruby
step "Tests: RSpec", "bundle exec rspec"
```

---

## Errores que ves en producción

Cada uno con el síntoma exacto y el arreglo.

**1. El lint de factories del CI falla por traits que nadie escribió.**
Síntoma: `LINT_FACTORIES=1 bundle exec rspec spec/lib` tira
`FactoryBot::InvalidFactoryError` mencionando `stock_reservation+committed`,
`stock_movement+scrap` y otros tres que no están en `spec/factories/`.
Causa: `FactoryBot.automatically_define_enum_traits` (default `true` en
factory_bot 6) genera un trait por cada valor de cada `enum` de ActiveRecord, y
esos traits setean sólo la columna del enum, violando los CHECK constraints
(`stock_reservations_committed_at_present`). Arreglo verificado:
`FactoryBot.automatically_define_enum_traits = false` antes del `lint`, o usar
`FactoryBot.lint` sin `traits: true`.

**2. Los tests de rate limiting dan verde sin probar nada.**
Síntoma: hacés 200 requests y nunca llega el 429; el test pasa igual.
Causa: `config.cache_store = :null_store` (el default de Rails en test) hace que
`store.increment` devuelva `nil` y la comparación nunca supere el límite.
Arreglo: `:memory_store` (`config/environments/test.rb:35`) + `Rails.cache.clear`
en un `before` global (`spec/rails_helper.rb:77`).

**3. Un test de concurrencia pasa en verde sin ejercitar un solo lock.**
Síntoma: 8 threads egresando 3 unidades sobre un stock de 10 y todos "tienen
éxito"; o los threads no encuentran los datos que el test creó.
Causa: `use_transactional_fixtures = true`. La transacción del ejemplo nunca
commitea y los otros threads, con otra conexión, no ven nada.
Arreglo: el tag `:concurrency` con `self.use_transactional_tests = false` y
limpieza por `TRUNCATE` (`spec/support/concurrency.rb:54-64`).

**4. `ActiveRecord::ConnectionTimeoutError` en un test que no usa threads.**
Síntoma: falla el test *siguiente* al de concurrencia, con "could not obtain a
connection from the pool within 5.000 seconds".
Causa: un thread anterior no devolvió su conexión al pool.
Arreglo: `connection_pool.with_connection` por thread y
`clear_active_connections!` al final (`spec/support/concurrency.rb:43`); y el pool
de test en 15 (`config/database.yml:101`).

**5. Todos los system tests con JS fallan de golpe con "Browser did not produce
websocket url within 10 seconds".**
Síntoma: el browser arranca bien si lo probás a mano con Ferrum, pero en la suite
falla; y una vez que falla uno, fallan todos.
Causa: `driven_by :cuprite` **re-registra** el driver y pisa tu
`Capybara.register_driver`, así que tu `process_timeout:` nunca se aplica (10 s
es el default de Ferrum). El cascadeo es por el `Capybara.reset_sessions!` que
reintenta después de cada ejemplo.
Arreglo: pasar la config por `options:` de `driven_by`, y una **copia** del hash
porque `driven_by` lo muta (`spec/support/capybara.rb:91-95`).

**6. Un test pasa solo y falla en la suite (o al revés).**
Síntoma: verde con `rspec spec/x_spec.rb`, rojo con `rspec`.
Causa: estado global filtrado — `Current`, `Rails.cache`, un contador de
Rack::Attack, una variable de clase.
Arreglo: reproducí con `--seed N`, aislá con `--bisect`, y limpiá el estado en un
`before` global (`Current.reset`, `Rails.cache.clear`) o con `around` si hay que
restaurar un valor.

**7. La cobertura sale 20 puntos por debajo de la real.**
Síntoma: SimpleCov reporta 55 % cuando visiblemente hay más cubierto.
Causa: `require "simplecov"` después de que se cargó código de la app.
Arreglo: primera línea de `spec/spec_helper.rb`, y `spec_helper` cargado desde
`.rspec` con `--require spec_helper`.

**8. La suite tarda 3 veces lo que debería y nadie sabe por qué.**
Síntoma: casi 60 s en vez de 16 s.
Causa típica: bcrypt con cost de producción en test (medido acá: 243 ms vs 1,2
ms por hash, ~200×; con 171 usuarios creados son 41 s de puro hash). Suele
aparecer por un initializer que setea `BCrypt::Engine.cost` sin condicionar por
entorno.
Arreglo: dejar que Rails maneje `ActiveModel::SecurePassword.min_cost` (es `true`
en test); confirmalo con `bin/rails runner`. Y perfilá con `PROFILE=1` antes de
adivinar.

**9. Un N+1 se cuela a producción y nadie se entera hasta el timeout.**
Síntoma: un endpoint que iba a 80 ms empieza a tardar 4 s cuando la tabla crece.
Causa: en Rails no existe `LazyInitializationException`; la asociación se carga
donde la toques, en silencio.
Arreglo: `Bullet.raise = true` y un ejemplo `:n_plus_one` por cada endpoint de
listado (`spec/support/bullet.rb:20`, `spec/queries/products_search_spec.rb:64`).

**10. Un `sleep` "arregla" un test flakey y lo empeora.**
Síntoma: el test pasa localmente, sigue fallando en CI, y la suite ahora tarda 30 s más.
Causa: `sleep` es a la vez lento y no determinista.
Arreglo: `travel_to`/`freeze_time` para tiempo, matchers de Capybara (que ya
reintentan hasta `default_max_wait_time`) para el browser, y subir
`process_timeout` del driver cuando el CI está cargado — no el `sleep`.

**11. `undefined method 'post' for an instance of RSpec::ExampleGroups::...`.**
Síntoma: escribiste un request spec y no anda.
Causa: el archivo no está en `spec/requests/`, así que
`infer_spec_type_from_file_location!` no le puso `type: :request`.
Arreglo: movelo, o declará `RSpec.describe "...", type: :request` explícito.

**12. Un job encolado adentro de una transacción se procesa antes del `COMMIT` —
o después de un `ROLLBACK`.**
Síntoma: el worker levanta el job y no encuentra la fila; o corre un job de una
operación que se revirtió.
Causa: con Sidekiq, `perform_later` escribe en Redis en el acto, sin esperar la
transacción.
Arreglo: `self.enqueue_after_transaction_commit = true` **en la clase del job**
(o en `ApplicationJob`). Cuidado con la trampa: en Rails 8.1 el railtie de Active
Job **excluye a propósito** esa clave de la configuración global
(`active_job/railtie.rb`, comentario "This config can't be applied globally"),
así que `config.active_job.enqueue_after_transaction_commit` en un initializer no
tiene efecto. En este repo está seteada así en
`config/initializers/sidekiq.rb:74`, y lo verifiqué: hoy
`ActiveJob::Base.enqueue_after_transaction_commit` es `false`. Y para lo que no
se puede perder, esto no alcanza: va el patrón outbox
(`app/services/outbox/recorder.rb:47`, con
`ActiveRecord.after_all_transactions_commit`).

---

## Cómo responder esto en una entrevista

**"¿RSpec o Minitest? ¿Por qué?"**

> Minitest viene con Rails, es chico y es Ruby común: para una gema o un servicio
> simple lo elijo sin dudar. Para una app de dominio uso RSpec por tres cosas
> concretas: `let` perezoso (con cuatro o cinco dependencias por grupo,
> materializar sólo lo que el ejemplo usa importa), metadata como `:concurrency`
> o `js: true` que dispara hooks globales sin heredar de nada, y que la salida
> con `--format documentation` es la especificación del negocio leíble.
>
> El costo real es el DSL: RSpec tiene diez veces más código que Minitest y es
> facilísimo escribir specs ilegibles con `shared_examples` anidados. Mi regla es
> que un ejemplo tiene que entenderse **sin scrollear**, y por eso en este repo la
> matriz de policies es un doble loop de Ruby común y no un shared example.

**"¿Cómo se distribuyen tus tests? ¿Pirámide?"**

> Pirámide aplanada, más cerca del "trofeo". En esta suite el 17 % son specs de
> servicio y ahí está la lógica de negocio; el 15 % son request specs que prueban
> sólo el contrato HTTP, sin repetir casos de negocio; y sólo el 3 % son system
> tests, que se llevan casi el 30 % del tiempo. Ésa es la proporción que quiero.
>
> La razón de que en Rails la pirámide se aplane es que **el contexto se bootea
> una sola vez y no hay `@DirtiesContext`**: un test contra Postgres real tarda 60
> ms. En Spring la excusa para mockear el repositorio es evitar levantar el
> contexto; acá esa excusa no existe, y mockear ActiveRecord sólo te da un test
> que no prueba lo que puede fallar.

**"¿Qué mockeás y qué no?"**

> Regla: no mockeo lo que no me pertenece, y mockeo en los bordes. La base de
> datos nunca —es lo que puede fallar de verdad, y en un dominio de stock las
> constraints y los locks *son* la lógica. Sí mockeo HTTP externo, el reloj y el
> broker de mensajes.
>
> Cuando puedo, prefiero un **Null Object real** antes que un doble: en este repo
> los services reciben un `event_recorder:` y en test le paso un
> `Outbox::NullRecorder` que acumula en memoria. Es código de producción, así que
> si cambia el contrato de `record` el archivo rompe; un doble flexible seguiría
> respondiendo cualquier cosa y el test daría verde en falso.
>
> Y si uso doble, **siempre verificado**: `instance_double`/`class_double` más
> `verify_partial_doubles = true`. Viniendo de Mockito eso es recuperar la
> verificación que en Java te da el compilador. `double(...)` a secas es un
> downgrade de seguridad.

**"¿Cómo testeás concurrencia?"**

> Con threads reales y conexiones reales, o no estás testeando concurrencia.
> Cuatro cosas que hay que hacer bien: una `CyclicBarrier` para que arranquen
> juntos, `with_connection` por thread (y el pool de test más grande que la
> cantidad de threads: acá está en 15), un `rescue` por thread —en Ruby una
> excepción en un thread sin `join` se pierde en silencio y el test da verde con
> todo roto—, y devolver las conexiones al pool al final o el test siguiente falla
> por checkout timeout.
>
> Lo más importante: **hay que desactivar las transactional fixtures**. La
> transacción del ejemplo nunca commitea, así que el thread nuevo con otra
> conexión no ve nada y el test pasa sin haber ejercitado un solo lock. Ese falso
> verde es peor que no tener test.
>
> Y no me quedo sólo con los tests: hay una invariante global —la proyección
> contra el `SUM` del ledger— que se verifica al final de los flujos y en un job
> nocturno. Los tests dicen "no encontré el bug"; la reconciliación dice "si hay
> uno, me entero".

**"Tenés un test flakey. ¿Qué hacés?"**

> Nunca `rspec-retry`. Un flakey es un bug: o el test está mal, o el código tiene
> una carrera de verdad, y reintentar oculta las dos cosas.
>
> El flujo es: anoto la seed que RSpec imprime, reproduzco con `--seed N`, y si
> depende del orden uso `--bisect`, que hace búsqueda binaria y te dice "estos dos
> specs juntos fallan". Encontrar un acople de estado a mano puede llevar una
> tarde; con `--bisect` son dos minutos.
>
> Las causas por frecuencia: estado global (cache, `Current`, contadores de rate
> limit), tiempo real en una aserción, unicidad basada en Faker en vez de
> `sequence`, y esperas en el browser. Para las tres primeras la suite ya tiene
> red: orden aleatorio por defecto, `Current.reset` y `Rails.cache.clear` en un
> `before` global, y `sequence` en todas las factories.

**"¿Qué cobertura buscás?"**

> Ninguna en particular como número. Los umbrales de esta suite están en 70 % de
> línea y 45 % de rama, y hoy está en 88 % / 63 %. Poner 100 % obliga a escribir
> tests basura para tapar `attr_reader`s, y esos tests después hay que
> mantenerlos. Además la cobertura mide qué se **ejecutó**, no qué se **verificó**:
> un spec que llama al método sin ninguna aserción da 100 % y cero valor.
>
> Lo que sí miro: la tendencia entre PRs, la cobertura del grupo `Services` por
> separado —para que el promedio no se diluya con vistas y helpers—, los archivos
> en 0 % (casi siempre es código muerto) y la **cobertura de rama** en los
> servicios. La brecha entre 88 % de línea y 63 % de rama me está diciendo que hay
> 201 caminos condicionales sin probar, y ésos son los `unless` de error que
> aparecen en producción.

**"¿Cómo hacés rápida una suite Rails?"**

> Primero mido, con `PROFILE=1 bundle exec rspec`, que te da el top 10. Adivinar
> acá es caro.
>
> Los cuatro costos reales, en orden: los system tests (acá el 3 % de los
> ejemplos se lleva casi el 30 % del tiempo — y está bien, mientras sean pocos
> y bien elegidos), los `create` de FactoryBot (`build_stubbed` es 5-6× más barato, y en
> los specs de policy eso significa 33 ejemplos en medio segundo sin tocar la
> base), bcrypt, y SimpleCov (+33 %, por eso va detrás de una variable de entorno
> y sólo corre en CI).
>
> Lo de bcrypt es el ejemplo que más me gusta porque es aritmética: cost 12 son
> 243 ms por hash y cost 4 son 1,2 ms. Esta suite crea 171 usuarios, así que sin
> `min_cost` pasaría de 16 s a casi 60, con el 70 % del tiempo hasheando
> passwords. Rails lo maneja solo en test; el bug aparece cuando alguien setea
> `BCrypt::Engine.cost` en un initializer sin condicionar por entorno.
>
> Paralelizar es lo último. Tiene un costo fijo de N boots de Rails (1,9 s cada
> uno) más N bases, así que recién conviene arriba de un minuto de suite.

---

## Para seguir

- `docs/05-solid-y-patrones.md` — por qué los casos de uso son objetos con `call`
  y devuelven `Result`; es lo que hace que los specs de servicio sean tan
  directos.
- `docs/06-concurrencia-transacciones-y-locking.md` — el detalle de los locks que
  ejercita `spec/integration/concurrency_spec.rb`.
- `docs/04-optimizacion-de-queries.md` — planes de ejecución y N+1, la contraparte
  de los specs de query object.
- `docs/07-colas-jobs-y-mensajeria.md` — el patrón outbox que testea
  `spec/jobs/outbox_publish_pending_job_spec.rb`.
- Los comentarios de `spec/rails_helper.rb`, `spec/spec_helper.rb`,
  `spec/support/capybara.rb` y `spec/support/concurrency.rb`: son la fuente de
  verdad de todo lo de acá, y están escritos para leerse.
