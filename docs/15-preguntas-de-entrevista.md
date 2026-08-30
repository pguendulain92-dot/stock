# Preguntas de entrevista, con respuestas

Este es el documento de repaso final: unas cien preguntas agrupadas por área, con
la respuesta corta y precisa que conviene dar, y —donde hace falta— una línea de
**"si repreguntan"** con el segundo nivel de detalle. Todo lo que hay acá es
consistente con el código de este repositorio y con `docs/00` a `docs/14`; los
números y las salidas de comandos se midieron acá, sobre **Ruby 3.3.6, Rails
8.1.3.1 y PostgreSQL 16.13**, con la base de seed (15 productos, 4 depósitos, 48
`stock_items`, 106 movimientos, 4 usuarios).

Está escrito para alguien que viene de **Java/Spring**: casi todas las respuestas
incluyen la comparación con el equivalente de la JVM y, sobre todo, marcan **dónde
se rompe la analogía**, que es exactamente donde el entrevistador va a apretar.

Cómo usarlo: leelo una vez entero, después tapá las respuestas y contestá en voz
alta. Si no podés decir una respuesta en 40 segundos sin leer, todavía no la sabés.

---

## 1. Ruby: el lenguaje

### ¿Qué significa que en Ruby "todo es un objeto"?

Literalmente todo: `1.class` → `Integer`, `nil.class` → `NilClass`, `String.class`
→ `Class`. No hay primitivos ni `int` vs `Integer` como en Java, así que no hay
autoboxing ni `NullPointerException` por unboxing. Y las clases mismas son objetos
en runtime, que es lo que hace posible `define_method`.

**Si repreguntan:** las llamadas no son invocaciones de método resueltas por el
compilador, son **mensajes** despachados en runtime; `obj.foo` es azúcar de
`obj.send(:foo)`.

### ¿Qué es un mixin y en qué se diferencia de una interfaz de Java?

Un módulo que se incluye en una clase y aporta **implementación**, no sólo firma.
Ruby no tiene herencia múltiple de clases, pero sí de módulos: `include Discardable`
inserta el módulo en la cadena de ancestros
(`app/models/concerns/discardable.rb:25`). Es más parecido a una `default method`
de Java 8 llevada al extremo, pero sin chequeo estático de nada.

**Si repreguntan:** `include` mete el módulo **arriba** de la clase en los
ancestros, `prepend` lo mete **abajo** (intercepta llamadas), `extend` lo agrega a
la clase singleton (métodos de clase).

### ¿Cómo resuelve Ruby una llamada a método?

Recorre la cadena de ancestros: singleton class → módulos con `prepend` → la clase
→ módulos con `include` → superclase → ... hasta `BasicObject`. Si no encuentra
nada, llama a `method_missing`. Lo ves con `StockItem.ancestors`.

### ¿Qué es `method_missing` y cuándo lo usarías?

Un hook que se dispara cuando el despacho falla. Sirve para proxies y DSLs
(ActiveRecord lo usó históricamente para los `find_by_nombre_y_apellido`). **Regla
de oro: si definís `method_missing`, definí también `respond_to_missing?`**, o el
objeto miente ante `respond_to?` y rompe el duck typing.

**Si repreguntan:** en este repo no lo usamos. Lo evitamos a propósito: es más
lento, no aparece en `grep` ni en el autocompletado, y `define_method` en tiempo de
carga (`app/models/concerns/has_money.rb:26`) da lo mismo sin ninguna de esas
desventajas.

### Diferencia entre bloque, `Proc` y `lambda`.

Un bloque no es un objeto, es un argumento sintáctico. `Proc` y lambda son objetos.
Las dos diferencias que importan: un **lambda** verifica la aridad y su `return`
vuelve del lambda; un **Proc** ignora argumentos de más y su `return` vuelve del
**método que lo creó** (y explota si ya volvió).

**Si repreguntan:** el `&` convierte bloque ↔ Proc. `def call(...) = new(...).call`
en `app/services/application_service.rb:56` usa el forwarding de argumentos de
Ruby 3.

### ¿Qué es un closure en Ruby y dónde se ve en este repo?

Un bloque/lambda captura el binding léxico donde fue creado. Los scopes de
ActiveRecord son lambdas: `scope :in_stock, -> { where(quantity_available: 1..) }`
(`app/models/stock_item.rb:40`). Por eso un scope se re-evalúa en cada llamada, y
por eso escribir `scope :recent, -> { where("created_at > ?", 1.day.ago) }` está
bien pero `where("created_at > ?", 1.day.ago)` fuera del lambda congelaría la fecha
al bootear.

### `Symbol` vs `String`: ¿cuándo uso cada uno?

Symbol para identificadores (claves de hash, nombres de método, estados internos):
son inmutables y **el mismo símbolo es el mismo objeto**, así que la comparación es
por identidad. String para datos que vienen de afuera o que se van a mutar.

**Si repreguntan:** desde Ruby 2.2 los símbolos creados dinámicamente **sí** se
recolectan, así que el viejo "symbol DoS" con `params.to_sym` está mitigado, pero
igual no conviertas input del usuario a símbolo.

### ¿Qué hace `freeze` y por qué `Result` se congela a sí mismo?

`freeze` vuelve el objeto inmutable (superficialmente). `Result#initialize`
(`app/lib/result.rb:53`) hace `freeze` para que nadie mute un resultado ya
devuelto: es un valor, no un buffer. El `# frozen_string_literal: true` del tope de
cada archivo congela los literales de string y ahorra allocations.

**Si repreguntan:** es **shallow**: congelar un hash no congela sus valores. Para
inmutabilidad real de un value object, `Data.define`.

### ¿Qué es `Data.define` y con qué lo comparás en Java?

Es el `record` de Java 16+: clase de valor inmutable, con `==`, `hash`, `to_h` y
deconstrucción para pattern matching, en una línea.
`ValueObjects::Money < Data.define(:cents, :currency)`
(`app/models/value_objects/money.rb:45`). A diferencia de `Struct`, no tiene
setters y exige todos los campos.

**Si repreguntan:** usá la forma **con herencia**, no `Money = Data.define(...) do
... end`. El bloque se evalúa con `class_eval` y las constantes se resuelven
**léxicamente**, así que una clase de error definida adentro del bloque aterriza en
el módulo que la envuelve, no dentro de `Money`. Está explicado en el archivo.

### ¿Qué es el GVL y qué cambia respecto de los threads de la JVM?

Un mutex global por proceso: los `Thread` de Ruby son pthreads reales pero sólo uno
ejecuta bytecode a la vez. Se **libera** durante I/O bloqueante (el driver `pg` lo
suelta mientras espera a Postgres). Medición de `docs/00`: trabajo CPU-bound con 4
threads → 1.53 s contra 1.51 s secuencial (cero ganancia); I/O-bound → 0.50 s
contra 2.00 s (4×).

**Si repreguntan:** la unidad de paralelismo real es el **proceso**. Puma corre N
workers × M threads (default 3, `config/puma.rb:28`). Una caché en memoria no es
una copia, son N copias — es exactamente el bug del rate limiting con `MemoryStore`.

### ¿Ractors y Fibers reemplazan al GVL?

**Ractor** (3.0, todavía experimental en 3.3) da paralelismo real —un GVL por
Ractor— pero no comparte objetos y **ActiveRecord no funciona adentro**. **Fiber**
es concurrencia cooperativa; con `Fiber::Scheduler` es el equivalente conceptual de
las virtual threads de Java 21, pero hay que optar explícitamente y buena parte del
ecosistema no está adaptada.

### ¿Cómo funciona el GC de Ruby comparado con G1/ZGC?

Mark & sweep generacional de 2 generaciones, con marcado incremental y barrido
perezoso. **No mueve objetos** por defecto (`GC.compact` es manual), así que hay
fragmentación real. Y **no existe `-Xmx`**: el heap crece hasta que el SO diga
basta, por eso en producción se reinician workers por RSS.

**Si repreguntan:** el "bloat" típico de Puma no suele ser un leak de objetos Ruby
sino fragmentación del allocator de C. `MALLOC_ARENA_MAX=2` o jemalloc por
`LD_PRELOAD` bajan el RSS 20-30% sin tocar una línea.

### ¿Qué es `self` en Ruby?

El receptor implícito del mensaje actual. Cambia según el contexto: en el cuerpo de
una clase es la clase; en un método de instancia, la instancia; dentro de
`instance_exec`, el objeto que le pasás. Esto último es lo que hace que
`by: -> { current_api_token&.id }` en `rate_limit` pueda ver métodos del controller
(`app/controllers/api/v1/base_controller.rb:77`).

### ¿Qué es un `ActiveSupport::Concern` y en qué se diferencia de un módulo pelado?

Resuelve dos cosas: el orden de dependencias entre módulos y el bloque `included do
... end` para ejecutar macros de clase (`scope`, `validates`, `before_action`) en el
momento de la inclusión. Sin él, tendrías que definir `self.included(base)` a mano.
Ejemplos: `app/models/concerns/discardable.rb`,
`app/controllers/concerns/api/idempotency.rb`.

---

## 2. Rails: el framework

### Rails vs Spring Boot en una frase.

Spring Boot es **configuración explícita con autoconfiguración**; Rails es
**convención sobre configuración con muy poca configuración posible**. Rails te da
menos grados de libertad y a cambio te da un layout de proyecto que cualquiera
entiende en 5 minutos. No hay contenedor de DI ni anotaciones: la "inyección" es
pasar objetos por el constructor (`app/services/stock/apply_movement.rb:42-45`).

### ¿Qué es Zeitwerk y qué pasa si te equivocás en el nombre de un archivo?

El autoloader: mapea **un archivo a una constante** por convención de nombres
(`app/services/outbox/null_recorder.rb` → `Outbox::NullRecorder`). Si el nombre no
coincide, `NameError` al referenciar la constante. En producción se usa
`eager_load`, que carga todo al bootear y hace que ese error aparezca en el deploy y
no a las 3 AM.

**Si repreguntan:** una clase escondida dentro de otro archivo (por ejemplo
`NullRecorder` adentro de `recorder.rb`) funciona en producción por el eager load y
falla en desarrollo. `bin/rails zeitwerk:check` **no** lo detecta, porque sólo
verifica que cada archivo defina su constante esperada. Por eso está en su propio
archivo, con el comentario que lo explica.

### Contame el ciclo de vida de una request.

Rack recibe el `env` → pasa por la pila de middlewares → el router matchea y elige
controller/acción → corren los `before_action` → la acción → `after_action` →
`render` → el response vuelve subiendo por los middlewares. Lo ves entero con
`bin/rails middleware`.

**Si repreguntan:** en este repo el orden importa: `Rack::Attack` está insertado
**después** de `ActionDispatch::RemoteIp` (`config/application.rb:52`), porque antes
de ese middleware `request.ip` es la IP del balanceador y todos los usuarios
compartirían un contador.

### ¿Qué es un middleware Rack y con qué se corresponde en Java?

Un objeto que responde `call(env)` y devuelve `[status, headers, body]`, apilado
como capas de cebolla. Cada capa puede cortar la cadena. Es exactamente
`javax.servlet.Filter` / la `FilterChain` de Spring Security.

### En `bin/rails middleware` aparece `Rack::Attack` dos veces. ¿Es un bug?

Sí y no: el railtie de la gema hace `app.middleware.use(Rack::Attack)` al final de
la pila, y nosotros además lo insertamos después de `RemoteIp`. **La segunda
ejecución es un no-op**: `Rack::Attack#call` arranca con
`return @app.call(env) if ... env["rack.attack.called"]`
(rack-attack 6.8.0, `lib/rack/attack.rb:105`), o sea que no se cuentan las requests
dos veces. Igual conviene sacar el duplicado; lo verifiqué leyendo la gema, no lo
supuse.

### ¿Qué es un engine y cuándo montarías uno?

Una mini-aplicación Rails empaquetada como gema, con sus rutas, controllers y
vistas. Acá montamos uno: `mount MissionControl::Jobs::Engine, at: "/jobs"`
(`config/routes.rb:114`). Lo montás cuando querés reutilizar una vertical entera
entre apps, o cuando consumís una (dashboards de jobs, Devise, Active Storage).

**Si repreguntan:** montar un engine de administración **sin restricción** es un
clásico de bug bounty. Acá va adentro de un `constraints` que exige sesión de admin
(`config/routes.rb:110-115`).

### MVC en Rails: ¿qué va en cada capa?

Modelo: persistencia + invariantes simples. Vista: presentación. Controller:
traducir HTTP ↔ dominio. Pero MVC no alcanza para una app real, por eso este repo
agrega `services/` (casos de uso), `queries/` (consultas), `policies/`
(autorización), `serializers/` (contrato de salida) y `forms/` (entrada validada).

**Si repreguntan:** la prueba de que un controller está bien es que su lógica se
pueda ejecutar desde un job, la consola o un import CSV sin copiar nada. Mirá
`app/controllers/api/v1/stock_operations_controller.rb`: cada acción es resolver,
autorizar, delegar, renderizar.

### ¿Qué es un concern y cuándo se vuelve un problema?

Un módulo compartido. Se vuelve un problema cuando lo usás para **partir un modelo
gordo en pedazos** en vez de para **compartir comportamiento entre modelos**: el
acoplamiento sigue igual, sólo lo repartiste en más archivos, y ahora el estado que
toca cada pedazo es invisible. Si el concern lo incluye una sola clase, casi siempre
debería ser un objeto aparte.

### ¿Qué son los strong parameters y qué problema resuelven?

Una allow-list explícita sobre `params` para evitar **mass assignment**
(`app/controllers/api/v1/products_controller.rb:78-83`). Sin eso, un atacante manda
campos que nunca pensaste exponer. Rails lo aprendió por las malas: en 2012 alguien
se dio permisos en el repo de Rails en GitHub explotando exactamente esto.

**Si repreguntan:** `params.expect` en Rails 8 es la forma nueva y más estricta;
`require` + `permit` sigue siendo perfectamente válido.

### ¿Cómo manejás errores globalmente en una API Rails?

`rescue_from` en un concern incluido por el controller base
(`app/controllers/concerns/api/error_handling.rb:23-32`). Es el
`@ControllerAdvice` + `@ExceptionHandler` de Spring.

**Si repreguntan:** los `rescue_from` se evalúan **en orden inverso** al de
declaración, así que `StandardError` va primero y lo específico después. Y nunca
devuelvas `e.message` crudo de una excepción inesperada: los mensajes de Postgres
filtran nombres de tablas y a veces datos.

### ¿Qué es `Current` y por qué no un `ThreadLocal`?

`ActiveSupport::CurrentAttributes` (`app/models/current.rb:17`) es un singleton por
thread/fiber que **Rails resetea automáticamente** al terminar cada request y cada
job. Esa garantía de reset es toda la diferencia con un `ThreadLocal` a mano: en un
pool de threads, si no limpiás, la request N+1 hereda el contexto de la N — fuga de
datos entre usuarios.

**Si repreguntan:** guardá ahí sólo contexto transversal (usuario, `request_id`,
IP). Usarlo para pasar parámetros de negocio entre capas es el mismo abuso que
hacerle `static` a todo en Java.

---

## 3. ActiveRecord

### Active Record vs Data Mapper: ¿qué cambia en la práctica respecto de JPA?

ActiveRecord implementa **Active Record** (el objeto sabe persistirse); JPA
implementa **Data Mapper** (un `EntityManager` gestiona la persistencia). Tres
consecuencias concretas, todas escritas en `app/models/application_record.rb:14-22`:

1. **No hay sesión de persistencia ni entidades detached.** Cada `save` es un
   INSERT/UPDATE inmediato. No hay flush automático ni dirty checking diferido al
   final de la transacción.
2. **No hay lazy loading transparente dentro de una sesión.** Tocar
   `product.category` dispara **una query en ese instante**. Por eso el N+1 es tan
   fácil de crear.
3. El modelo mezcla persistencia y dominio, así que la disciplina SOLID la ponés
   vos: modelos flacos + service objects.

**Si repreguntan:** el corolario que más sorprende a un javero es que
`producto.nombre = "x"` sin `save` **no persiste nada nunca**, mientras que en JPA
dentro de una transacción activa sí.

### ¿Qué es una `ActiveRecord::Relation` y por qué importa que sea perezosa?

Un builder de query que **no ejecuta nada** hasta que la necesitás
(`to_a`, `each`, `first`, `count`). Eso permite componer: un query object devuelve
una Relation y el que llama todavía puede paginar y encadenar. Por eso
`ApplicationQuery` tiene la regla explícita "devolver Relation, no Array"
(`app/queries/application_query.rb:19-20`).

### ¿Qué es un N+1 y de cuántas formas se te cuela?

Una query para la colección y N para las asociaciones de cada elemento. Las cuatro
formas: (1) iterar una asociación sin `includes`; (2) llamar un método del modelo
que consulta, dentro de un loop; (3) **agregaciones** por elemento; (4) hacerlo
desde una vista o un serializer, donde no se ve.

**Si repreguntan:** el caso (3) es el que `includes` **no** arregla. Por eso existe
`StockItems::Availability` (`app/queries/stock_items/availability.rb`): un
`GROUP BY` que devuelve un Hash `product_id => {on_hand:, reserved:, available:}`,
que el controller le pasa **precalculado** al serializer
(`app/controllers/api/v1/products_controller.rb:23-27`).

### `includes` vs `preload` vs `eager_load` vs `joins`.

| Método | SQL | Cuándo |
|---|---|---|
| `preload` | 2 queries separadas (`IN (...)`) | Sólo querés evitar el N+1 |
| `eager_load` | 1 query con `LEFT OUTER JOIN` + alias | Necesitás filtrar/ordenar por la asociación |
| `includes` | decide solo: `preload`, salvo que detecte que referenciás la tabla | El default razonable |
| `joins` | `INNER JOIN`, **no** carga la asociación | Filtrar por la asociación sin traerla |

**Si repreguntan:** `joins` + tocar la asociación = N+1 igual, porque `joins` no
llena la caché de asociaciones. Y `includes` + `where("categories.name = ?")` sin
`references(:categories)` explota; con un hash (`where(categories: {...})`) Rails lo
infiere.

### ¿Cómo detectás un N+1 antes de que llegue a producción?

Con `bullet` activado **en test**, de modo que un N+1 **rompa la suite**
(`spec/rails_helper.rb:62-70`, tag `:n_plus_one`). En desarrollo, el log de queries
o `rack-mini-profiler`. En producción, el APM.

### ¿Qué es un scope y cuándo pasar a un query object?

Un scope es un lambda que devuelve una Relation, ideal para filtros chicos y
reutilizables (`Product.kept.active`). Pasás a query object cuando la consulta tiene
varios filtros opcionales, joins y agregaciones: meterla en el modelo lo infla
(viola SRP) y mezcla "qué es un producto" con "cómo busca la pantalla X". Ejemplo:
`app/queries/products/search.rb`.

### ¿Por qué `default_scope` casi nunca?

Porque se cuela en **todas** las asociaciones, joins y counts; hace que
`Product.count` mienta; y sacarlo con `unscoped` te vuela también el `order` y los
`where` del join. La convención sana es scopes explícitos: `Product.kept`
(`app/models/concerns/discardable.rb:29`).

### Validaciones de Rails vs constraints de la base: ¿cuál es la verdad?

La base. Una validación corre en un proceso Ruby y **no es atómica**:
`validates_uniqueness_of` hace `SELECT` y después `INSERT`, y entre las dos hay una
ventana en la que otro proceso inserta lo mismo. La garantía real es el índice
único; la validación existe para dar un mensaje lindo.

**Si repreguntan:** defensa en profundidad, y este repo lo hace explícito: la
coherencia de signo de un movimiento está **duplicada** a propósito, como validación
Ruby (`app/models/stock_movement.rb:76-84`) y como CHECK constraint
`stock_movements_sign_matches_kind` en el schema.

### ¿Cuáles son los CHECK constraints de `stock_items` y por qué existen?

`quantity_on_hand >= 0`, `quantity_reserved >= 0`,
`quantity_reserved <= quantity_on_hand` y
`maximum_level IS NULL OR maximum_level >= reorder_point`. Son la última red:
aunque alguien se saltee `Stock::ApplyMovement` con un script o un `psql`, la base
rechaza el estado inválido.

### ¿Qué es una columna generada y qué trampa tiene en Rails?

`quantity_available` es `GENERATED ALWAYS AS (quantity_on_hand - quantity_reserved)
STORED`: la calcula Postgres, se puede leer e indexar, no se puede escribir.

La trampa, medida en la consola de este repo: **asignarla no falla**. Rails la
excluye del `UPDATE`, así que `item.quantity_available = 999; item.save!` devuelve
`true`, el atributo queda "sucio" en memoria y el valor real vuelve recién con
`reload`. Ojo también con que `StockItem.readonly_attributes` está **vacío**: no hay
excepción que te avise.

**Si repreguntan:** por eso `ApplyMovement#apply_to`
(`app/services/stock/apply_movement.rb:132-140`) hace `item.reload` después de
guardar: sin eso, el evento del outbox publicaría un `quantity_available` viejo.

### ¿Cómo hacés inmutable un registro?

Dos capas. En la app, `def readonly? = persisted?`
(`app/models/stock_movement.rb:47`): cualquier UPDATE levanta
`ActiveRecord::ReadOnlyRecord` (verificado en consola). En producción, la barrera de
verdad sería un trigger o revocar el UPDATE al rol de la app.

### `after_save` vs `after_commit`: ¿cuál usás para disparar un job?

`after_commit`, siempre. `after_save` corre **dentro** de la transacción: si hace
rollback, el job ya se encoló y va a procesar algo que no existe; y el worker puede
levantarlo antes de que Postgres commitee.

**Si repreguntan:** en Rails 7.2+ hay dos herramientas mejores.
`config.active_job.enqueue_after_transaction_commit = :always`
(`config/initializers/sidekiq.rb`, al final) lo arregla para cualquier adapter; y
`ActiveRecord.after_all_transactions_commit`
(`app/services/outbox/recorder.rb:47`) ejecuta al commitear la transacción **más
externa**, que es lo que necesitás dentro de transacciones anidadas.

### ¿Qué trampas tienen las transacciones en Rails?

Tres, y las tres están documentadas en `app/services/application_service.rb:36-45`:

1. Desde Rails 7 un `return` dentro de un bloque `transaction` **hace commit** de lo
   escrito (antes hacía rollback). Cambió el comportamiento en silencio.
2. `raise ActiveRecord::Rollback` dentro de una transacción **anidada sin
   `requires_new: true`** se traga la excepción y **no revierte** la de afuera: una
   transacción anidada sin `requires_new` no abre nada, se une a la externa.
3. Con `requires_new: true` sí funciona, porque emite un `SAVEPOINT`.

La solución acá es una excepción propia (`BusinessRuleViolation`) que viaja hasta el
`rescue` de `transactional` (`app/services/application_service.rb:68-84`): el
rollback está garantizado y afuera seguimos devolviendo un `Result`.

### ¿Qué es una migración y en qué se diferencia de Flyway/Liquibase?

Una clase Ruby versionada por timestamp que se aplica una sola vez; Rails lleva la
cuenta en la tabla `schema_migrations`. La diferencia con Flyway: la migración es
**código Ruby ejecutable**, no SQL ni XML, y además Rails vuelca el estado resultante
en `db/schema.rb`, que es lo que se carga para crear una base nueva
(`db:schema:load`), no la cadena de migraciones.

**Si repreguntan:** si usás features de Postgres que `schema.rb` no sabe representar
(triggers, tipos custom, funciones), hay que pasar a
`config.active_record.schema_format = :sql` y versionar `structure.sql`. Acá
`schema.rb` alcanza porque las columnas generadas y los CHECK constraints **sí** se
representan (los ves en `db/schema.rb:203` y `db/schema.rb:213-217`).

### Optimistic locking en Rails vs `@Version` de JPA.

Mismo concepto: una columna `lock_version` que se agrega al `WHERE` del UPDATE. La
diferencia: en Rails el chequeo ocurre **en cada `UPDATE`**, no en el flush, porque
no hay sesión de persistencia. Y `update_all` / `update_column` **saltean** el
optimistic locking; si escribís SQL crudo, tenés que incrementar `lock_version` a
mano, como hace `StockItem.atomically_decrement`
(`app/models/stock_item.rb:104-114`).

### ¿Cómo se ve el optimistic locking sobre HTTP?

El cliente manda el `lock_version` que leyó; si otro lo modificó, Rails levanta
`StaleObjectError` y devolvemos **409**
(`app/controllers/api/v1/products_controller.rb:56`). Es el mismo mecanismo que
`ETag` + `If-Match`, y evita el *last write wins* silencioso.

### ¿Qué diferencia hay entre `update_attribute`, `update_column` y `update!`?

`update!` corre validaciones, callbacks y locking. `update_attribute` saltea
**validaciones** pero corre callbacks y toca `updated_at`. `update_column` /
`update_columns` van directo al SQL: sin validaciones, sin callbacks, sin
`updated_at`, sin locking. Lo usamos a propósito en
`ApiToken#touch_usage!` (`app/models/api_token.rb:77-81`), donde queremos un UPDATE
barato y con throttling.

---

## 4. Base de datos y PostgreSQL

### ¿Cuándo un índice B-tree no se usa?

Cuando el predicado no es sargable (`WHERE lower(sku) = ?` sin índice funcional,
`LIKE '%x%'` con comodín inicial), cuando la tabla es tan chica que el Seq Scan es
más barato, cuando el orden de columnas del índice compuesto no coincide con el del
WHERE (regla del prefijo izquierdo), o cuando las estadísticas están desactualizadas.

**Si repreguntan:** honestamente, en esta base de seed el índice parcial de reorden
**no se usa**, y está bien:

```text
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM stock_items WHERE quantity_available <= reorder_point;
 Seq Scan on stock_items  (cost=0.00..1.60 rows=16) (actual rows=13 loops=1)
   Buffers: shared hit=1
```

48 filas entran en **una página**. El planner tiene razón. El índice
`index_stock_items_needing_reorder` gana recién con volumen, y decirlo así (en vez
de inventar un Index Scan) es exactamente la respuesta que quiere escuchar un
entrevistador senior.

### ¿Qué es un índice parcial y cuándo conviene?

Un índice con `WHERE`: sólo indexa las filas que cumplen el predicado.
`index_stock_items_needing_reorder` sólo tiene las filas bajo el punto de reorden,
así que es una fracción del tamaño. Para que Postgres pueda usarlo, el WHERE de la
query tiene que **implicar** el predicado del índice: por eso
`StockItems::LowStock` escribe la condición **exactamente igual** que la migración
(`app/queries/stock_items/low_stock.rb:24`).

### ¿Qué índices no-B-tree usás acá y para qué?

`GIN` con `gin_trgm_ops` sobre `products.name` y `suppliers.name` (para que
`ILIKE '%texto%'` pueda usar índice), `GIN` con `jsonb_path_ops` sobre
`suppliers.metadata`, y `GIN` sobre el array `api_tokens.scopes`. Las extensiones
habilitadas son `pg_trgm`, `btree_gin` y `citext`.

### ¿Cómo leés un `EXPLAIN ANALYZE`?

`cost` es una estimación en unidades arbitrarias; `actual time` es real. Lo primero
que mirás es la **diferencia entre `rows` estimadas y reales**: si difieren en un
orden de magnitud, las estadísticas están mal y el plan también. Después, el nodo
más caro y si hay `Seq Scan` sobre tablas grandes o `Sort` con `external merge`
(disco). `BUFFERS` te dice cuántas páginas tocó.

### ¿Qué nivel de aislamiento usás y por qué no SERIALIZABLE?

READ COMMITTED, el default. Postgres implementa SERIALIZABLE con SSI: no bloquea,
rastrea dependencias y **aborta a posteriori**, así que **toda** transacción
necesita un loop de reintento y con contención alta la tasa de abortos sube.
Prefiero locks explícitos: más código, comportamiento predecible.

**Si repreguntan:** dos cosas que conviene aclarar. Postgres **no tiene dirty
reads** ni en READ COMMITTED (`READ UNCOMMITTED` se comporta igual), y su REPEATABLE
READ es snapshot isolation, así que también elimina phantoms — no es el REPEATABLE
READ de MySQL con gap locks. Lo que REPEATABLE READ no te da es **write skew**.

### ¿Qué es un deadlock y cómo lo prevenís?

Dos transacciones que se esperan mutuamente. Postgres lo detecta
(`deadlock_timeout`, 1 s por defecto) y mata a una; el usuario ve un 500
intermitente "imposible de reproducir". **La prevención es orden total y
determinístico de adquisición de locks.** En las transferencias multi-producto se
hace con una sola query
`... WHERE product_id IN (...) ORDER BY id FOR UPDATE`
(`app/services/stock/transfers/dispatch.rb:99-102`). Es una garantía, no una mejora
estadística.

**Si repreguntan:** el orden también vale **entre tablas**: en este repo siempre se
bloquea primero la reserva y después el `stock_item`
(`app/services/stock/release_reservation.rb:25-30`). El `retry_on
ActiveRecord::Deadlocked` de `app/jobs/application_job.rb:52` es el cinturón de
seguridad, no la solución.

### ¿Cómo dimensionás el pool de conexiones?

**El pool es por proceso y por base.** 3 workers × 5 threads = 15 conexiones desde
una máquina; multiplicá por las 4 bases de Rails 8 (primary, cache, queue, cable) y
por la cantidad de pods, y comparalo contra `max_connections` de Postgres (default
100). Regla dura: `max_connections` del pool **≥** `RAILS_MAX_THREADS`, o vas a ver
`ActiveRecord::ConnectionTimeoutError`. A escala: PgBouncer en transaction pooling.
Todo esto está en `config/database.yml:8-31`.

**Si repreguntan:** con PgBouncer en transaction pooling perdés prepared statements
por sesión, `LISTEN/NOTIFY` y las variables de sesión; hay que configurar
`prepared_statements: false`.

### ¿Qué timeouts de base ponés y por qué?

En `config/database.yml:52-55`: `statement_timeout: 15000` (mata queries colgadas),
`lock_timeout: 10000` (no esperes locks eternamente) y
`idle_in_transaction_session_timeout: 30000` (mata transacciones zombie, que son las
que frenan el VACUUM y hacen crecer la tabla).

### ¿Cuándo particionarías una tabla?

Cuando el volumen hace que el mantenimiento sea el problema, no la lectura: retención
por fecha (borrar 190M de filas genera tuplas muertas que el autovacuum no da
abasto a limpiar), o índices que ya no entran en memoria. Con particiones
declarativas de Postgres 12+, `DROP PARTITION` es instantáneo y no genera bloat. Los
candidatos naturales acá son `stock_movements` y `outbox_events` por `occurred_at` /
`created_at`.

**Si repreguntan:** mientras tanto, la respuesta barata es borrar seguido y en lotes
chicos, que es lo que hace `Cleanup::ExpiredRecordsJob`
(`app/jobs/cleanup/expired_records_job.rb:43-49`) con `in_batches` + `delete_all`.

### ¿Cómo usarías réplicas de lectura?

`ActiveRecord::Base.connected_to(role: :reading)` con una entrada `replica: true` en
`database.yml` (hay un ejemplo comentado en `config/database.yml:79-84`). La trampa es el
**lag de replicación**: leer inmediatamente después de escribir puede devolver el
estado viejo. Rails trae `ActiveRecord::Middleware::DatabaseSelector` para mandar a
la primaria las lecturas que siguen a una escritura del mismo usuario.

**Si repreguntan:** las réplicas escalan lecturas, **no** escrituras, y no reducen
la contención de locks sobre `stock_items`.

### ¿Cuándo desnormalizarías?

Cuando el costo de mantener el dato duplicado es menor que el de recalcularlo, y
tenés cómo detectar la deriva. Este repo desnormaliza a propósito:
`stock_movements` guarda `product_id` y `warehouse_id` aunque se deducen del
`stock_item` (`app/models/stock_movement.rb:68-74`), y `stock_items` mantiene
`quantity_on_hand` como **proyección** del ledger. La contrapartida obligatoria es
`StockItems::Reconciliation` (`app/queries/stock_items/reconciliation.rb`) corriendo
todas las noches: si la proyección y la suma del ledger difieren, hay un bug.

---

## 5. Diseño y arquitectura

### ¿Qué es un service object y por qué no ponés eso en el modelo?

Una clase con un método público (`call`) que representa **un caso de uso**. Es el
patrón Command. No va en el modelo porque una operación real necesita bloquear,
validar reglas, escribir el ledger, emitir el evento y devolver un `Result`: eso no
es responsabilidad de la entidad de persistencia, y meterlo ahí es el camino directo
al modelo de 2000 líneas.

**Si repreguntan:** cómo salen los SOLID casi gratis está en
`app/services/application_service.rb:15-25`. El que más se pregunta es **DIP**:
`event_recorder:` y `clock:` entran por el constructor con un default sensato
(`app/services/stock/apply_movement.rb:45`); en los tests se inyecta
`Outbox::NullRecorder` y un reloj congelado. Sin contenedor de DI: en Ruby los
argumentos con nombre y valor por defecto alcanzan.

### ¿Por qué `Result` y no excepciones?

Porque en Ruby **todas** las excepciones son unchecked: nada en la firma te dice qué
puede fallar. Si usás excepciones para reglas de negocio, el que llama no tiene
forma de saberlo salvo leyendo la implementación. La regla del repo
(`app/lib/result.rb:14-21`): **falla esperada** (regla de negocio) → `Result.failure`,
es un valor; **falla inesperada** (bug o infraestructura) → excepción, que explote y
la vea el error tracker.

```ruby
# app/lib/result.rb:37-47 — `Data.define` es el `record` de Java 16+ en una línea
Error = Data.define(:code, :message, :details) do
  def to_h = { code:, message:, details: }   # <- "hash shorthand" de Ruby 3.1
end

class << self
  def success(value = nil) = new(ok: true, value:)
  def failure(code, message, **details) =
    new(ok: false, error: Error.new(code:, message:, details:))
end
```

**Si repreguntan:** `Result` implementa `deconstruct_keys`, así que el controller
usa pattern matching (`case/in`) y el runtime te avisa si no contemplaste un caso:
`case/in` levanta `NoMatchingPatternError` en vez de devolver `nil` como
`case/when`.

### ¿Qué es CQRS y qué versión de CQRS tenés acá?

Separar el modelo de escritura del de lectura. Acá hay una versión pragmática: las
escrituras pasan por services y escriben el **ledger** (`stock_movements`,
append-only); las lecturas van contra la **proyección** (`stock_items`) y contra
query objects. No hay dos bases ni buses: es CQRS "ligero", y decirlo así es más
honesto que decir "implementé CQRS".

### ¿Esto es event sourcing?

No del todo, y hay que saber la diferencia. En event sourcing puro, el estado **se
deriva** de los eventos y no existe otra fuente de verdad. Acá el ledger es
inmutable y la proyección es redundante y auditable, pero el sistema opera sobre la
proyección. Es "ledger + proyección reconciliada", que es lo que usan la mayoría de
los sistemas contables reales.

**Si repreguntan:** la prueba está en `Stock::ReconcileBalancesJob`, y en el
comentario de `app/jobs/stock/reconcile_balances_job.rb:33-50`: para cerrar una
brecha hay que mover **una sola** de las dos, porque `ApplyMovement` mueve las dos
por el mismo delta y la diferencia nunca converge. Ese detalle lo encontró un test.

### ¿Qué es el patrón transactional outbox y qué problema resuelve?

Resuelve el **dual write**: no podés escribir en Postgres y publicar en Kafka
atómicamente sin transacciones distribuidas. La solución es escribir el evento en
una tabla **dentro de la misma transacción** de negocio
(`app/services/outbox/recorder.rb:18`) y que un relay lo publique después
(`app/jobs/outbox/publish_pending_job.rb`). Estado y evento commitean juntos o no
commitea ninguno.

### ¿Cuándo NO necesitás outbox?

Cuando el evento se puede perder. "Mandale un mail de bienvenida" no justifica una
tabla y un relay: alcanza con `enqueue_after_transaction_commit = :always`. La
ventana que queda (el proceso muere entre el COMMIT y el enqueue) es de
microsegundos; si esa ventana te importa, outbox. Saber dónde está esa línea es la
respuesta madura.

### ¿Cómo hacés idempotente una API de escritura?

Clave que **genera el cliente** (`Idempotency-Key`), porque sólo él sabe que dos
requests son el mismo intento. El servidor guarda la clave, el **fingerprint del
body** y la respuesta (`app/controllers/concerns/api/idempotency.rb`). Reintento con
la misma clave y mismo body → misma respuesta con `Idempotent-Replay: true`. Misma
clave, body distinto → 422. Clave en vuelo → 409.

**Si repreguntan:** dos detalles que casi todos se olvidan. (1) El **fingerprint**:
sin él, un cliente con la clave fija recibe silenciosamente el resultado de otra
operación. (2) La clave tiene que estar **scopeada por usuario**
(`app/controllers/concerns/api/idempotency.rb:68-73`): el índice único de
`stock_movements.idempotency_key` es global, así que sin el prefijo el usuario B con
`Idempotency-Key: pedido-1` recibiría el movimiento del usuario A — fuga de
información **y** pérdida de datos, en silencio. Ese bug apareció escribiendo los
tests.

### ¿Cómo implementás un lock distribuido sin Redis?

Con un índice único. El INSERT en estado `processing` es la sección crítica: si dos
requests con la misma clave llegan a la vez, una gana y la otra recibe
`RecordNotUnique`, que traducimos a 409
(`app/controllers/concerns/api/idempotency.rb:159-161`). También hay advisory locks
de Postgres (`pg_advisory_xact_lock`) para exclusión mutua sin fila.

### ¿Cómo versionás una API y por qué por path?

Por path (`/api/v1/...`). Las alternativas: header (`Accept:
application/vnd.stock.v2+json`) es más purista pero imposible de probar desde el
browser y confunde a los caches; query param se pierde en redirects y logs. Path es
explícito, cacheable, se ve en los logs y podés enrutar v1/v2 a servicios distintos
en el balanceador. Es lo que usan Stripe y GitHub. El razonamiento completo está en
`config/routes.rb:45-51`.

**Si repreguntan:** lo importante no es la versión, es la **política de cambios**:
agregar campos es compatible, sacarlos o cambiar su tipo no. Una v2 se justifica
recién cuando el cambio es incompatible y tenés clientes que no podés migrar.

### ¿REST puro o RPC sobre HTTP?

Mixto, y a propósito. Los recursos son REST (`GET /api/v1/products`), pero las
operaciones son verbos: `POST /api/v1/stock/receive`, `/issue`, `/adjust`. REST puro
diría "creá un Movement" —y de hecho eso hace por debajo—, pero la URL comunica la
**intención**, y la intención es lo que el ledger necesita registrar: recibir no es
lo mismo que ajustar, aunque las dos sumen 10 unidades. No seas dogmático con REST
cuando el dominio es de comandos.

### ¿Por qué serializers POROs y no `render json: product`?

Porque `to_json` de ActiveRecord serializa **todas** las columnas: el día que
agregás `internal_cost_notes`, se filtra sola. Un serializer PORO
(`app/serializers/application_serializer.rb`) es un contrato explícito, versionado y
testeable, y es la clase más fácil de testear que existe.

**Si repreguntan:** alba/blueprinter/jsonapi-serializer son buenas alternativas;
jbuilder no, porque son vistas con lookup de templates y no se testean como objetos.

---

## 6. Concurrencia y transacciones

### Dos usuarios venden la última unidad al mismo tiempo. ¿Qué hacés?

Bloqueo pesimista de la fila del agregado y valido **después** de bloquear.
`StockItem.lock.find(id)` genera `SELECT ... FOR UPDATE`
(`app/services/stock/apply_movement.rb:102-104`), así que el segundo espera en el
SELECT y cuando entra lee el saldo real. Bloqueo **una sola fila** —el par
producto/depósito—, así que dos productos distintos siguen 100% en paralelo:
Postgres no escala locks a la tabla como SQL Server.

```ruby
# app/services/stock/apply_movement.rb:61-78 — el ORDEN es todo el truco
def call
  transactional do
    if (existing = replayed_movement)   # idempotencia: todavía no escribimos nada
      next success(existing)
    end

    item = lock_stock_item!             # SELECT ... FOR UPDATE
    validate!(item)                     # las reglas, contra el estado YA bloqueado

    apply_to(item)                      # la proyección
    movement = write_ledger_entry(item) # el asiento inmutable
    publish_event(item, movement)       # el outbox, en la MISMA transacción

    success(movement)
  end
end
```

**Si repreguntan:** abajo hay dos redes más, el CHECK `quantity_on_hand >= 0` y el
ledger reconciliado. El trade-off es que serializo las operaciones sobre el mismo
SKU; si un SKU se vuelve fila caliente, paso a un UPDATE condicional de una sola
sentencia.

### ¿Qué es un lost update y por qué READ COMMITTED no te salva?

T1 y T2 leen 10, las dos calculan 10-7 en Ruby y las dos escriben 3: vendiste 14 de
10. READ COMMITTED garantiza que cada UPDATE ve la fila más nueva, pero **el cálculo
lo hiciste afuera**, con un valor viejo. El comentario largo de
`app/services/stock/apply_movement.rb:21-36` lo tiene con el timeline.

### Optimista o pesimista: ¿cómo elegís?

Por probabilidad de conflicto y por quién puede reintentar. **Pesimista** cuando el
conflicto es probable y caro (stock, reservas, transferencias): pagás un lock que
casi siempre ibas a necesitar. **Optimista** cuando el conflicto es raro y hay un
humano que reintenta (editar la ficha de un producto): costo cero en el camino
feliz, 409 cuando choca.

### ¿Hay una tercera opción?

Sí: el **UPDATE condicional atómico**, una sola sentencia con la regla de negocio en
el WHERE (`app/models/stock_item.rb:104-114`). Si devuelve 0 filas, la condición no
se cumplió. Ventaja: cero round-trips extra, cero riesgo de deadlock. Desventaja: no
podés hacer lógica compleja en Ruby entre el chequeo y la escritura, y **perdés el
optimistic locking** salvo que incrementes `lock_version` a mano (por eso el SQL lo
hace).

### ¿Por qué el CHECK y no sólo la validación?

Porque la validación corre en un proceso Ruby, fuera de cualquier lock, y bajo
concurrencia no garantiza nada. El CHECK lo evalúa el motor en el mismo momento de
la escritura. Es el mismo argumento que el índice único contra
`validates_uniqueness_of`.

### ¿Cómo evitás que un carrito abandonado te coma el stock?

Toda reserva **nace con vencimiento**
(`StockReservation::DEFAULT_TTL = 30.minutes`,
`app/models/stock_reservation.rb:9`) y hay un job que barre las vencidas cada minuto
(`Stock::ExpireReservationsJob`, `config/recurring.yml`). Sin eso, en tres meses el
sistema dice que no tenés nada mientras el depósito está lleno.

### ¿Por qué `CommitReservation` baja las dos cantidades a la vez?

Porque si hicieras "release + issue" en dos pasos, entre uno y otro el stock quedaría
**disponible** por un instante y otro proceso podría llevárselo. Por eso
`ApplyMovement` acepta `reserved_delta` y baja `quantity_on_hand` y
`quantity_reserved` en la misma escritura
(`app/services/stock/commit_reservation.rb:49-60`). `quantity_available` no cambia:
ya estaba descontada desde la reserva.

### ¿Por qué procesás en lotes con una transacción por ítem?

Porque una transacción larga en Postgres mantiene locks todo ese tiempo, **frena el
VACUUM** (no puede limpiar tuplas más nuevas que ella, la tabla se hincha) y si falla
al final perdés todo el trabajo. `Stock::ExpireReservations`
(`app/services/stock/expire_reservations.rb:37-45`) usa `in_batches` y una
transacción por reserva.

### ¿Cómo testeás concurrencia de verdad?

Con **threads reales y conexiones distintas**, y desactivando las transactional
fixtures (si el test corre dentro de una transacción sin commitear, los otros
threads no ven los datos y el test es un falso verde).
`spec/integration/concurrency_spec.rb` hace exactamente eso: 8 threads pidiendo 3
unidades sobre 10 → exactamente 3 éxitos, 5 fallos, `quantity_on_hand == 1` y la
reconciliación vacía.

**Si repreguntan:** por eso `config/database.yml:101` le pone `max_connections: 15` a la
base de test: con el pool en 5, el sexto thread se queda esperando y el test falla
con `ConnectionTimeoutError` — que es justamente el síntoma que verías en producción
si dimensionás mal el pool.

---

## 7. Colas, jobs y mensajería

### ¿Qué es Active Job y con qué se compara?

Una **fachada / SPI**, no una implementación: escribís el job una vez y elegís el
adapter por configuración (`config/initializers/active_job.rb`). Es el rol de JMS en
Java. El precio de la abstracción: expone el mínimo común denominador, así que
features propias de Sidekiq (batches, unique jobs) exigen heredar de `Sidekiq::Job`
y perder portabilidad.

### Sidekiq vs Solid Queue: ¿cómo elegís?

| Aspecto | Sidekiq (Redis) | Solid Queue (Postgres) |
|---|---|---|
| Latencia | ~1 ms (BRPOP bloqueante) | 100 ms – 1 s (polling) |
| Throughput | decenas de miles/s | miles/s |
| Durabilidad | según la config de Redis | ACID, igual que tus datos |
| Enqueue transaccional | ❌ va a Redis ya mismo | ✅ mismo COMMIT que el negocio |
| Infra extra | Redis | ninguna |

**El punto transaccional es el más importante y el menos conocido.** Con Sidekiq, un
`perform_later` dentro de una transacción encola en Redis inmediatamente; si después
hay rollback, el job procesa una orden que no existe.

**Si repreguntan:** `enqueue_after_transaction_commit = :always` lo arregla para
cualquier adapter, y está activo en este repo.

### ¿Cuáles son las dos reglas de oro de los jobs?

1. **Pasá ids, no objetos.** Un objeto serializado tiene estado viejo, infla el
   payload y, si el registro se borró, explota con `DeserializationError` **antes**
   de tu código. Con el id releés el estado actual y decidís.
2. **Todo job tiene que ser idempotente**, porque la garantía es at-least-once.

Ambas están en `app/jobs/application_job.rb:17-38`.

### ¿Qué es at-least-once y por qué no existe exactly-once?

Si el proceso muere después de hacer el trabajo y antes de marcarlo como hecho, se
reintenta y se ejecuta dos veces. Evitarlo requeriría commitear atómicamente en dos
sistemas distintos, o sea transacciones distribuidas. Lo que sí existe es
**at-least-once delivery + idempotent processing**, que es lo que la gente quiere
decir cuando dice exactly-once. Por eso cada evento del outbox lleva un `event_id`
UUID y el consumidor deduplica (`app/jobs/outbox/publish_pending_job.rb:12-17`).

### ¿Cómo funciona una cola sobre SQL?

`SELECT ... FOR UPDATE SKIP LOCKED`: bloqueo exclusivo de las filas seleccionadas y
**salteá** las que ya están tomadas. N workers hacen la misma query en paralelo y
cada uno se lleva un lote distinto, sin coordinación externa, sin Redis y sin
deadlocks (`app/models/outbox_event.rb:27-33`). Es lo que usan Solid Queue, Que y
GoodJob por debajo. Sin `SKIP LOCKED`, el worker 2 esperaría al 1 y la cola se
serializaría.

### ¿Se garantiza el orden de los eventos?

No globalmente. Procesamos `ORDER BY id`, pero con varios workers y `SKIP LOCKED` el
worker A puede terminar el evento 5 después que B el 6. Si necesitás orden **por
agregado** —y en stock lo necesitás— hay que particionar por `aggregate_id`: mismo
agregado, mismo worker. Es exactamente el rol de la partition key en Kafka.

### ¿Cómo configurás los reintentos?

`retry_on` con `wait: :polynomially_longer` para errores transitorios
(deadlock, lock timeout, conexión) y `discard_on` para errores permanentes:
reintentar un `RecordNotFound` 25 veces es desperdicio, el registro no va a
reaparecer (`app/jobs/application_job.rb:52-66`). Si retryás todo, la cola se tapa
con basura.

**Si repreguntan:** el backoff necesita **jitter**, o 1000 jobs que fallaron juntos
reintentan en el mismo instante y vuelven a tumbar el servicio apenas se levanta
(*thundering herd*). Rails aplica ~15% por defecto
(`ActiveJob::Base.retry_jitter`).

### ¿Qué es un poison message y cómo lo manejás?

Un mensaje que siempre falla y tapa la cola. En el relay del outbox, el `rescue`
está **adentro del `each`**: un evento roto se marca con `mark_failed!` y el lote
sigue (`app/jobs/outbox/publish_pending_job.rb:48-56`). Después de
`MAX_ATTEMPTS = 10` el evento sale del lote (scope `stuck`). En Sidekiq el
equivalente es la **DLQ** (Dead set) más un `death_handler` que loguea
(`config/initializers/sidekiq.rb`). Una cola sin DLQ pierde trabajo en silencio.

---

## 8. Rate limiting

### ¿Qué algoritmos de rate limiting conocés y cuál usa Rack::Attack?

Rack::Attack usa **ventana fija**: el período se calcula como
`Time.now.to_i / period`, alineado al reloj absoluto. Su defecto es el **borde de
ventana**: con 100/minuto podés mandar 100 a las 12:00:59 y 100 a las 12:01:00 → 200
en un segundo sin violar la regla. Alternativas: sliding window log (exacto, O(n) por
cliente), sliding window counter (interpola, lo usa Cloudflare) y **token bucket**
(permite ráfagas controladas, lo usan Stripe y AWS; se implementa en Redis con Lua
para que sea atómico).

### ¿Por qué dos capas de rate limiting?

Porque miden cosas distintas. **Rack::Attack** corre en el borde, antes de instanciar
el controller y de tocar la base: una request bloqueada cuesta ~0.1 ms. Pero sólo
conoce la IP y los headers. **`rate_limit` de Rails 8** corre después de autenticar,
así que puede limitar por usuario, plan o tenant — cuesta más, pero es el único lugar
donde tenés esa información
(`app/controllers/api/v1/base_controller.rb:20-38`).

### ¿Cuál es el discriminador correcto y cuál es el error clásico?

Depende de qué querés proteger. Para login, **dos límites en paralelo**: por IP
(frena credential stuffing) y por email (frena el ataque distribuido de un botnet
contra una cuenta, donde cada IP hace 2 requests y el límite por IP no lo ve).
Necesitás los dos: cubren amenazas distintas
(`config/initializers/rack_attack.rb:160-180`). Para la API, por **token**, no por
IP: los clientes están detrás de NAT y compartirían el contador.

**Si repreguntan:** el token se hashea antes de usarlo como clave, para no dejar
secretos en Redis, en logs ni en dashboards.

### ¿Por qué el store no puede ser un `MemoryStore`?

Porque cada worker de Puma tendría su propio contador: con 4 workers un límite de 100
se convierte en 400, y encima inconsistente. El store tiene que ser **compartido y
atómico** (Redis `INCR`, memcached). Solid Cache sobre Postgres funciona, pero son
1-2 escrituras por request contra tu base principal.

**Si repreguntan:** hay un fallo silencioso peor. `rate_limit` hace
`store.increment(...)`; un `NullStore` devuelve `nil`, la comparación
`count && count > to` nunca se cumple y **el límite queda desactivado sin un solo
mensaje**. Por eso el store se elige explícitamente y se avisa
(`app/controllers/api/v1/base_controller.rb:40-57`).

### Contame una trampa real de `rate_limit` de Rails 8.

La clave del contador se arma así (actionpack 8.1, `rate_limiting.rb:72-77`):

```ruby
cache_key = ["rate-limit", scope, name, by].compact.join(":")
count = store.increment(cache_key, 1, expires_in: within)
if count && count > to
```

y `scope` por defecto es `controller_path`. Si declarás **dos**
`rate_limit` que aplican al mismo controller sin pasar `name:`, generan **la misma
clave**: comparten contador y cada request lo incrementa **dos veces**. Un límite de
20 corta en 10. Está documentado, con la medición, en
`app/controllers/api/v1/base_controller.rb:59-74`. La solución es dar `name:`
distinto a cada límite.

### ¿Qué devolvés cuando bloqueás?

429 con `Retry-After` y las cabeceras `RateLimit-*` (RFC 9331). Un 429 sin cabeceras
es hostil: el cliente no sabe cuánto esperar y reintenta en loop, empeorando todo
(`config/initializers/rack_attack.rb:230-254`).

**Si repreguntan:** antes de activar un límite nuevo en producción se lo deja en
`track` (mide sin bloquear) un par de semanas, para ver cuántos clientes legítimos lo
habrían tocado. Activar a ciegas es la forma más rápida de romperle la integración a
un cliente.

---

## 9. Testing

### ¿Qué forma tiene tu pirámide de tests en Rails?

Más ancha en el medio que la pirámide clásica. En Rails los tests de **servicio**
(caso de uso con base de datos real) dan la mejor relación cobertura/costo, porque el
ORM y las constraints son parte del comportamiento y mockearlos te deja probando
mentiras. Arriba, pocos tests de sistema; abajo, unitarios puros para value objects y
`Result`.

**Si repreguntan:** los números de este repo:

```bash
$ bundle exec rspec --dry-run
325 examples, 0 failures
$ cat coverage/.last_run.json
{ "result": { "line": 79.07, "branch": 57.27 } }    # línea vs rama
```

### Factories vs fixtures.

Fixtures: un dataset global YAML, rapidísimo (se carga una vez) pero acoplado —
cambiar una fila rompe tests que ni sabías que la usaban. Factories: cada test
construye lo que necesita, explícito y legible, más lento. Con FactoryBot hay traits
y secuencias; el equivalente Java son los Object Mother / builders.

**Si repreguntan:** `build_stubbed` es el punto medio olvidado: te da un objeto con
id y asociaciones sin tocar la base.

### ¿Cuándo mockear y cuándo no?

Mockeá lo que está **fuera de tu control** (HTTP externo, el reloj, el broker). No
mockees tu propia base de datos ni tus propios objetos de dominio: terminás
verificando que llamaste a un método, no que el sistema hace lo correcto.

**Si repreguntan:** para el outbox usamos un **Null Object** real
(`app/services/outbox/null_recorder.rb`) en vez de un `double`: es código de verdad,
así que si el contrato de `record(...)` cambia, el test falla; un doble flexible
seguiría dando verde en falso.

### ¿Qué son las transactional fixtures y cuándo fallan?

Cada ejemplo corre dentro de una transacción que se revierte al terminar: el rollback
es O(1), muchísimo más rápido que truncar. **Fallan** cuando el código bajo test corre
en otro hilo con otra conexión (tests de concurrencia, system tests con un server
aparte): ese hilo no ve tus datos sin commitear. Por eso los specs de concurrencia lo
desactivan explícitamente (`spec/rails_helper.rb:37-45`).

### ¿Qué hace flakey a un test y cómo lo arreglás?

Cuatro causas típicas: dependencia del **orden** (estado global no limpiado — por eso
`Current.reset` y `Rails.cache.clear` antes de cada ejemplo,
`spec/rails_helper.rb:75-78`), dependencia del **tiempo** (usá `travel_to` /
`freeze_time`, nunca `sleep`), dependencia de la **red** (WebMock) y **carreras** en
tests de browser (esperá por condición, no por tiempo).

### ¿Cobertura del 100%?

No. La cobertura te dice qué **no** probaste; no te dice si lo que probaste está
bien. Un 100% de líneas con asserts triviales es peor que un 75% con tests que
ejercitan las invariantes. Mirá la cobertura de **rama**, que es la que se olvida:
acá es 57.27% contra 79.07% de línea, y esa brecha son los `if` sin el camino
alternativo probado.

### ¿Cómo probás que no hay N+1?

Con Bullet activado en test y un tag que hace fallar el ejemplo
(`spec/rails_helper.rb:62-70`). Es la única forma de que un N+1 no se cuele: que el
CI falle.

### ¿TDD sí o no?

Sí donde el diseño no está claro y las reglas son enredadas —el dominio de stock es
exactamente eso— y no donde estás explorando una API ajena. En este repo hay dos bugs
que aparecieron **escribiendo el test**, no después: el scoping por usuario de las
claves de idempotencia y la corrección de la deriva que nunca convergía.

---

## 10. Seguridad (OWASP aplicado a Rails)

### SQL injection: ¿dónde sigue siendo posible en Rails?

`where(sku: params[:sku])` es seguro. Lo peligroso es la interpolación en fragmentos
crudos: `where("name = '#{params[:q]}'")`, `order(params[:sort])`,
`pluck(params[:col])`, `group`, `having`, `joins` con string. Este repo usa binds con
nombre (`app/queries/products/search.rb:64`) y una **allow-list** para el ordenamiento
(`SORTS` en `app/queries/products/search.rb:25-30`) — nunca `order(params[:sort])`.

**Si repreguntan:** además `sanitize_sql_like` escapa `%` y `_` del input, porque un
usuario que escribe `%` te fuerza un escaneo completo de la tabla: DoS barato.

### ¿Y `Arel.sql`?

Es la escotilla que le dice a Rails "confiá en este string". Está bien para SQL
**literal y escrito por vos** (`Arel.sql("SUM(quantity_on_hand)")`,
`app/queries/stock_items/availability.rb:39`), y es un agujero si adentro hay algo
que viene de `params`.

### XSS en Rails: ¿qué te protege y qué no?

ERB escapa por defecto. Lo que **no** te protege: `raw`, `html_safe`,
`sanitize` mal configurado, y meter datos del usuario en un atributo `href` o en un
bloque `<script>`. Un `link_to` con href controlado por el usuario permite
`javascript:`.

**Si repreguntan:** la Content Security Policy
(`config/initializers/content_security_policy.rb`) es la segunda línea, y limita el
daño cuando la primera falla.

### ¿Por qué la API no tiene protección CSRF y la web sí?

Porque CSRF funciona gracias a que el browser **adjunta la cookie sola**. Un header
`Authorization` no se adjunta solo, así que una API stateless con Bearer token no es
vulnerable. La desactivación es legítima **sólo** porque no usamos cookies ahí
(`app/controllers/concerns/api/token_authentication.rb:9-16`). Desactivar CSRF
"porque molesta" en un controller con sesión es un agujero grave.

### ¿Cómo guardás un token de API?

Sólo el **digest**. El token en claro existe una vez, en el objeto que devuelve
`ApiToken.issue!` (`app/models/api_token.rb:35-48`); después sólo queda
`token_digest`. Es cómo funcionan los personal access tokens de GitHub.

**Si repreguntan:** SHA-256, **no** bcrypt, y hay que saber justificarlo: bcrypt es
lento a propósito para defender secretos de baja entropía (contraseñas humanas). Un
token de 256 bits de `SecureRandom` no es fuerza-bruteable, y esto corre en **cada
request**. Para contraseñas, bcrypt vía `has_secure_password`.

### ¿Hace falta `secure_compare` para el token?

No acá, y saber por qué es la respuesta buena: hasheamos el input y buscamos por
**índice único** sobre el digest, así que nunca comparamos el secreto en Ruby. Sí
haría falta si compararas dos strings secretos con `==`, porque el `==` corta en el
primer byte distinto y filtra información por timing.

### ¿Cómo evitás el agujero de "me olvidé de autorizar"?

`verify_authorized` / `verify_policy_scoped` en un `after_action`
(`app/controllers/api/v1/base_controller.rb:117-130`): explota si la acción no llamó
a `authorize`. Y el `Scope` por defecto devuelve `scope.none`
(`app/policies/application_policy.rb:57`): si te olvidás de definir `resolve`, no se
filtra información de más. **Deny by default** en las dos direcciones.

**Si repreguntan:** en dev/test explota; en producción sólo se loguea, para no tumbar
un endpoint por un olvido, pero la alerta queda. Y ojo: autorizar el `show` no sirve
de nada si el `index` te lista todo — por eso el `Scope`.

### ¿Qué es IDOR y cómo lo prevenís?

Acceder al recurso de otro cambiando el id en la URL. La prevención no es ocultar
ids, es **autorizar cada acceso** y filtrar las colecciones con `policy_scope`. Los
UUID ayudan a que no sea enumerable, pero no son control de acceso.

### ¿Qué te dice Brakeman de este repo?

Corrido ahora, en este repo:

```bash
$ bundle exec brakeman -q --no-pager
Rails Version: 8.1.3.1   Brakeman Version: 8.0.6
Controllers: 20   Models: 22   Templates: 34   Errors: 0
Security Warnings: 0
No warnings found
```

Es el equivalente a SpotBugs/Find-Sec-Bugs, y corre en CI
junto con `bundler-audit`, que chequea el `Gemfile.lock` contra la Ruby Advisory DB
(el OWASP dependency-check de Ruby).

**Si repreguntan:** Brakeman detecta automáticamente cosas como el regex con `^`/`$`
en vez de `\A`/`\z`, que en Ruby son anclas de **línea** y dejan pasar
`"VALIDO\n<script>..."`. Por eso el formato del SKU usa `\A...\z`
(`app/models/product.rb:48-50`).

---

## 11. Performance y memoria

### La app está lenta. ¿Cuál es tu primer paso?

**Medir, no adivinar.** Orden: (1) ¿es la app o la base? Mirá `pg_stat_activity` y
`pg_stat_statements`; (2) ¿es una request o todas? El APM te da el p95 por endpoint;
(3) dentro de la request, ¿SQL o Ruby? `rack-mini-profiler` te lo desglosa; (4) si es
Ruby, `stackprof`. Subir `RAILS_MAX_THREADS` **no** es un paso, es una forma de
empeorar la latencia por el GVL.

### ¿Qué cacheás y con qué invalidación?

Lo caro y estable. Acá hay un ejemplo mínimo y correcto: `Warehouse.transit` es un
`Rails.cache.fetch` con TTL de 1 hora (`app/models/warehouse.rb:29-33`), porque el
depósito de tránsito casi nunca cambia y se lee en cada transferencia.

**Si repreguntan:** para vistas, **russian doll caching** con claves basadas en
`updated_at` (`cache [product, :row]`): la invalidación es implícita, que es la única
que no se olvida nadie. Y siempre TTL además de la clave, como red.

### ¿`pluck` o cargar modelos?

`pluck` cuando sólo necesitás los valores: no instancia objetos ActiveRecord. Para
decenas de miles de filas la diferencia es de cientos de MB de RAM. Por eso
`StockItems::Availability` devuelve un Hash con `pluck` + `to_h`
(`app/queries/stock_items/availability.rb:37-45`) y no una colección de modelos.

### ¿Cómo procesás una tabla grande sin volar la memoria?

`find_each` / `in_batches`, que paginan por **PK** (`WHERE id > ?`), no con OFFSET:
O(1) por lote sin importar el volumen. `in_batches` + `delete_all` va directo al SQL
sin instanciar modelos ni correr callbacks, que es lo que querés en una limpieza
(`app/jobs/cleanup/expired_records_job.rb:43-49`).

### OFFSET vs keyset pagination.

`OFFSET 100000 LIMIT 20` obliga a Postgres a generar y descartar 100.000 filas: el
costo crece con el número de página, y si alguien inserta mientras paginás ves filas
repetidas. **Keyset** salta directo con el índice, es O(log n) para cualquier página, y como
el cursor apunta a una fila concreta insertar no desplaza nada
(`app/queries/stock_movements/ledger.rb:76-83`):

```sql
SELECT * FROM stock_movements
WHERE (occurred_at, id) < ($1, $2)          -- comparación de TUPLAS, SQL estándar
ORDER BY occurred_at DESC, id DESC
LIMIT 20;                                    -- usa index_stock_movements_ledger
```

Contra: no podés saltar a la página 37 —
irrelevante en un ledger.

**Si repreguntan:** el cursor se devuelve en Base64 de un JSON para que sea **opaco**:
si el cliente no puede adivinar qué hay adentro, no se rompe cuando cambiás el
criterio de orden.

### ¿Por qué el proceso Ruby crece y no baja?

Dos causas distintas. Si `GC.stat[:heap_live_slots]` crece, es un leak de objetos
(referencias globales, caches sin límite). Si está estable y el RSS igual sube, es
**fragmentación del allocator de C**: glibc crea una arena por thread y la memoria
liberada queda en huecos que no vuelven al SO. `MALLOC_ARENA_MAX=2` o jemalloc.

**Si repreguntan:** el piso medido para este repo es ~95 MB de RSS por worker de Puma
antes de servir una request. Con 4 workers, 380 MB. En Java pagás ese costo una vez
para todos los threads; en Ruby lo pagás N veces, salvo por copy-on-write con
`preload_app!`.

---

## 12. Preguntas de diseño en vivo

Para cada una, un esqueleto de cinco puntos. Decilo en ese orden: te da estructura,
te deja pausas para que el entrevistador redirija, y demuestra que pensás en
trade-offs y no en features.

### "Diseñá un sistema de control de stock."

1. **Modelo y unidad de consistencia.** `products` × `warehouses` → `stock_items`,
   una fila por par. Esa fila es el agregado: toda operación que cambia stock bloquea
   exactamente una. Da serialización donde hace falta y paralelismo total entre pares
   distintos.
2. **Ledger append-only + proyección.** `stock_movements` es inmutable y guarda el
   hecho (`kind`, `quantity` con signo, `quantity_after`, quién, cuándo, contra qué
   referencia). `stock_items.quantity_on_hand` es la proyección para leer rápido.
   Nunca "seteo un valor": registro un hecho.
3. **Disponible ≠ físico.** `quantity_available` es una columna **generada**
   `on_hand - reserved`. Las reservas nacen con TTL y hay un job que las expira; sin
   eso, los carritos abandonados te comen el inventario.
4. **Invariantes en la base.** CHECK `quantity_on_hand >= 0`,
   `quantity_reserved <= quantity_on_hand`, índice único `(product_id,
   warehouse_id)`, FKs con `on_delete: :restrict` para no borrar historia contable.
5. **Auditoría y salida de eventos.** Reconciliación nocturna proyección vs suma del
   ledger —si difieren, hay un bug y quiero que suene la alarma, no que se
   autocorrija— y outbox transaccional para publicar los eventos de dominio.

### "¿Cómo evitás vender más de lo que tenés?"

1. **Un solo punto de escritura.** `Stock::ApplyMovement` es el único lugar del
   sistema que cambia una cantidad; todo lo demás delega. Si mañana hay que agregar
   una regla a toda operación de stock, se toca un archivo.
2. **Lock pesimista de fila y validar después de bloquear.** `SELECT ... FOR UPDATE`
   sobre el `stock_item`; el segundo espera en el SELECT y lee el saldo real. READ
   COMMITTED no alcanza porque el cálculo lo hago en Ruby con un valor viejo.
3. **CHECK constraint como última red**, porque una validación de Rails corre fuera
   del lock y no es atómica.
4. **Reservas para la ventana de checkout**, con TTL y expiración automática, y
   commit atómico que baja `on_hand` y `reserved` juntas (si hiciera release + issue,
   entre los dos pasos el stock queda disponible y otro se lo lleva).
5. **Verificación continua.** Tests de concurrencia con threads reales (8 threads × 3
   unidades sobre 10 → exactamente 3 éxitos) y reconciliación nocturna. El trade-off
   que menciono solo: serializo por SKU; si un SKU se vuelve fila caliente, paso a un
   UPDATE condicional de una sentencia.

### "¿Cómo hacés que una API de escritura sea segura ante reintentos?"

1. **La clave la genera el cliente** (`Idempotency-Key`, un UUID), porque sólo él sabe
   que dos requests son el mismo intento. El servidor no puede inferirlo: dos ingresos
   idénticos de 10 unidades pueden ser legítimamente dos ingresos.
2. **Fingerprint del body.** Misma clave + body distinto → 422. Sin eso, un cliente
   con la clave fija recibe en silencio el resultado de otra operación.
3. **Scope de la clave.** Prefijada por usuario, o el índice único global hace que el
   usuario B reciba el movimiento del usuario A: fuga de información **y** pérdida de
   datos.
4. **Concurrencia con índice único.** El INSERT en estado `processing` es la sección
   crítica: la segunda request pierde contra el índice y devuelve 409 "hay una en
   vuelo", en vez de ejecutar dos veces. Es un lock distribuido sin Redis.
5. **Qué se cachea y por cuánto.** Sólo respuestas 2xx (cachear un 500 sería
   devolverlo para siempre), con TTL de 24 h y un job de limpieza. Y el mismo
   mecanismo hacia abajo: la clave viaja al service y al ledger, así que la
   idempotencia es de punta a punta, no sólo del lado HTTP.

### "¿Cómo migrás una columna sin downtime?"

1. **Por qué duele.** En Postgres muchas operaciones de DDL toman `ACCESS EXCLUSIVE`,
   que bloquea hasta los SELECT. Peor: el lock **se encola**, así que una migración
   esperando deja atrás una fila de queries y el sitio se cae **antes** de que la
   migración empiece.
2. **Expand-contract, cuatro deploys.** Columna nueva → escribir en las dos →
   backfill en lotes → leer de la nueva → borrar la vieja. Nunca `rename_column`.
3. **Backfill aparte del DDL**, en lotes, sin transacción envolvente, para que el
   autovacuum siga al día.
4. **Índices con `algorithm: :concurrently`** y `disable_ddl_transaction!`. Tarda el
   doble y puede dejar un índice inválido si falla, pero no bloquea escrituras.
5. **Barandas automáticas.** `strong_migrations` te frena en desarrollo con el
   reemplazo seguro escrito en el mensaje de error, y `lock_timeout` de 10 s hace que
   una migración que no consigue el lock **aborte** en vez de encolarse
   (`config/initializers/strong_migrations.rb`). Para borrar una columna, primero
   `ignored_columns` y deploy, después el `remove_column`. El detalle de cómo se
   orquesta esto en el deploy está en `docs/14-deploy-y-operacion.md`.

---

## 13. Preguntas para hacerle vos al entrevistador

Preguntar bien te posiciona como par, no como candidato. Estas son concretas y las
respuestas te dicen mucho:

- **"¿Cómo es el ciclo de deploy? ¿Cuántas veces por día deployan y quién puede
  hacerlo?"** Te dice el nivel de automatización real, más que cualquier respuesta
  sobre "cultura DevOps".
- **"¿Cuánto tarda la suite de tests y qué porcentaje de los builds fallan por tests
  flakey?"** Si no saben el número, no la miran.
- **"¿Qué pasa hoy si una migración toma un lock largo en la tabla más grande?"**
  Directo al corazón de si tienen `strong_migrations`, `lock_timeout` y un runbook.
- **"¿Tienen `pg_stat_statements` activo? ¿Cuál es la query más cara del sistema y
  hace cuánto que lo es?"**
- **"¿Cómo manejan la idempotencia en las escrituras de la API pública?"** Si la
  respuesta es "los clientes no reintentan", ya sabés qué te espera.
- **"¿Qué parte del código les gustaría reescribir y qué se los impide?"** La
  respuesta más honesta que vas a escuchar en toda la entrevista.
- **"¿Cómo se toma la decisión de sumar una gema o un servicio nuevo?"** Distingue
  equipos con criterio de equipos con currículum-driven development.
- **"¿Cuál fue el último incidente de producción y qué cambió después?"** Si no
  cambió nada, los incidentes se van a repetir.

---

## Errores que ves en producción

Cada uno con el **síntoma** (lo que reporta el usuario o el monitoreo) y el
**arreglo**. Son los que efectivamente aparecen en este dominio.

| Síntoma | Causa | Arreglo |
|---|---|---|
| Stock negativo, o vendiste 14 de 10 unidades | Lost update: leíste, calculaste en Ruby, escribiste, sin lock | `SELECT ... FOR UPDATE` **antes** de validar (`app/services/stock/apply_movement.rb:102`) + CHECK `quantity_on_hand >= 0` |
| El sistema dice que no hay stock y el depósito está lleno | Reservas sin TTL o el job de expiración no corre | TTL obligatorio (`StockReservation::DEFAULT_TTL`) + `Stock::ExpireReservationsJob` cada minuto; alertar si no corrió |
| "Deadlock detected" intermitente e irreproducible | Dos transacciones toman locks en orden distinto | Orden total: `ORDER BY id` en el `FOR UPDATE` (`app/services/stock/transfers/dispatch.rb:99`) y orden fijo entre tablas |
| El cliente cobró/recibió dos veces tras un timeout | Escritura no idempotente | `Idempotency-Key` + fingerprint + clave scopeada por usuario (`app/controllers/concerns/api/idempotency.rb`) |
| Dos comprobantes con el mismo número | El **query cache** de Rails cachea un `INSERT ... RETURNING` ejecutado con `select_value` | `connection.uncached { ... }` + `clear_query_cache` (`app/models/sequence_counter.rb:47-48`) |
| Un rate limit de 20 corta en 10 | Dos `rate_limit` sin `name:` comparten clave y cuentan doble | `name:` distinto por límite (`app/controllers/api/v1/base_controller.rb:59-79`) |
| El rate limiting "no limita nada" y no hay error | `NullStore`: `increment` devuelve `nil` y la comparación nunca se cumple | Elegir el store explícitamente y avisar si no sirve |
| Un usuario abusa y bloquea a todos | `Rack::Attack` insertado antes de `RemoteIp`: `request.ip` es la IP del balanceador | `insert_after ActionDispatch::RemoteIp` (`config/application.rb:52`) + `trusted_proxies` |
| Un job procesa un registro que no existe | `perform_later` dentro de una transacción que después hizo rollback | `enqueue_after_transaction_commit = :always`; para eventos que no se pueden perder, outbox |
| La cola se tapa y los jobs buenos no entran | Poison message reintentado infinito, o `retry_on` para todo | `rescue` por ítem + `mark_failed!`, `discard_on` para errores permanentes, DLQ |
| El evento salió pero el estado no cambió (o al revés) | Dual write: base y broker sin transacción común | Outbox: el evento se escribe en la misma transacción y un relay lo publica |
| Un endpoint nuevo queda abierto a todo el mundo | Alguien se olvidó de `authorize` | `verify_authorized` en `after_action` + `Scope#resolve = scope.none` por defecto |
| Un listado devuelve el mismo producto dos veces | Orden por columna no única sin desempate | Desempatar siempre por `id` (`SORTS` en `app/queries/products/search.rb:25-30`) |
| Página 1 vuela, página 5000 tarda segundos | `OFFSET` grande | Keyset pagination con comparación de tuplas |
| El endpoint tarda 6 s con 200 productos | N+1 de agregación; `includes` no lo arregla | Una query con `GROUP BY` y pasar el resultado precalculado al serializer |
| Una búsqueda con `%` tumba la base | `ILIKE` con comodín del usuario, sin escapar | `sanitize_sql_like` + índice GIN trigram |
| `PG::ConnectionBad: sorry, too many clients` | Pool por proceso × threads × bases × pods contra `max_connections` | Dimensionar el pool, PgBouncer en transaction pooling |
| El RSS sube y no baja, sin leak de objetos | Fragmentación del allocator de C | `MALLOC_ARENA_MAX=2` o jemalloc; reiniciar workers por RSS |
| Un campo interno nuevo aparece en la API pública | `render json: modelo` serializa todas las columnas | Serializers POROs explícitos |
| El valor que guardaste "no se guardó" y no hubo error | Escribiste una columna **generada**: Rails la excluye del UPDATE y no avisa | Nunca asignarla; `reload` después de escribir para leerla |
| Un job recurrente corre 10 veces por noche | `crontab` replicado en 10 servidores | Scheduler con líder único (`config/recurring.yml` de Solid Queue) |
| El reporte diario salió con 3 horas de diferencia | La zona horaria del scheduler es `Time.zone` de la app | Fijar `config.time_zone` explícitamente y pensar el cron en esa zona |

---

## Cómo responder esto en una entrevista

**"Contame el proyecto en dos minutos."**

> Es un control de stock en Rails 8.1 sobre Postgres 16. El núcleo son dos cosas: un
> **ledger inmutable** de movimientos y una **proyección** por par producto/depósito
> que es la unidad de consistencia — toda operación que cambia stock bloquea
> exactamente esa fila con `SELECT ... FOR UPDATE`. Encima hay una capa de casos de
> uso que devuelven un `Result` en vez de lanzar excepciones para reglas de negocio,
> query objects para las consultas, policies de Pundit para autorización y
> serializers POROs para el contrato de la API. Las escrituras de la API son
> idempotentes con `Idempotency-Key`, y los eventos de dominio salen por un outbox
> transaccional. La invariante la garantizan CHECK constraints en la base, no
> validaciones de Rails, y hay una reconciliación nocturna que compara la proyección
> contra la suma del ledger.

**"Venís de Java. ¿Qué te costó más de Rails y qué asumiste mal?"**

> Asumir que ActiveRecord es JPA. No hay sesión de persistencia, no hay entidades
> detached y no hay dirty checking diferido: cada `save` es un UPDATE ahí mismo, y
> tocar una asociación dispara una query **en ese instante**, no en un flush. Eso
> cambia dos cosas prácticas: el N+1 es trivial de crear y hay que atacarlo con
> `includes`/`preload` explícitos, y el optimistic locking se verifica en cada UPDATE
> —no al final de la transacción—, así que `update_all` lo saltea y hay que
> incrementar `lock_version` a mano si escribís SQL crudo.
>
> Lo segundo fue la concurrencia: en la JVM subís threads y ganás CPU; con el GVL de
> CRuby, no. Medido acá: 4 threads en trabajo CPU-bound dan 1.53 s contra 1.51 s
> secuencial. La unidad de paralelismo es el proceso, y eso tiene un efecto dominó —
> el pool de conexiones es por proceso, una caché en memoria son N copias, y un rate
> limiter con `MemoryStore` multiplica tu límite por la cantidad de workers.

**"¿Cómo decidís entre poner algo en el modelo, en un service o en un query object?"**

> Por la pregunta que responde. **Modelo**: "qué es un stock item" — lecturas,
> invariantes simples, escrituras de bajo nivel. **Service**: "qué operación de
> negocio estoy ejecutando" — necesita transacción, lock, ledger, evento y devuelve un
> `Result`. **Query object**: "cómo busca esta pantalla" — filtros combinables,
> agregaciones, y devuelve una Relation para que el que llama todavía pueda paginar.
>
> El criterio operativo: si el nombre de la clase necesita un "y", son dos clases. Y
> si algo del modelo sólo lo usa una pantalla, no es del modelo.

**"¿Cuál es la parte de este diseño que menos te convence?"**

> Dos. Una: serializo las escrituras por par producto/depósito. Es correcto y es
> barato mientras el tráfico esté repartido, pero un SKU que se vuelve fila caliente
> es un cuello de botella; ahí pasaría a un UPDATE condicional de una sola sentencia
> —que ya está implementado en `StockItem.atomically_decrement`— o a partir el saldo
> en varias filas y sumarlas.
>
> Dos: la proyección es redundante con el ledger, así que existe la posibilidad de
> deriva. La mitigo con reconciliación nocturna que **alerta y no autocorrige**,
> porque una deriva es un bug y autocorregirla lo esconde. Pero es complejidad real
> que hay que justificar: si el negocio no necesitara auditoría contable, con la
> proyección sola alcanzaría.

**"¿Qué hacés en los primeros 30 días en un sistema legacy que no conocés?"**

> Primero, hacer que el sistema me hable: `pg_stat_statements`, logs estructurados,
> APM y `bullet` en test si no está. No toco nada hasta poder medir.
>
> Segundo, buscar las invariantes que **no** están en la base: un `validates_uniqueness_of`
> sin índice único, un saldo sin CHECK, una escritura de dinero en Float. Ese es el
> inventario de bugs latentes, y arreglarlo es barato comparado con el costo cuando
> explota.
>
> Tercero, un test de caracterización de la operación más crítica antes de refactorizar
> nada. Y recién ahí, cambios chicos y reversibles. La trampa clásica es llegar con la
> arquitectura ideal en la cabeza; la arquitectura que importa es la que el equipo
> puede sostener el martes a la mañana.

---

## Para seguir

- Fundamentos de Ruby y el contraste con Java: `docs/00-ruby-y-rails-para-javeros.md`
- Capas y flujo de una request: `docs/01-arquitectura.md`
- Gema por gema, con el equivalente Java: `docs/02-dependencias-y-gemas.md`
- ActiveRecord, migraciones y constraints: `docs/03-base-de-datos-y-activerecord.md`
- N+1, índices y `EXPLAIN`: `docs/04-optimizacion-de-queries.md`
- SOLID y patrones aplicados: `docs/05-solid-y-patrones.md`
- Locks, aislamiento y deadlocks: `docs/06-concurrencia-transacciones-y-locking.md`
- Colas, outbox y reintentos: `docs/07-colas-jobs-y-mensajeria.md`
- Rate limiting en detalle: `docs/08-rate-limiting.md`
- Testing: `docs/09-testing.md`
- Los 16 errores con su reproducción: `docs/10-errores-comunes.md`
- API, serialización e idempotencia: `docs/11-api-rest-serializacion-e-idempotencia.md`
- Seguridad: `docs/12-seguridad.md`
- Observabilidad y performance: `docs/13-observabilidad-y-performance.md`
- Deploy, entornos y operación: `docs/14-deploy-y-operacion.md`
