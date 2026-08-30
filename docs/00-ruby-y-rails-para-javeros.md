# Ruby y Rails para desarrolladores Java

Documento de entrada. Asume que sabés Java en serio (Spring, JPA/Hibernate, Maven, la JVM,
threads) y que lo que te falta es el mapa de Ruby. Acá está la traducción concepto por
concepto y, sobre todo, **dónde la traducción se rompe**: esos son los puntos donde un
javero escribe Ruby que corre y está mal.

Todo el código citado sale de este repo (Rails 8.1.3.1 / Ruby 3.3.6, control de stock) o
de comandos que corrí contra él. Las rutas son reales; abrilas mientras leés.

```bash
$ ruby -v ; bin/rails -v ; cat .ruby-version
ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
Rails 8.1.3.1
ruby-3.3.6
```

---

## 1. El modelo de objetos: todo es objeto, todo es mensaje

### 1.1 No hay primitivos ni `static`

```ruby
5.class            # => Integer      <- no hay int/Integer, autoboxing ni clases utilitarias
nil.class          # => NilClass     <- nil ES un objeto y responde mensajes
Integer.class      # => Class        <- la clase también es un objeto
```

Como `nil` responde mensajes (`nil.to_a` → `[]`), el estilo defensivo cambia: donde en Java
escribís `if (x == null || x.isEmpty())`, en Ruby escribís `x.blank?` — una sola llamada que
ya contempla el `nil`.

Tampoco hay `static`: lo que parece uno es un método en la **clase singleton** del
objeto-clase (`app/lib/result.rb:43-47`):

```ruby
class << self
  def success(value = nil) = new(ok: true, value:)
  def failure(code, message, **details) =
    new(ok: false, error: Error.new(code:, message:, details:))
end
```

A diferencia de un `static`, estos métodos se heredan, se sobreescriben y se stubean en
tests. Mismo patrón en `app/services/application_service.rb:55`,
`app/queries/application_query.rb:23` y `app/models/api_token.rb:33`.

### 1.2 Llamar un método es mandar un mensaje

No hay resolución estática: `obj.foo(1)` es `obj.send(:foo, 1)`, y el intérprete busca
`:foo` en la cadena de ancestros **en runtime**, cada vez (con inline cache).

```ruby
# app/controllers/concerns/api/idempotency.rb:135
skip_authorization if respond_to?(:skip_authorization, true)
```

Ese `true` incluye métodos privados. El concern funciona en un controller con Pundit y en uno
sin, sin `instanceof` ni interfaz opcional: en Java sería
`try { getClass().getDeclaredMethod(...) } catch (NoSuchMethodException e) {}`.

Y con símbolos calculados en runtime (`app/models/concerns/has_money.rb:30-33`):

```ruby
ValueObjects::Money.new(cents: public_send(cents_column) || 0,
                        currency: public_send(currency_column) || "USD")
```

Reflexión sin `Method.invoke`, sin `setAccessible`, sin excepciones checked.

### 1.3 Open classes y monkey patching

Cualquier clase, del core o de una gema, se puede reabrir. No es un hack, es el modelo
(`config/initializers/rack_attack.rb:45-51`):

```ruby
class Rack::Attack
  class Request < ::Rack::Request
    def remote_ip
      @remote_ip ||= (env["action_dispatch.remote_ip"] || ip).to_s
    end
  end
end
```

Le agregamos un método a una clase de terceros: en Java, un wrapper, un decorator o un agente
que toque bytecode. Rails usa esto a lo grande:

```bash
$ bin/rails runner 'puts Object.ancestors.inspect'
[ActiveSupport::Dependencies::RequireDependency, Object,
 ActiveSupport::ToJsonWithActiveSupportEncoder, JSON::GeneratorMethods,
 ActiveSupport::Tryable, Kernel, BasicObject]
```

`Object` — la raíz de todo — tiene cuatro módulos inyectados por gemas, y uno está **antes**
de `Object` (o sea, `prepend`eado). Eso es lo que hace funcionar `5.days.ago`,
`"foo".blank?` y `nil.try(:x)`.

**Dónde se rompe:** el parche es global al proceso. Si dos gemas parchean el mismo método,
gana la última cargada y no hay warning. Java tiene shading, classloaders y JPMS para
evitarlo; Ruby no tiene nada equivalente. Por eso
`config/initializers/rack_attack.rb:39-44` documenta *por qué* ese parche está permitido
(la propia doc de la gema lo recomienda).

### 1.4 Duck typing en vez de interfaces

No hay `interface` ni `implements`. Un objeto sirve si responde los mensajes que le mandás
(`app/services/outbox/publisher.rb:17-46`):

```ruby
ADAPTERS = { "log" => -> { LogAdapter.new }, "noop" => -> { NoopAdapter.new }, ... }.freeze

class LogAdapter
  def publish(message) = Rails.logger.info(event: "domain_event", **message)
end
class NoopAdapter
  def initialize = @published = []
  def publish(message) = @published << message
end
```

Los adapters no comparten superclase ni módulo. La "interfaz" es `publish(message)` y vive
en un comentario y en los tests — el archivo lo dice en las líneas 11-14: menos ceremonia,
misma sustancia, **cero ayuda del compilador, por eso los tests son obligatorios**.

El caso más elegante es `app/forms/application_form.rb`: un `StockTransferForm` no tiene
tabla ni hereda de `ActiveRecord::Base`, y sin embargo funciona con `form_with` igual que un
modelo, porque incluye `ActiveModel::Model` y responde a `to_key`, `errors`, `valid?`. Rails
nunca pregunta de qué clase es. El precio: donde Java te da un error de compilación, Ruby te
da un `NoMethodError` a las 3 AM.

### 1.5 Módulos: mixin, no herencia múltiple

Ruby tiene herencia **simple** de clases (como Java) y módulos que se mezclan
(`app/models/product.rb:4-5`):

```ruby
class Product < ApplicationRecord
  include Discardable   # aporta discard!, kept?, y los scopes kept/discarded
  include HasMoney      # aporta la macro de clase has_money
```

Composición: `Product` no "es un" descartable, "tiene" comportamiento descartable. A
diferencia de la herencia múltiple de C++, los módulos se **linealizan**: no hay diamante
ambiguo, hay un orden determinado y consultable con `ancestors`.

---

## 2. La cadena de ancestros y el method lookup

### 2.1 `ancestors` es la verdad

En Java la jerarquía es un árbol de clases más un set plano de interfaces. En Ruby es **una
lista ordenada** que podés imprimir:

```bash
$ bin/rails runner 'p StockItem.ancestors.first(4).map(&:name)'
["StockItem", "StockItem::GeneratedAssociationMethods",
 "StockItem::GeneratedAttributeMethods", "ApplicationRecord"]
```

(Uso `.map(&:name)` porque `inspect` de una clase de ActiveRecord te imprime el esquema
entero.) `GeneratedAttributeMethods`: Rails lee el esquema de Postgres —**perezosamente**, la
primera vez que se usa el modelo, no al bootear; en dev podés ver la clase sin cargar y dice
`call 'StockItem.load_schema'`— genera un módulo anónimo con `#sku`, `#sku=`, `#sku_changed?`
y lo inserta en la cadena. Sin proxies dinámicos, sin bytecode generation, sin `@Entity`
procesado por un annotation processor: es un módulo más.

```bash
$ bin/rails runner 'puts ValueObjects::Money.ancestors.first(6).inspect'
[ValueObjects::Money, Comparable, #<Class:0x00007f3ffd5f1100>, Data,
 ActiveSupport::Dependencies::RequireDependency, Object]
```

Ese `#<Class:0x...>` es la clase **anónima** que devolvió `Data.define`
(`app/models/value_objects/money.rb:45`). Es normal: las clases son objetos, y una
constante sólo le pone nombre a lo que le asignes.

### 2.2 `include` vs `prepend` vs `extend`

| Forma | Dónde entra el módulo | Equivalente mental |
|---|---|---|
| `include M` | **debajo** de la clase (la clase gana) | `implements` con default methods |
| `prepend M` | **encima** de la clase (el módulo gana, puede `super`) | un `@Around` de AOP, sin AspectJ |
| `extend M` | en la clase singleton → métodos "de clase" | métodos `static` heredados |

`prepend` no tiene equivalente limpio en Java: envuelve un método existente sin tocar su
código y sin herencia.

```ruby
module Auditado
  def save!(...)
    Rails.logger.info("guardando #{self.class}")
    super
  end
end
class StockItem; prepend Auditado; end
```

En Spring necesitarías un proxy CGLIB y aceptar que las llamadas internas (`this.save()`)
no pasan por el proxy. En Ruby pasan siempre: no hay proxy, cambiaste el lookup.

### 2.3 El algoritmo de lookup

Clase singleton del objeto → módulos `prepend`eados (orden inverso) → la clase → módulos
`include`idos (orden inverso) → superclase, y se repite hasta `BasicObject`. Si no lo
encontró, `method_missing` recorre lo mismo; si tampoco, `NoMethodError`.

Ese orden explica por qué `include Comparable` (`money.rb:54`) convive con un `<=>` propio
(`money.rb:97`): `Comparable` aporta `<`, `>`, `between?` y `clamp` **implementados en
términos de** `<=>`, y como queda debajo de la clase, tu `<=>` gana. Template method sin
herencia:

```bash
$ bin/rails runner 'puts(ValueObjects::Money.from_amount("5","USD") <
                         ValueObjects::Money.from_amount("19.99","USD"))'
true
```

### 2.4 `method_missing`: el hook que Java no tiene

```bash
$ bin/rails runner '
puts "antes:   #{Product.singleton_class.instance_methods(false).include?(:find_by_sku)}"
puts "respond_to?: #{Product.respond_to?(:find_by_sku)}"
Product.find_by_sku("X")
puts "despues: #{Product.singleton_class.instance_methods(false).include?(:find_by_sku)}"
puts "source:  #{Product.method(:find_by_sku).source_location.inspect}"'

antes:   false
respond_to?: true
despues: true
source:  [".../activerecord-8.1.3.1/lib/active_record/dynamic_matchers.rb", 40]
```

Tres cosas, y es el patrón canónico:

- `find_by_sku` **no existe** antes de la primera llamada.
- `respond_to?` igual dice `true`, porque ActiveRecord implementa `respond_to_missing?`.
  **Regla:** si implementás `method_missing`, implementá siempre `respond_to_missing?`; si
  no, tu objeto miente y rompe todo el código que hace duck typing.
- Después de la primera llamada **queda definido** en la clase singleton: "define on miss",
  se paga la reflexión una sola vez.

Lo más cercano en Java es un `InvocationHandler` de `Proxy`, o Spring Data derivando
`findBySkuAndActiveTrue` — pero eso genera una implementación al arrancar; Ruby lo hace
perezosamente, sin generar clases.

**Dónde se rompe:** mata los stack traces útiles y hace que un typo (`prodcut.skuu`) falle
en runtime y en la línea equivocada. Por eso en este repo sólo aparece vía Rails, nunca
escrito a mano.

---

## 3. Bloques, procs, lambdas y `yield`

### 3.1 El bloque es el argumento privilegiado

En Java una lambda es un argumento más y necesita una interfaz funcional para tener tipo.
En Ruby un método puede recibir **un bloque**: un argumento anónimo, sin tipo, que va
después de los paréntesis y no ocupa lugar en la firma.

```ruby
# app/lib/result.rb:66-70                       # uso (result.rb:62):
def then_try                                    #   find_item.then_try { |i| check_stock(i) }
  return self if failure?                       #            .then_try { |i| write(i) }
  yield(value)
end
```

Sin `Function<StockItem, Result>`, sin `@FunctionalInterface`. Es lo que hace que el DSL de
Rails no se sienta como un DSL:

```ruby
def transactional                                 # app/services/application_service.rb:68
  ApplicationRecord.transaction { yield }
rescue BusinessRuleViolation => e
  e.result
end

def apply_if(relation, value)                     # app/queries/application_query.rb:35
  value.present? ? yield(relation, value) : relation
end

def +(other) = combine(other) { |a, b| a + b }    # money.rb:71 y quantity.rb:34
def combine(other)                                # money.rb:104
  assert_same_currency!(other)
  with(cents: yield(cents, other.cents))
end
```

`apply_if` mata el `relation = relation.where(...) if x.present?` repetido en un query object
con filtros opcionales; acá lo usa `app/queries/products/search.rb:47-48`.

Ese último es "template method con bloque": `combine` centraliza la validación de moneda y
el `with`; el bloque aporta la única línea que cambia. En Java serían dos métodos con la
validación duplicada, o un `BinaryOperator<Integer>` con más ruido que señal.

### 3.2 Bloque vs Proc vs Lambda

| | Bloque | `proc {}` | `lambda {}` / `-> () {}` |
|---|---|---|---|
| ¿Es un objeto? | No (salvo que lo captures con `&`) | Sí | Sí |
| Chequeo de aridad | — | **No** (rellena con `nil`) | **Sí** (`ArgumentError`) |
| `return` dentro | vuelve del método que lo definió | **vuelve del método que lo definió** ⚠️ | vuelve del lambda |

La fila del `return` es la que muerde: si el método que creó el `proc` ya volvió, tirás
`LocalJumpError`. **Regla:** si guardás un callable en una constante o variable, usá `->`.
Este repo lo hace en todos lados:

```ruby
scope :in_stock, -> { where(quantity_available: 1..) }        # stock_item.rb:40
normalizes :sku, with: ->(s) { s.to_s.strip.upcase }          # product.rb:29
by: -> { current_api_token&.id || request.remote_ip }         # base_controller.rb:77
"log" => -> { LogAdapter.new },                               # outbox/publisher.rb:18
```

El último es un `Supplier<LogAdapter>` en un `Map`: una factory sin `@Configuration`, sin
`@Bean`, sin container.

**Por qué los scopes son lambdas:** sin el `->`, el `where` se evaluaría una sola vez al
cargar la clase y congelaría cualquier `Time.current` que tenga adentro — el mismo bug que un
`static final Date HOY = new Date()`. Rails ya no te deja hacerlo: `scope :active, where(...)`
levanta `ArgumentError: The scope body needs to be callable.` (comprobado). El lambda se
evalúa en cada llamada.

### 3.3 El operador `&` y `Symbol#to_proc`

`&` convierte bloque ↔ callable. Y `&:id` equivale a `{ |x| x.id }`:

```ruby
StockItems::Availability.call(product_ids: @products.map(&:id))   # app/controllers/products_controller.rb:13
enum :kind, KINDS.index_by(&:itself), validate: true              # stock_movement.rb:25
.order(:id).lock.includes(:product).index_by(&:product_id)        # transfers/dispatch.rb:101
```

`KINDS.index_by(&:itself)` convierte `%w[receipt issue ...]` en
`{"receipt" => "receipt", ...}` — el mapa que `enum` necesita para backing de String en vez
de ordinal (así reordenar el array no cambia el significado de los datos históricos). En
Java: `Arrays.stream(KINDS).collect(toMap(identity(), identity()))`.

### 3.4 Comparación con las lambdas de Java 8

Tres diferencias que importan: (a) la lambda de Java tiene tipo verificado, el bloque de Ruby
no tiene ninguno; (b) Java no tiene "bloque implícito por llamada", que es lo que hace que
`yield` sea tan barato de escribir; (c) Java sólo captura variables *effectively final*,
mientras que un bloque de Ruby es una closure real y **puede mutar** el entorno. La última es
la peligrosa: Java lo prohíbe justamente para no romper la concurrencia.

---

## 4. Symbols vs Strings, y por qué importa

Un `Symbol` (`:sku`) es un identificador internado e inmutable, único por proceso. Un
`String` es una secuencia de bytes mutable. Lo más cercano en Java es `String.intern()` o
un `enum`, pero con sintaxis de primera clase.

Medición real con el Ruby 3.3.6 de este entorno, en un script con `# frozen_string_literal:
true` y el GC desactivado para que los números salgan limpios (100.000 iteraciones de cada
forma, contando los `T_STRING` nuevos con `ObjectSpace.count_objects`):

```text
literal congelado ("clave")   :      27 strings   # frozen_string_literal: true activo
copia mutable    (+"clave")   : 100 000 strings
interpolación    ("cl#{1}ave"): 100 000 strings
símbolo          (:clave)     :       0 strings

:clave.object_id   estable: true
"clave".object_id  estable: true    # gracias al literal congelado
+"clave".object_id estable: false   # la copia mutable es un objeto nuevo cada vez
```

Ojo con la anteúltima línea: `"clave".object_id` sale estable **porque el archivo tiene el
comentario mágico**. Sacalo y da `false`, como cualquier literal mutable.

Tres reglas salen de ahí:

1. **Claves de hash y nombres de método/columna → símbolos.** Se comparan por identidad, no
   byte a byte, y no allocan.
2. **`# frozen_string_literal: true` en la primera línea de cada archivo.** Está en 97 de
   los 103 `.rb` de `app/` (los 6 que faltan son los que generó `rails generate
   authentication` y nadie tocó). Es la optimización con mejor relación beneficio/esfuerzo
   de Ruby. Efecto secundario: mutar un literal ahora tira `FrozenError` — y como no es
   uniforme, el error aparece sólo en algunos archivos.
3. **Los símbolos dinámicos sí se recolectan** desde Ruby 2.2. Antes eran un vector de DoS
   (10 millones de claves JSON distintas y llenabas la tabla hasta el OOM).

**La trampa clásica del javero:** asumir que un `Hash` normaliza las claves.

```ruby
h = { sku: "ABC" }
h["sku"]   # => nil     ← acá se te va la tarde
h[:sku]    # => "ABC"
```

`JSON.parse` devuelve claves **String**; un hash literal usa **Symbol**. Por eso los `params`
de un controller no son un `Hash`: son un `ActionController::Parameters` (comprobado:
`params.is_a?(Hash) # => false`) que por dentro guarda un `HashWithIndifferentAccess`, así
que ahí las dos formas funcionan. En cuanto salís de `params`, se acabó: cuando el dato llega
de JSON hay que normalizarlo en el borde (`app/forms/stock_transfer_form.rb:26`):

```ruby
@normalized_lines ||= Array(lines).map { |l| l.respond_to?(:to_h) ? l.to_h.symbolize_keys : l }
```

---

## 5. Ruby 3.x moderno, con el código de este repo

### 5.1 `Data.define` — el `record` de Java 16

```ruby
# app/lib/result.rb:37-39
Error = Data.define(:code, :message, :details) do
  def to_h = { code:, message:, details: }
end
```

Genera una clase de valor **inmutable** con `==`, `hash`, `to_h`, `inspect`, `deconstruct` y
`deconstruct_keys`. Equivale a
`record Error(String code, String message, Map<String,Object> details) {}`. (`Struct` es el
primo mutable y con setters: para value objects usá siempre `Data`.)

| | `record` Java | `Data.define` Ruby |
|---|---|---|
| Inmutabilidad | Campos `final` | Instancia congelada (`frozen? == true`) |
| Copia con cambios | A mano, o Lombok `@With` | `with(cents: 100)` de fábrica |
| Constructor con validación | Constructor compacto | `def initialize(...)` + `super` |
| Argumentos | Posicionales | Posicionales **o** por nombre |
| Herencia | Prohibida (`final`) | `class Money < Data.define(...)` ✅ |

Ese último punto es el que usa el repo. `app/models/value_objects/money.rb:45-85`:

```ruby
class Money < Data.define(:cents, :currency)
  SUBUNITS = { "USD" => 100, "CLP" => 1, "JPY" => 1, ... }.freeze   # CLP y JPY sin centavos
  class CurrencyMismatch < StandardError; end
  include Comparable

  def initialize(cents:, currency: "USD")            # constructor compacto: normaliza
    super(cents: cents.to_i, currency: currency.to_s.upcase)
  end

  def +(other) = combine(other) { |a, b| a + b }
  def *(factor)
    raise ArgumentError, "no se puede multiplicar dinero por dinero" if factor.is_a?(Money)
    with(cents: (BigDecimal(cents.to_s) * BigDecimal(factor.to_s)).round.to_i)
  end
  def -@ = with(cents: -cents)                       # menos unario: -money
end
```

`app/models/value_objects/quantity.rb:19-32` hace lo mismo pero valida en el constructor:

```ruby
class Quantity < Data.define(:amount, :unit)
  UNITS = %w[unit kg g l ml m cm box pallet].freeze
  class UnitMismatch < StandardError; end
  class InvalidUnit  < StandardError; end
  include Comparable

  def initialize(amount:, unit: "unit")
    unit = unit.to_s
    raise InvalidUnit, "unidad desconocida: #{unit}" unless UNITS.include?(unit)
    super(amount: Integer(amount), unit:)            # Integer(), no .to_i
  end
end
```

Ambos son "Primitive Obsession" de Fowler resuelto: sumar 5 kg + 3 unidades explota en vez
de dar 8. Verificado:

```bash
$ bin/rails runner 'q = ValueObjects::Quantity.new(amount: 5, unit: "kg")
begin; q + ValueObjects::Quantity.new(amount: 3, unit: "unit"); rescue => e; puts e.class; end'
ValueObjects::Quantity::UnitMismatch
```

⚠️ **La trampa que documenta `money.rb:21-43` y que verifiqué:** las dos formas de
`Data.define` **no son equivalentes**.

```bash
$ ruby -e '
module VO
  Foo = Data.define(:a) do
    class Boom < StandardError; end
  end
end
puts "VO::Boom?      #{VO.const_defined?(:Boom, false)}"
puts "VO::Foo::Boom? #{VO::Foo.const_defined?(:Boom, false)}"'

VO::Boom?      true
VO::Foo::Boom? false
```

El bloque de `Data.define` se evalúa con `class_eval`, y en Ruby las constantes se resuelven
**léxicamente**: por dónde está escrito el código, no por el receptor. La constante aterriza
en `VO`, no en `VO::Foo`. Con la forma de herencia el cuerpo es una definición de clase
normal y todo queda donde esperás — confirmado: la excepción se levanta como
`ValueObjects::Money::CurrencyMismatch`. Java no tiene este problema porque no tiene
`class_eval`.

### 5.2 Pattern matching con `case/in` — los record patterns de Java 21

El caso más completo está en `app/controllers/concerns/api/idempotency.rb:101-127`:

```ruby
case record
in { replay: true, record: IdempotencyKey => stored }
  response.set_header("Idempotent-Replay", "true")
  render json: stored.response_body, status: stored.response_status
in { conflict: true }  then render_error(:idempotency_conflict, "...", status: :conflict)
in { mismatch: true }  then render_error(:idempotency_key_reuse, "...", status: :unprocessable_content)
in { record: IdempotencyKey => fresh }
  yield
  persist_response(fresh)
end
```

Es el `switch` con record patterns de Java 21, con dos diferencias que importan:

- **Matchea estructura, no clase.** `{ replay: true, record: IdempotencyKey => stored }`
  exige que `:replay` valga `true` **y** que `:record` sea un `IdempotencyKey`, y lo liga a
  `stored`. Java necesita tipos sellados declarados de antemano; Ruby matchea sobre hashes
  anónimos.
- **Si ningún patrón matchea, levanta `NoMatchingPatternError`** en vez de devolver `nil`
  como `case/when`. (Cuando lo que falta es una clave del hash, la clase concreta es
  `NoMatchingPatternKeyError`, que hereda de `NoMatchingPatternError` — comprobado, así que
  rescatar la de arriba alcanza.) Es exhaustividad en runtime en vez de en compilación: peor
  que Java, infinitamente mejor que un `if` que se olvida un caso. El comentario de las
  líneas 97-100 lo dice: en una máquina de estados, un estado no contemplado tiene que ser
  **ruidoso**.

Para que un objeto tuyo sea deconstruible alcanzan dos métodos (`app/lib/result.rb:88-91`):

```ruby
def deconstruct_keys(_keys) = { ok: @ok, value: @value, error: @error }
def deconstruct           = [ @ok, @ok ? @value : @error ]
```

Verificado contra la base real. El camino feliz va envuelto en una transacción con
`Rollback` para no dejar un movimiento fantasma en la base de desarrollo (el id que imprime
igual se consume: las secuencias de Postgres no se revierten):

```bash
$ bin/rails runner '
ActiveRecord::Base.transaction do
  r = Stock::Receive.call(product: Product.first, warehouse: Warehouse.first, quantity: 3, user: nil)
  case r
  in { ok: true,  value: } then puts "OK -> #{value.class} id=#{value.id} qty_after=#{value.quantity_after}"
  in { ok: false, error: } then puts "FAIL -> #{error.code}: #{error.message}"
  end
  raise ActiveRecord::Rollback
end'
OK -> StockMovement id=1275108 qty_after=135

$ bin/rails runner 'p Stock::Issue.call(product: Product.first, warehouse: Warehouse.first,
                                        quantity: 999_999, user: nil).error.to_h'
{:code=>:insufficient_stock, :message=>"Stock insuficiente: hay 132, se pidieron 999999",
 :details=>{:available=>132, :requested=>999999, :product_id=>1, :warehouse_id=>1}}
```

`app/models/concerns/has_money.rb:37-46` usa `case/in` como despachador de tipos, que es
literalmente lo que Java resolvería con **sobrecarga de métodos**:

```ruby
case money
in ValueObjects::Money => m then ...   # setter con Money
in Integer => cents        then ...   # setter con centavos
in nil                     then ...
else raise ArgumentError, "#{name}= espera Money o Integer (centavos), recibió #{money.class}"
end
```

### 5.3 Endless methods, hash shorthand, forwarding, rangos, safe navigation

**Endless methods** (3.0) — un método de una sola expresión, sin `end`:

```ruby
def ok? = @ok                                                    # result.rb:56
def available = quantity_available.to_i                          # stock_item.rb:51
def readonly? = persisted?                                       # stock_movement.rb:47
def iso(time) = time&.iso8601(3)                                 # application_serializer.rb:43
def self.digest(raw) = OpenSSL::Digest::SHA256.hexdigest(raw)    # api_token.rb:52
```

**Hash shorthand** (3.1) — si la clave coincide con el nombre de la variable o método,
omitís el valor. Sirve tanto para construir como para pasar argumentos
(`app/services/stock/apply_movement.rb:143-158`):

```ruby
def to_h = { code:, message:, details: }              # result.rb:38
def as_json(*) = { cents:, currency:, formatted: to_s }  # money.rb:94

StockMovement.create!(
  stock_item: item, product_id: item.product_id, warehouse_id: item.warehouse_id,
  user:, kind:, quantity:,                            # <- toma las variables/métodos homónimos
  quantity_after: item.quantity_on_hand,
  unit_cost_cents:, currency: item.product.currency,
  reference:, idempotency_key:, reason:, metadata:, occurred_at: now
)
```

Java no tiene nada parecido; lo más cerca es un builder con nombres repetidos.

**Argument forwarding `(...)`** (2.7, y desde 3.0 admite argumentos antes del `...`) —
reenvía posicionales, keywords y bloque:

```ruby
def call(...) = new(...).call                                    # application_service.rb:56
def call(...) = new(...).call                                    # application_query.rb:24
def self.discrepancies(...) = StockItems::Reconciliation.call(...)  # stock_movement.rb:64
```

Eso permite que **todos** los services se invoquen igual sin que la clase base conozca la
firma de ninguno. En Java necesitarías varargs de `Object` y castear.

**Rangos sin extremo** (2.6/2.7) — ActiveRecord traduce `1..` a `>= 1`, `..0` a `<= 0`:

```ruby
scope :in_stock,     -> { where(quantity_available: 1..) }         # stock_item.rb:40
scope :out_of_stock, -> { where(quantity_available: ..0) }         # stock_item.rb:41
scope :live,         -> { where(expires_at: Time.current..) }      # idempotency_key.rb:14
scope :active,       -> { where(expires_at: Time.current..) }      # session.rb:10
scope :stuck,        -> { pending.where(attempts: MAX_ATTEMPTS..) }# outbox_event.rb:11
relation = relation.where(occurred_at: @from..) if @from           # queries/stock_movements/ledger.rb:54
```

Más legible que `where("quantity_available >= ?", 1)` y —más importante— **no es SQL
crudo**: cero riesgo de inyección y Rails puede seguir componiendo la relación.

**Safe navigation `&.`** — el `?.` de Kotlin:

```ruby
def current_user = @current_api_token&.user            # token_authentication.rb:88
kinds: params[:kinds]&.split(",")                      # api/v1/stock_movements_controller.rb:15
kinds: params[:kind].presence&.then { |k| [ k ] }      # app/controllers/stock_movements_controller.rb:8
```

**Contra `Optional` de Java:** `&.` es más barato (no aloca un wrapper) y más discreto,
pero **no aparece en ninguna firma**. Un método Ruby no te dice si puede devolver `nil`;
`Optional<Product>` sí. Es el trade-off central de Ruby: menos ceremonia, menos garantías.
Esa última línea es
`Optional.ofNullable(x).filter(not(String::isBlank)).map(List::of)` en 30 caracteres.

**`frozen_string_literal`** — comentario mágico, en las primeras líneas, **por archivo**. No
hay flag global equivalente. Comprobado: sin el comentario `"lit".frozen? # => false`; con
él, `true`.

---

## 6. Lo que Ruby no tiene y vas a extrañar

| Java | Ruby | Qué hacés en su lugar |
|---|---|---|
| Tipos estáticos | ✗ | RBS (oficial, `.rbs` aparte + `steep`) o Sorbet (`sig` inline, de Stripe). **Ninguno se usa acá.** |
| Compilador | ✗ | RuboCop (estilo y algunos errores), Brakeman (seguridad), y **tests** |
| `interface` | ✗ | Duck typing + tests compartidos (`app/services/outbox/publisher.rb:11-14`) |
| Sobrecarga de métodos | ✗ | Keyword args con defaults, o `case/in` sobre el tipo (`has_money.rb:37-46`) |
| `private` real | ✗ | Sólo prohíbe el receptor explícito (`self.` está permitido desde 2.7); `obj.send(:m)` lo saltea siempre |
| `final` / `sealed` | ✗ | `freeze` (superficial) y disciplina |
| Genéricos | ✗ | No hacen falta sin tipos; sí los extrañás leyendo código ajeno |
| Excepciones checked | ✗ | **Todas** son unchecked → ver abajo |

**Sobre `private`.** No es encapsulamiento real, es una convención con soporte del
intérprete. El repo lo aprovecha en `app/models/api_token.rb:46`:

```ruby
token.instance_variable_set(:@plaintext, raw)
```

Le setea una variable de instancia a otro objeto desde afuera. En Java es
`setAccessible(true)`; en Ruby es una línea normal. El poder es real y el riesgo también.

**Sobre las excepciones.** Como todas son unchecked, nada en la firma te dice qué puede
fallar. La respuesta del repo (`app/lib/result.rb:6-20`) es una regla explícita:

- **Falla esperada** (regla de negocio: no hay stock, producto inactivo) → `Result.failure`.
  Es un valor, viaja en el retorno, el que llama no lo ignora sin querer.
- **Falla inesperada** (bug o infraestructura) → excepción. Que explote, que la vea el error
  tracker, que dispare el retry del job.

Es `Either` de Vavr, hecho a mano en 100 líneas.

---

## 7. Concurrencia: el GVL contra los threads de la JVM

### 7.1 Los threads son del SO, pero sólo uno ejecuta Ruby

CRuby tiene un **GVL** (Global VM Lock): un mutex global por proceso que hay que tener para
ejecutar bytecode Ruby. Los `Thread` son pthreads de verdad —no green threads— pero se
turnan. El GVL **se libera** durante I/O bloqueante y en extensiones C que lo sueltan (el
driver `pg` lo suelta mientras espera a Postgres). Medición real en esta máquina (4 cores),
con `(1..12_000_000).reduce(:+)` como carga CPU y `sleep 0.5` como I/O, 4 tandas:

```text
secuencial CPU : 2.37s
4 threads CPU  : 2.41s      <- CERO ganancia. Y encima un poco peor.
secuencial IO  : 2.00s
4 threads IO   : 0.50s      <- 4x. Escala perfecto.
```

Ese es el resumen: **CPU-bound** → los threads no dan nada (en la JVM, 4 threads en 4 cores
te darían ~4x). **I/O-bound** → escalan igual que en la JVM. Y una app Rails es 80-95% I/O.

### 7.2 Qué significa para Puma

Puma es multi-proceso **y** multi-thread: N `workers` (procesos forkeados, un GVL cada uno)
× M `threads`. `config/puma.rb:28-29`:

```ruby
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count
```

El default de Rails 8 es **3**, y el comentario del archivo (líneas 16-23) explica por qué
es bajo: más threads suben el throughput pero degradan la **latencia**, porque se pelean
por el intérprete.

| Tomcat / Undertow | Puma |
|---|---|
| 1 JVM, 200 threads en el pool | N procesos × 3-5 threads |
| Memoria compartida entre threads | Compartida **dentro** del worker; separada entre workers |
| Escalás subiendo threads | Escalás subiendo **workers** |
| Un `static` es global a la app | Un `@@var` es global **al proceso**, no a la app |
| `ThreadLocal` | `Thread.current[]` o `ActiveSupport::CurrentAttributes` |
| Caché en memoria = 1 copia | Caché en memoria = **N copias**, una por worker |

La última fila es el error de escalado #1 del javero que llega a Rails: poner un
`MemoryStore` como store de rate limiting y descubrir que con 4 workers el límite de 100 se
volvió 400, inconsistente. Este repo lo evita usando Redis o Solid Cache
(`app/controllers/api/v1/base_controller.rb:46-57`).

### 7.3 El pool de conexiones se multiplica

`config/database.yml:10-27` lo dice sin vueltas: **el pool es por proceso**.

```text
3 workers × 5 threads = 3 pools de 5 = 15 conexiones desde UNA máquina
× 4 bases de Rails 8 (primary, cache, queue, cable) = hasta 60 por máquina
```

Contra el `max_connections` de Postgres (default 100), multiplicado por la cantidad de pods.
Ahí aparece `PG::ConnectionBad: FATAL: sorry, too many clients already`. Regla dura:
`max_connections` del pool **>=** `RAILS_MAX_THREADS`; si es menor, ves
`ActiveRecord::ConnectionTimeoutError`. A escala, PgBouncer en transaction pooling.

### 7.4 Estado por request: `CurrentAttributes`, no `ThreadLocal`

`app/models/current.rb:17-26`:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :api_token
  attribute :request_id
  attribute :user_agent
  attribute :ip_address

  def user = session&.user || api_token&.user
end
```

Es un singleton por thread/fiber que **Rails resetea automáticamente** al final de cada
request y de cada job. Esa garantía de reset es toda la diferencia con un `ThreadLocal` a
mano: en un pool de threads, si no limpiás, la request N+1 hereda los datos de la N — fuga
de datos entre usuarios, y en Java te pasa igual sin `remove()` en un `finally`.

La regla del archivo (líneas 12-15) conviene repetirla en una entrevista: guardá ahí **sólo
contexto transversal** (usuario, request_id, IP). Usarlo para pasar parámetros de negocio
entre capas es el mismo abuso que hacerle `static` a todo.

### 7.5 Ractors y Fibers

**Ractor** (3.0, experimental todavía en 3.3) es paralelismo real: un GVL por Ractor.
Funciona (`Ractor.new { 2 + 2 }.take # => 4`), pero los objetos no se comparten: se copian o
se mueven, y sólo pasan gratis los "shareable" (congelados y profundamente inmutables). En
la práctica **ActiveRecord no anda dentro de un Ractor**, ni la mayoría del ecosistema. Hoy
no es una opción para Rails.

**Fiber** es concurrencia **cooperativa**: corrutinas que ceden control
(`f = Fiber.new { Fiber.yield 1; 2 }` → `f.resume` da 1, después 2). Desde Ruby 3.0 hay
`Fiber::Scheduler`, que hace que el I/O bloqueante ceda el fiber automáticamente: es la base
del gem `async` y del servidor Falcon, y el equivalente conceptual de las **virtual threads
de Java 21 (Loom)** — con la diferencia enorme de que en Java son transparentes y el
ecosistema entero las soporta, mientras que acá hay que optar y muchas gemas no están
adaptadas.

### 7.6 Por qué "más threads" no acelera

Tres cuellos, en orden: el **GVL** (§7.1), el **pool** (§7.3: con `RAILS_MAX_THREADS=20` y
pool de 5, 15 threads esperan y después revientan) y **Postgres** (200 conexiones concurrentes
no lo hacen ir más rápido, lo hacen pelearse consigo mismo). Cuando algo va lento la respuesta
es **medir** — el repo trae `rack-mini-profiler`, `stackprof` y `memory_profiler` en
`:development` — no subir `RAILS_MAX_THREADS`.

---

## 8. Memoria y GC

| | Ruby 3.3 | G1 / ZGC |
|---|---|---|
| Algoritmo | Mark & sweep generacional (2 gen.), marcado incremental, barrido perezoso | Regiones, concurrente, copiante |
| ¿Mueve objetos? | **No** por defecto (`GC.compact` es manual) | Sí, siempre |
| Fragmentación | Real; se combate con jemalloc | El copiado la elimina |
| Tuning | Env vars (`RUBY_GC_HEAP_GROWTH_FACTOR`, …) | Decenas de flags `-XX:` |
| Heap máximo | **No existe `-Xmx`**: crece hasta que el SO diga basta | `-Xmx` es un techo duro |

Esa última fila es la que más sorprende. Si tu app tiene un leak, el proceso crece hasta que
el OOM killer lo mata. La contramedida en producción es un supervisor que reinicie workers
por RSS (`puma-worker-killer`, o el límite del contenedor).

Números reales de este repo:

```bash
$ ruby -e 'puts File.read("/proc/self/status")[/VmRSS:\s+(\d+)/,1].to_i / 1024'
18                       # Ruby pelado: 18 MB
$ bin/rails runner '...'
RSS = 94 MB              # Rails booteado, entorno de desarrollo
objetos vivos: ~265 000 ; GC count: 35 ; clases cargadas: 4 649
```

(`objetos vivos` es `GC.stat[:heap_live_slots]` y baila unos miles entre corridas; `clases`
es `ObjectSpace.each_object(Class).count` — si contás `Module` en vez de `Class` te da 5 684,
que es el número que la gente suele citar sin darse cuenta.)

94 MB **por worker de Puma**, antes de servir una request. Con 4 workers son ~376 MB de piso.
Una JVM de Spring Boot arranca más pesada, pero todos los threads comparten ese costo; en
Ruby lo pagás N veces, salvo por copy-on-write.

**Copy-on-write y `preload_app!`.** Puma en modo cluster **forkea**: con `preload_app!` la app
se carga una vez en el master y los hijos heredan las páginas; el SO copia sólo al escribir.
El ahorro se degrada porque el propio GC, al marcar, escribe en los headers y ensucia páginas
compartidas — Ruby 2.0 introdujo *bitmap marking* (los bits viven aparte) para mitigarlo, y
por eso se recomienda `GC.compact` antes del fork. Java no tiene este problema porque no
forkea: un proceso, muchos threads, un heap.

**El "bloat" de Puma y jemalloc.** Síntoma clásico: el RSS sube y **no baja** aunque
`GC.stat[:heap_live_slots]` esté estable. No es un leak de objetos Ruby, es
**fragmentación del allocator de C**: `malloc` de glibc crea una arena por thread (hasta
8× cores) y la memoria liberada queda en huecos que nunca vuelven al SO. Dos arreglos, una
línea cada uno:

```bash
export MALLOC_ARENA_MAX=2                                        # gratis, ~20-30% menos RSS
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2     # jemalloc fragmenta mucho menos
```

Este intérprete está compilado contra el malloc del sistema
(`RbConfig::CONFIG["MAINLIBS"]` → `-lz -lrt -lrt -ldl -lcrypt -lm -lpthread`, sin
`-ljemalloc`). La imagen oficial de Ruby y el `Dockerfile` que genera Rails 8 suelen traer
jemalloc justamente por esto.

---

## 9. Ecosistema: gem/bundler vs maven/gradle

| Maven / Gradle | Bundler / RubyGems | Diferencia que importa |
|---|---|---|
| `pom.xml` | `Gemfile` | Es **código Ruby**, se evalúa (podés poner `if`) |
| `~/.m2` | `~/.gem` o `vendor/bundle` | |
| `dependency:tree` resuelto | `Gemfile.lock` | Se commitea **siempre**, es autoritativo |
| `<scope>compile/test/provided` | `group :development, :test` | La app elige qué grupos carga |
| Classpath | `$LOAD_PATH` + `require` | **No hay classpath**, ver §10.2 |
| Shading / relocación | ✗ | Los monkey patches son globales, no hay aislamiento |
| `[1.0,2.0)` | `~> 1.5` ("pessimistic") | `~> 1.5` = `>= 1.5, < 2.0`; `~> 1.5.3` = `>= 1.5.3, < 1.6` |
| SDKMAN / jenv | rbenv / chruby / mise | Acá hay 3.1.6, 3.2.6 y 3.3.6 instaladas |

El `Gemfile:6-18` de este repo trae el mapeo comentado. Ejemplos de restricciones reales:

```ruby
gem "rails", "~> 8.1.3", ">= 8.1.3.1"   # dos restricciones combinadas
gem "pg", "~> 1.5"                       # cualquier 1.x >= 1.5
```

Y el lock resuelto incluye **la versión de Ruby y la de Bundler** — más estricto que un
`pom.xml`:

```text
    pg (1.6.3)   puma (8.0.2)   rails (8.1.3.1)   sidekiq (8.1.7)
RUBY VERSION      ruby 3.3.6
BUNDLED WITH      4.0.9
```

Las gemas con extensiones nativas (`pg`) aparecen con una línea por plataforma
(`x86_64-linux`, `arm64-darwin`, `x86_64-linux-musl`…): el equivalente a los classifiers.

**`require: false`** (`Gemfile:12-16`) significa "instalala pero **no la cargues** al
bootear". Se usa para herramientas de línea de comandos (`brakeman`, `rubocop`) que no
tienen por qué estar dentro del proceso de la app: cada gema cargada suma RAM y tiempo de
boot a **todos** los procesos (web, worker, consola). No hay equivalente directo en Maven.
Quién dispara la carga: `Bundler.require(*Rails.groups)` en `config/application.rb:19`.

**rbenv** funciona con *shims*: binarios falsos en el `PATH` que resuelven la versión leyendo
`.ruby-version` del directorio actual. Cambiar de proyecto cambia el Ruby, sin `sdk use`, y
la versión es parte del repo (está commiteada), no de tu shell. `bundle exec <cmd>` es el
equivalente de correr con el classpath exacto del lock.

---

## 10. Rails vs Spring Boot

### 10.1 Convención sobre configuración, al extremo

Spring Boot autoconfigura pero seguís declarando: `@Entity`, `@Table`, `@Column`,
`@RestController`. Rails no declara casi nada:

```ruby
class StockItem < ApplicationRecord
  belongs_to :product
end
```

De eso deduce: tabla `stock_items`, PK `id`, columnas leídas del esquema al bootear con sus
accessors, FK `product_id`, clase asociada `Product`. Cero anotaciones. El precio: para
salirte de la convención tenés que saber **cuál era** — `app/models/product.rb:20-22` pasa
`class_name:`, `inverse_of:` y `dependent:` explícitos porque el nombre no la sigue.

### 10.2 Zeitwerk vs classpath scanning

**En Ruby no hay classpath.** Hay `$LOAD_PATH` y `require`, que carga un archivo por ruta.
Rails pone encima **Zeitwerk**: mapea nombre de constante ↔ ruta por convención usando
`autoload` del intérprete (perezoso, no escanea nada).

```bash
$ bin/rails runner 'puts Rails.autoloaders.main.dirs.sort
                        .map { |d| d.sub(Rails.root.to_s + "/", "") }'
app/channels  app/controllers  app/controllers/concerns  app/events  app/forms
app/helpers  app/jobs  app/lib  app/mailers  app/models  app/models/concerns
app/policies  app/queries  app/serializers  app/services  lib
...y los app/ de las gemas-engine (activestorage, solid_queue, mission_control-jobs…)
```

La regla: **cada root es la raíz del namespace, no un segmento de él.**

| Archivo | Constante | Por qué |
|---|---|---|
| `app/lib/result.rb` | `Result` | `app/lib` es root ⇒ no es `Lib::Result` |
| `app/models/value_objects/money.rb` | `ValueObjects::Money` | `value_objects/` sí es un segmento |
| `app/models/concerns/discardable.rb` | `Discardable` | `app/models/concerns` **también** es root |
| `app/controllers/concerns/api/idempotency.rb` | `Api::Idempotency` | idem |

```bash
$ bin/rails runner 'Result; ValueObjects::Money
puts Object.const_source_location("Result").inspect
puts Object.const_source_location("ValueObjects::Money").inspect'
["/home/user/stock/app/lib/result.rb", 32]
["/home/user/stock/app/models/value_objects/money.rb", 45]
```

Diferencias con Java que hay que tener claras:

- **En desarrollo recarga.** `config.eager_load` es `false` en dev (comprobado), así que al
  editar un archivo la constante se descarta y se vuelve a cargar sin reiniciar: JRebel gratis.
- **En producción `eager_load = true`:** todo se carga al bootear, los errores de nombres
  aparecen en el arranque y las páginas quedan listas para el CoW del fork.
- **Nunca hay dos versiones de la misma clase.** Sin classloaders, sin jar hell. A cambio,
  tampoco podés aislar nada.

### 10.3 No hay contenedor de DI, y no hace falta

La respuesta no es "Ruby no necesita DI". **Sí necesita inversión de dependencias**; lo que no
necesita es un *contenedor* — que en Java existe porque armar el grafo a mano es inviable
(constructores largos, resolución por tipo, scopes, ciclos de vida). Ruby lo resuelve con
**argumentos por nombre y valores por defecto** (`app/services/stock/apply_movement.rb:42-45`):

```ruby
def initialize(stock_item:, kind:, quantity:, reserved_delta: 0,
               user: nil, reference: nil, reason: nil, unit_cost_cents: nil,
               idempotency_key: nil, occurred_at: nil, metadata: {},
               event_recorder: Outbox::Recorder.new, clock: Time)
```

Las dos últimas son **dependencias inyectadas** con un default sensato: en producción no
escribís nada extra, en un test inyectás un recorder que acumula en un array y un reloj
congelado. Es `@Autowired` + `@MockBean` sin XML, sin `@Configuration`, sin proxies, sin un
contexto que arranque en 8 segundos.

El "registro de beans" cuando hace falta es un `Hash` congelado
(`app/services/outbox/publisher.rb:17-28`):

```ruby
ADAPTERS = { "log" => -> { LogAdapter.new }, "noop" => -> { NoopAdapter.new }, ... }.freeze

def self.build(name = ENV.fetch("OUTBOX_ADAPTER", "log"))
  ADAPTERS.fetch(name) { raise ArgumentError, "Adapter de outbox desconocido: #{name}" }.call
end
```

Un `Map<String, Supplier<Publisher>>` en doce líneas, y el error de configuración es
explícito en vez de un `NoSuchBeanDefinitionException`.

### 10.4 Middleware Rack = FilterChain de Servlet

Rack es la interfaz mínima entre servidor y app: un objeto que responde `call(env)` y
devuelve `[status, headers, body]`. Se apilan como capas de cebolla y cualquiera puede cortar
la cadena. Es `javax.servlet.Filter` con menos ceremonia.

```bash
$ bin/rails middleware
...
use ActionDispatch::RemoteIp
use Rack::Attack                      # <- insertado por config/application.rb:52
use Propshaft::QuietAssets
...
use Rack::TempfileReaper
use Rack::Attack                      # <- insertado por el railtie de la gema
use Bullet::Rack
run Stock::Application.routes
```

`config/application.rb:52` hace `insert_after ActionDispatch::RemoteIp, Rack::Attack`, y el
motivo está en las líneas 33-51: en la posición 0 correría **antes** de `RemoteIp` y
`request.ip` sería la IP del load balancer, así que todos tus usuarios compartirían un
contador.

⚠️ **Mirá el resultado real: `Rack::Attack` aparece DOS VECES.** La segunda la agrega el
railtie de la gema (`rack-attack-6.8.0/lib/rack/attack/railtie.rb`, que hace
`app.middleware.use(Rack::Attack)`); el `insert_after` de la app no reemplaza esa inserción,
la suma.

El instinto dice "entonces cada request pasa por el throttle dos veces y todos los contadores
se incrementan el doble". **Lo medí y es falso**, y el porqué es la parte que vale: la gema es
idempotente a propósito. `rack-attack-6.8.0/lib/rack/attack.rb:104-107` arranca así:

```ruby
def call(env)
  return @app.call(env) if !self.class.enabled || env["rack.attack.called"]

  env["rack.attack.called"] = true
```

La primera instancia marca el `env`; la segunda se ve marcada y pasa de largo. Comprobado
empujando 3 requests por el stack completo con `Rack::MockRequest`, con un `alias` sobre
`Rack::Attack#call` para ver cada pasada, y leyendo después el contador del store:

```text
>> Rack::Attack#call (rack.attack.called=nil)    <- hace el trabajo
>> Rack::Attack#call (rack.attack.called=true)   <- no-op
   (idem para las requests 2 y 3)
CONTADOR req/ip tras 3 requests = 3              <- 3, no 6
```

O sea: el duplicado **no rompe los límites**, pero sí es basura en la cadena — un frame de
Rack por request y una trampa para el que lea `bin/rails middleware` y saque la conclusión
apurada. Vale sacarlo:

```ruby
config.middleware.delete Rack::Attack
config.middleware.insert_after ActionDispatch::RemoteIp, Rack::Attack
```

La lección transferible, y la respuesta buena en una entrevista: **un middleware que se puede
montar dos veces tiene que ser idempotente**, y la marca en el `env` es el patrón estándar
para lograrlo — es literalmente lo que hace `OncePerRequestFilter` de Spring con un atributo
del request. Cuando el componente *no* trae esa guarda, el doble conteo sí ocurre: es el caso
del `rate_limit` nativo de Rails sin `name:` que documenta
`app/controllers/api/v1/base_controller.rb:59-74`.

### 10.5 ActiveRecord vs JPA: **acá se rompe la analogía**

Esta es la sección que más cuesta, porque todo *parece* familiar y no lo es. ActiveRecord es
el patrón Active Record de Fowler; JPA es Data Mapper con Unit of Work. Son cosas distintas.
**No hay `EntityManager`, no hay persistence context, no hay identity map.** Verificado:

```bash
$ bin/rails runner '
p1 = Product.first
p1.name = "OTRO NOMBRE"
puts "changed? #{p1.changed?} / changes: #{p1.changes.inspect}"
p2 = Product.find(p1.id)
puts "mismo objeto? #{p1.equal?(p2)} ; == ? #{p1 == p2}"
puts "nombre en p2: #{p2.name}"'

changed? true / changes: {"name"=>["Tornillo métrica 5 x 20mm", "OTRO NOMBRE"]}
mismo objeto? false ; == ? true
nombre en p2: Tornillo métrica 5 x 20mm
```

Leelo tres veces:

1. El dirty tracking **existe** (`changed?`, `changes`) pero es **local al objeto y
   sincrónico**. No hay flush diferido: nada se va a escribir solo.
2. `Product.find(p1.id)` devolvió un **objeto distinto** con el valor **viejo**. En JPA,
   dentro de la misma transacción, te habría devuelto la *misma* instancia gestionada con el
   cambio pendiente.
3. `==` da `true` porque ActiveRecord lo define como "misma clase y mismo `id`". Confunde:
   son iguales pero no son el mismo objeto y no comparten estado.

| JPA / Hibernate | ActiveRecord |
|---|---|
| `EntityManager` con persistence context | **No existe** |
| Identity map (1 instancia por PK por sesión) | **No existe**: cada `find` construye un objeto nuevo |
| Dirty checking en el **flush** | Dirty tracking inmediato, pero **no escribe nada solo** |
| `flush()` automático antes de una query | **Nunca**: `save!` emite el `UPDATE` en el acto |
| Lazy loading con proxies + `LazyInitializationException` | Asociación no cargada ⇒ **hace la query** ⇒ N+1 silencioso |
| `@Version` | Columna `lock_version` por convención (`app/models/stock_item.rb:22`) |
| Cascade + orphan removal | `dependent: :destroy / :restrict_with_error / :nullify` |
| Cache de 2º nivel | No hay; se usa `Rails.cache` a mano |
| Query cache de la sesión | Query cache **por request**, y muerde (`app/models/sequence_counter.rb:25-49`) |

Tres consecuencias prácticas:

- **Si no llamás `save!`, no se guarda.** Un javero acostumbrado a mutar una entidad
  gestionada y confiar en el flush pierde el cambio.
- **Dos instancias del mismo registro se pisan.** Por eso el dominio bloquea la fila
  explícitamente antes de leer y escribir: `StockItem.lock.find(id)` ⇒ `SELECT … FOR UPDATE`
  (`app/services/stock/apply_movement.rb:102-104`).
- **Las columnas calculadas por la base no se actualizan solas en memoria**
  (`app/services/stock/apply_movement.rb:132-140`):

```ruby
def apply_to(item)
  item.quantity_on_hand  += quantity
  item.quantity_reserved += reserved_delta
  item.last_movement_at   = now
  item.save!
  item.reload   # Postgres calculó quantity_available (columna generada); el objeto no lo sabe
end
```

En JPA se resuelve con `@Generated` + `refresh()`; acá hay que hacerlo a mano.

---

## 11. Herramientas del día a día

**`bin/rails console`** — el REPL contra la base real, con toda la app cargada: probás un
query object, mirás el SQL que genera, llamás a un service, inspeccionás un `Result`. Todo
este documento se verificó así. `bin/rails console --sandbox` abre una transacción al arrancar
y hace `ROLLBACK` al salir — la forma de tocar producción sin romper nada. No hay equivalente
en Java: `jshell` no tiene tu contexto de Spring cargado y un `@SpringBootTest` no es
interactivo.

**`bin/rails runner`** — `java -cp app.jar com.foo.Main` sin escribir un `Main`. Para
backfills, cron simples y verificar afirmaciones:
`bin/rails runner 'puts StockItem.ancestors.first(3).inspect'`.

**El debugger** — el gem `debug` (default gem desde Ruby 3.1) está en el `Gemfile:139` con
`require: "debug/prelude"`. Poné `binding.break` y el proceso para con un REPL completo:
`n`/`s`/`fin` son step over/into/out, y remoto es `rdbg --open --port 12345 -- bin/rails s`.
La ventaja que Java no tiene: en el breakpoint no evaluás expresiones en una caja aparte,
**estás en el proceso** — podés redefinir un método o mutar el objeto.

**`bin/rails routes`** — 127 líneas en esta app (2 de encabezado, 125 rutas), cuatro columnas:
helper, verbo, patrón, `controller#action`. Es el mapa de endpoints centralizado que en Spring
reconstruís leyendo `@RequestMapping` desperdigados o mirando `/actuator/mappings`.

```text
api_v1_stock_receive POST /api/v1/stock/receive(.:format)  api/v1/stock_operations#receive {:format=>:json}
  api_v1_stock_issue POST /api/v1/stock/issue(.:format)    api/v1/stock_operations#issue   {:format=>:json}
 api_v1_stock_adjust POST /api/v1/stock/adjust(.:format)   api/v1/stock_operations#adjust  {:format=>:json}
```

El `(.:format)` no es adorno: es el segmento opcional que hace que `/products/1.json` y
`/products/1` peguen en la misma acción.

**`bin/rails middleware`** — el `/actuator/mappings` de los filtros: el orden exacto de la
cadena. Cada vez que un middleware "no anda", el primer comando es este (§10.4).

| Java | Este repo |
|---|---|
| Checkstyle / Spotless | `bin/rubocop` (preset `rubocop-rails-omakase`) |
| SpotBugs / Find-Sec-Bugs | `bin/brakeman` |
| OWASP dependency-check | `bin/bundler-audit` |
| JaCoCo | `simplecov` |
| WireMock | `webmock` + `vcr` |
| Object Mothers / builders | `factory_bot` |
| Quartz + su consola | Solid Queue + `mission_control-jobs` |
| Flyway / Liquibase | `db/migrate` + `strong_migrations` |

---

## Errores que ves en producción

**1. Mutar un literal de string con `frozen_string_literal: true`.** *Síntoma:*
`FrozenError: can't modify frozen String`, sólo en algunos archivos (acá: 97 de 103 lo
tienen). *Arreglo:* `+"texto"`
(unary plus) o `String.new`; mejor todavía, no mutes strings.

**2. `.to_i` sobre entrada del usuario.** *Síntoma:* `"abc".to_i == 0` y
`"10 unidades".to_i == 10`; un movimiento con la cantidad equivocada y ningún error.
*Arreglo:* `Integer(params[:quantity])`, que levanta `ArgumentError`. Ver
`app/controllers/api/v1/stock_operations_controller.rb:90-98`.

**3. `^` y `$` en un regex de validación.** *Síntoma:* pasa un valor con `\n` y payload
después: `/^[A-Z0-9]+$/` acepta `"VALIDO\n<script>alert(1)</script>"`, porque **en Ruby
`^`/`$` son principio/fin de LÍNEA**, no de input (en Java son de input). *Arreglo:* `\A` y
`\z` siempre. Ver `app/models/product.rb:32-50`; Brakeman lo marca solo.

**4. `return` adentro de un bloque `transaction`.** *Síntoma:* la transacción **commitea** lo
que ya escribió en vez de revertir (cambió en Rails 7 y rompió código en silencio).
*Arreglo:* `next` para salir del bloque, o una excepción propia que viaje hasta el rescue.
Ver `app/services/application_service.rb:33-53` y el `next success(existing)` de
`app/services/stock/apply_movement.rb:66`.

**5. `raise ActiveRecord::Rollback` en una transacción anidada.** *Síntoma:* se traga la
excepción y **no** revierte la de afuera (Rails anida sin savepoint salvo
`requires_new: true`). *Arreglo:* el mismo de arriba.

**6. Esperar el flush automático de JPA.** *Síntoma:* mutás un objeto, la request termina, el
cambio nunca llegó a la base. *Arreglo:* ActiveRecord no tiene unit of work; `save!` /
`update!` explícito.

**7. Leer una columna generada sin `reload`.** *Síntoma:* `quantity_available` en memoria
tiene el valor previo al `save!` y el evento sale con datos viejos. *Arreglo:* `item.reload`
(`app/services/stock/apply_movement.rb:132-140`).

**8. Query cache devolviendo el mismo número de secuencia.** *Síntoma:* dos comprobantes con
el mismo número: el `INSERT … RETURNING` se ejecutó con `select_value`, así que para Rails es
un SELECT y lo cachea por request. *Arreglo:* `connection.uncached { … }` +
`clear_query_cache`. Documentado en `app/models/sequence_counter.rb:25-49`, y **no aparece en
un test unitario** porque el cache está apagado fuera del executor.

**9. `find_or_create_by!` bajo concurrencia.** *Síntoma:* `RecordNotUnique` esporádico: dos
requests pasan el `find` a la vez. *Arreglo:* confiar en el índice único y rescatar el choque
(`app/models/stock_item.rb:116-126`, `find_or_provision!`).

**10. `MemoryStore` como store de rate limiting o caché con varios workers.** *Síntoma:* el
límite de 100 corta cerca de 400, inconsistente: cada proceso tiene su contador. *Arreglo:*
Redis o Solid Cache (`app/controllers/api/v1/base_controller.rb:46-57`).

**11. Dos declaraciones de rate limit que comparten clave.** *Síntoma:* un límite de 20 corta
en 10, porque cada request incrementa el mismo contador dos veces. Pasa con el `rate_limit`
nativo de Rails sin `name:`, porque la clave es
`["rate-limit", scope, name, by].compact.join(":")` y sin `name` las dos declaraciones la
arman igual (verificado y documentado en `app/controllers/api/v1/base_controller.rb:59-74`).
*Arreglo:* `name:` distinto por límite. *Falso positivo relacionado:* `bin/rails middleware`
muestra `Rack::Attack` dos veces en esta app y **no** duplica los contadores — la gema se
protege con `env["rack.attack.called"]` (§10.4). Sacá igual el duplicado, pero no lo
diagnostiques como doble conteo sin medirlo.

**12. Pool de conexiones menor que `RAILS_MAX_THREADS`.** *Síntoma:*
`ActiveRecord::ConnectionTimeoutError` bajo carga; o, del otro lado,
`FATAL: sorry, too many clients already` por multiplicar workers × threads × bases.
*Arreglo:* `max_connections >= RAILS_MAX_THREADS`, contar las 4 bases de Rails 8, PgBouncer a
escala (`config/database.yml:10-27`).

**13. Subir `RAILS_MAX_THREADS` para acelerar trabajo CPU-bound.** *Síntoma:* la latencia p99
empeora y el throughput no sube. *Arreglo:* el GVL; más **workers**, no más threads (medido:
2.41s con 4 threads vs 2.37s secuencial).

**14. RSS que crece y nunca baja con el heap estable.** *Síntoma:* `heap_live_slots` plano,
`VmRSS` en subida. No es un leak: es fragmentación de `malloc`. *Arreglo:*
`MALLOC_ARENA_MAX=2` o jemalloc vía `LD_PRELOAD`.

**15. `default_scope { kept }` para el soft delete.** *Síntoma:* `Product.count` miente, el
scope se cuela en joins y asociaciones, y `unscoped` te vuela también el `order` y los
`where` del join. *Arreglo:* scopes explícitos (`Product.kept`): la trampa está explicada en
`app/models/concerns/discardable.rb:10-17` y los scopes se definen en las líneas 29-30.

**16. N+1 adentro de una validación.** *Síntoma:* un `valid?` que hace 500 queries. Es el N+1
más invisible que existe porque nadie mira el SQL de una validación. *Arreglo:* precargar en
un `Hash` con una query (`app/forms/stock_transfer_form.rb:29-37`).

**17. Claves String vs Symbol en un `Hash`.** *Síntoma:* `h["sku"] # => nil` cuando el hash
tiene `:sku`; típico al mezclar `params` (indifferent access) con `JSON.parse` (String) o un
hash literal (Symbol). *Arreglo:* `symbolize_keys` en el borde
(`app/forms/stock_transfer_form.rb:26`).

---

## Cómo responder esto en una entrevista

**1. "¿Qué diferencia hay entre ActiveRecord y JPA/Hibernate?"**
ActiveRecord es el patrón Active Record: el objeto sabe persistirse. JPA es Data Mapper con
Unit of Work. Concretamente: ActiveRecord **no tiene** persistence context, ni identity map,
ni flush diferido. `save!` emite el `UPDATE` en el acto; si no lo llamás, no se guarda. Dos
`find` del mismo id devuelven objetos distintos que se pueden pisar, y por eso las escrituras
concurrentes necesitan `SELECT … FOR UPDATE` o lock optimista con `lock_version`. El dirty
tracking existe pero es local al objeto y sincrónico.
*Trade-off:* mucho menos framework y ninguna `LazyInitializationException`, a cambio de que
el control de concurrencia es tuyo, y de que una asociación no cargada dispara una query en
vez de fallar — N+1 silenciosos en vez de errores ruidosos.

**2. "¿Rails necesita un contenedor de inyección de dependencias?"**
Necesita **inversión** de dependencias, no un contenedor. En Java el container existe porque
armar el grafo a mano es inviable. En Ruby alcanza con argumentos por nombre y defaults:
`def initialize(..., event_recorder: Outbox::Recorder.new, clock: Time)`. En producción usa
el default; en tests inyectás un doble y un reloj congelado. Cuando hace falta un registro de
beans, es un `Hash` congelado de lambdas.
*Trade-off:* boot instantáneo, cero magia, stack traces reales; a cambio no tenés scopes
declarativos ni un grafo inspeccionable, y en una app muy grande el cableado manual se vuelve
repetitivo.

**3. "Contame el GVL y qué implica para Puma."**
CRuby tiene un mutex global: sólo un thread ejecuta bytecode Ruby a la vez. Los threads son
del SO, no green threads, y el GVL **se libera** en I/O. Lo medí: 4 threads CPU-bound tardan
lo mismo que secuencial (2.41s vs 2.37s); 4 threads I/O-bound escalan 4x (0.50s vs 2.00s).
Como una app Rails es 80-95% I/O, el modelo de threads funciona igual. Se escala con
**procesos** (workers), no con threads: el default de Rails 8 es 3 porque más threads suben
throughput y degradan latencia.
*Trade-off:* pagás la memoria N veces (mitigado por copy-on-write con `preload_app!`) y el
pool de conexiones se multiplica por proceso — de ahí el
`FATAL: sorry, too many clients already` clásico.

**4. "¿Cómo manejás errores sin excepciones checked?"**
Con una regla explícita, porque el lenguaje no la impone. Falla **esperada** (regla de
negocio) → un objeto `Result` con `code`, `message` y `details`, componible con
`then_try`/`map` y consumible con pattern matching. Falla **inesperada** (bug o
infraestructura) → excepción, que explota, la ve el error tracker y dispara el retry del job.
Es `Either` de Vavr hecho a mano en 100 líneas (`app/lib/result.rb`).
*Trade-off:* el camino de error queda explícito y testeable, pero nadie te obliga a respetar
la convención: sin compilador, la disciplina la sostienen el code review y los tests.

**5. "¿Qué es Zeitwerk y en qué se diferencia del classpath?"**
En Ruby no hay classpath: hay `$LOAD_PATH` y `require` de archivos. Zeitwerk mapea constante
↔ ruta por convención usando `autoload`, así que es perezoso y no escanea al arrancar. Cada
directorio raíz es la **raíz del namespace**: por eso `app/lib/result.rb` define `Result` y
no `Lib::Result`, y `app/models/value_objects/money.rb` define `ValueObjects::Money`. En
desarrollo recarga sin reiniciar; en producción `eager_load = true` carga todo al bootear,
así los errores de nombres aparecen en el arranque y las páginas quedan compartidas para el
fork.
*Trade-off:* jamás vas a tener dos versiones de una clase ni jar hell, pero tampoco podés
aislar nada — un monkey patch de una gema es global al proceso y gana el último cargado.

**6. "¿Qué features de Ruby 3 usarías y por qué?"**
`Data.define` para value objects inmutables (el `record` de Java 16, con `with` de regalo).
`case/in` para pattern matching estructural, más flexible que los record patterns de Java 21
porque matchea hashes anónimos, y que **levanta `NoMatchingPatternError`** si nada encaja en
vez de devolver `nil`. `deconstruct_keys` para que tus objetos sean matcheables. Endless
methods y hash shorthand para bajar el ruido. `frozen_string_literal: true` en todos los
archivos: medido, baja de 100.000 a 27 las allocaciones en 100k iteraciones. Y `(...)` para
forwarding, que permite el `def call(...) = new(...).call` compartido por todos los services.
*Trade-off:* todo esto es Ruby 3.2+; si el equipo mantiene apps viejas, la mitad no corre. Y
`Data.define` con bloque tiene una trampa de scope léxico de constantes (por eso acá usamos
`class X < Data.define(...)`).
