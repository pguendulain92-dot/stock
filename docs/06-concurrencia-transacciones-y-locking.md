# Concurrencia, transacciones y locking

Este es **el** documento del dominio. Un sistema de stock es, esencialmente, un
problema de concurrencia disfrazado de CRUD: el 90% del código es aburrido y el
10% que decide si vendés 14 unidades de las 10 que tenés está todo acá.

Vas a encontrar: los niveles de aislamiento de PostgreSQL 16 con las anomalías
que previene cada uno (y las que **no**), el timeline exacto de un *lost update*
con el SQL de cada paso, las tres estrategias de locking implementadas en este
repo con el código real, cómo se producen y se evitan los deadlocks (con un
deadlock de verdad que provoqué en esta base), las trampas de las transacciones
anidadas en Rails, el modelo de concurrencia de Ruby (GVL, Puma, `Current`) y
cómo se testea todo esto con threads reales.

Escrito para vos, que venís de Spring + JPA/Hibernate. Cada sección marca dónde
la analogía con Java **se rompe**, porque ahí es donde se pierde el tiempo (o el
inventario). Todo lo que se afirma acá está o citado del repo con archivo y
línea, o verificado corriéndolo contra `stock_development` (PostgreSQL 16.13,
Ruby 3.3.6, Rails 8.1.3.1).

---

## 0. Mapa: dónde vive cada cosa

| Concepto | Archivo | Qué mirar |
|---|---|---|
| Lock pesimista de una fila | `app/services/stock/apply_movement.rb:103` | `StockItem.lock.find` |
| Lock pesimista de N filas, ordenado | `app/services/stock/transfers/dispatch.rb:99` | `.order(:id).lock` |
| `FOR UPDATE SKIP LOCKED` | `app/models/outbox_event.rb:32` | cola en SQL |
| `FOR UPDATE NOWAIT` | `app/models/application_record.rb:34` | `lock_or_fail!` |
| Optimistic locking | `app/models/stock_item.rb:22`, `app/models/product.rb:9` | `locking_column` |
| Optimistic locking sobre HTTP | `app/controllers/api/v1/products_controller.rb:56` | `lock_version` en el PATCH |
| UPDATE condicional atómico | `app/models/stock_item.rb:115` | `atomically_decrement` |
| CHECK constraints (última red) | `db/migrate/20260830160600_create_stock_items.rb:77` | 5 constraints |
| Transacción + traducción de errores | `app/services/application_service.rb:68` | `transactional` |
| Abortar sin `ActiveRecord::Rollback` | `app/services/application_service.rb:46` | `BusinessRuleViolation` |
| Efectos después del commit | `app/services/outbox/recorder.rb:47` | `after_all_transactions_commit` |
| Encolar después del commit | `app/jobs/application_job.rb` | `self.enqueue_after_transaction_commit = true` — estuvo mal puesto en un initializer, ver §7.1 |
| Lotes para evitar transacciones largas | `app/services/stock/expire_reservations.rb:37` | `in_batches` |
| Timeouts de sesión | `config/database.yml` | `lock_timeout`, `statement_timeout` |
| Tests de concurrencia reales | `spec/integration/concurrency_spec.rb` | 8 ejemplos con threads |
| Helper de threads + conexiones | `spec/support/concurrency.rb:25` | `run_concurrently` |

---

## 1. Aislamiento en PostgreSQL: lo que asumís mal viniendo de MySQL y de JPA

### 1.1 El default real de esta app

```bash
psql -d stock_development -c "show default_transaction_isolation;"
#  read committed
```

READ COMMITTED es el default de Postgres y el de este proyecto. No lo cambiamos
en `config/database.yml`: lo que sí seteamos ahí son los timeouts
(`lock_timeout: 10000`, `statement_timeout: 15000`,
`idle_in_transaction_session_timeout: 30000`), que son tanto o más importantes.

Verificado desde la app:

```ruby
# bin/rails runner
ActiveRecord::Base.connection.select_value("show transaction_isolation")  # => "read committed"
ActiveRecord::Base.connection.select_value("show lock_timeout")           # => "10s"
ActiveRecord::Base.connection.select_value("show statement_timeout")      # => "15s"
```

### 1.2 La tabla de anomalías, con la letra chica de Postgres

| Anomalía | READ COMMITTED | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| Dirty read (leer no commiteado) | ✅ imposible | ✅ imposible | ✅ imposible |
| Non-repeatable read | ❌ ocurre | ✅ prevenida | ✅ prevenida |
| Phantom read | ❌ ocurre | ✅ prevenida *(Postgres, no el estándar)* | ✅ prevenida |
| Lost update (read-modify-write en tu app) | ❌ **ocurre** | ⚠️ aborta la tx (`SerializationFailure`) | ⚠️ aborta la tx |
| Write skew / serialization anomaly | ❌ ocurre | ❌ **ocurre** | ✅ prevenida |

Tres cosas que hay que saber de memoria:

**1. Postgres NO tiene dirty read, ni siquiera si lo pedís.** `READ UNCOMMITTED`
se acepta sintácticamente pero se comporta exactamente como READ COMMITTED. La
razón es arquitectónica: con MVCC, una tupla no commiteada simplemente no es
visible para ningún otro snapshot. No hay forma de leerla. Si en una entrevista
te preguntan "¿cómo evitás dirty reads en Postgres?", la respuesta correcta es
"no hago nada, no existen".

**2. El REPEATABLE READ de Postgres es más fuerte que el del estándar SQL.** El
estándar sólo exige que prevenga non-repeatable reads; Postgres implementa
*snapshot isolation*, así que también te elimina los phantoms. No confundir con
MySQL (ver 1.5).

**3. En READ COMMITTED, el snapshot es por SENTENCIA, no por transacción.** Dos
`SELECT` iguales dentro de la misma transacción pueden devolver cosas distintas.
Esto es lo que hace posible el lost update de la sección 2.

### 1.3 El detalle de READ COMMITTED que decide el diseño del repo

Cuando un `UPDATE` en READ COMMITTED encuentra una fila que otra transacción ya
modificó pero todavía no commiteó, **espera**. Cuando la otra commitea, Postgres
no aborta: **re-evalúa el `WHERE` contra la versión nueva** (el mecanismo se
llama *EvalPlanQual*). Si la condición ya no se cumple, la fila no se actualiza.

Eso es exactamente lo que hace correcto a `StockItem.atomically_decrement`
(`app/models/stock_item.rb:115`): el `WHERE quantity_on_hand - quantity_reserved >= ?`
se vuelve a evaluar sobre el dato fresco. Es una garantía de READ COMMITTED, no
un truco.

Y es también lo que **no** te salva cuando el cálculo lo hiciste en Ruby: ahí el
`WHERE` es `id = 42` y siempre se cumple.

### 1.4 REPEATABLE READ y SERIALIZABLE, con los errores reales

Corrí esto contra `stock_development` sobre una tabla scratch, con dos threads y
conexiones distintas. **REPEATABLE READ**, dos `UPDATE` sobre la misma fila:

```text
[[1, "ActiveRecord::SerializationFailure",
     "PG::TRSerializationFailure: ERROR:  could not serialize access due to concurrent update"]]
```

O sea: en RR no perdés el update, **perdés la transacción**. Postgres no puede
re-evaluar el `WHERE` (violaría el snapshot), así que aborta. Eso te obliga a
escribir el bucle de reintento vos.

**Write skew**: dos transacciones leen el mismo agregado y cada una escribe una
fila *distinta*. Ninguna pisa a la otra, pero juntas rompen una invariante que
cruza filas ("el total nunca baja de 10"):

```text
REPEATABLE READ -> total=0   errores=[]                     # ❌ invariante rota
SERIALIZABLE    -> total=10  errores=[[1, "SerializationFailure"]]   # ✅
```

El mensaje que tira SERIALIZABLE es distinto del de RR, y conviene reconocerlo:

```text
PG::TRSerializationFailure: ERROR:  could not serialize access due to
read/write dependencies among transactions
```

SERIALIZABLE en Postgres es **SSI** (Serializable Snapshot Isolation): no toma
locks de lectura, rastrea dependencias y aborta a posteriori. Ventaja: no
bloquea. Desventaja: te enterás tarde y **tenés que reintentar sí o sí**, y con
mucha concurrencia la tasa de abortos crece.

### 1.5 Contra MySQL y contra JPA

| | PostgreSQL 16 | MySQL 8 / InnoDB | JPA / Hibernate |
|---|---|---|---|
| Default | READ COMMITTED | **REPEATABLE READ** | el del driver/DB (en Postgres, READ COMMITTED) |
| Dirty read | imposible siempre | posible en READ UNCOMMITTED | depende de la DB |
| Phantoms en RR | prevenidos (snapshot) | prevenidos con **gap locks** (bloquean rangos) | depende de la DB |
| Lectura bloqueante en RR | ve el snapshot | **ve la última versión commiteada** (*current read*) | idem DB |
| Lost update | lo resolvés vos | lo resolvés vos | `@Version` o `LockModeType` |

Los dos errores clásicos de un javero que viene de MySQL:

- **"El default es REPEATABLE READ"**. En MySQL sí, en Postgres no. Y el RR de
  MySQL logra los phantoms con *gap locks*, que bloquean rangos de índice y son
  una fuente de deadlocks que en Postgres no existe.
- **"Hibernate me da repeatable read"**. Lo que te da es el **persistence
  context** (cache de primer nivel): si pedís dos veces la misma entidad en la
  misma sesión, te devuelve *el mismo objeto en memoria*, no vuelve a la base.
  Eso parece repeatable read pero es una ilusión a nivel de objeto: no protege
  nada a nivel de base, no cubre queries JPQL con `flush`, y desaparece apenas
  cerrás la sesión. **En Rails no existe nada equivalente**: cada
  `StockItem.find(1)` es un `SELECT` nuevo y te devuelve un objeto nuevo.

```ruby
a = StockItem.find(1)
b = StockItem.find(1)
a.equal?(b)   # => false  (en Hibernate, dentro de una sesión, sería true)
```

Esto es la diferencia Active Record (el objeto se persiste solo) vs Data Mapper
(un `EntityManager` gestiona). Está explicada en
`app/models/application_record.rb:10`. Consecuencia práctica para concurrencia:
**no hay dirty checking diferido ni flush al final de la transacción**. Cada
`save!` es un `UPDATE` inmediato. No podés razonar "Hibernate va a agrupar todo
al commit"; en Rails el orden de las escrituras es el orden en que las escribiste,
y por lo tanto el orden en que se toman los locks es el que vos escribiste. Eso
es peor para el rendimiento y **mejor para razonar sobre deadlocks**.

### 1.6 Cómo se cambia el nivel en Rails

```ruby
ActiveRecord::Base.transaction(isolation: :serializable) do
  # ...
end
# :read_uncommitted, :read_committed, :repeatable_read, :serializable
```

Trampa verificada: **no se puede pedir un nivel de aislamiento uniéndose a una
transacción ya abierta**.

```text
ActiveRecord::TransactionIsolationError: cannot set isolation when joining a transaction
```

Es decir que un `transaction(isolation: :serializable)` adentro de otro service
que ya abrió transacción explota. Por eso en este repo **no usamos niveles
elevados**: todos los services pasan por
`ApplicationService#transactional` (`app/services/application_service.rb:68`),
que abre una transacción sin isolation, y la consistencia la damos con locks
explícitos, que componen sin sorpresas.

---

## 2. LOST UPDATE: el problema de este dominio

### 2.1 El timeline, con el SQL de cada paso

Dos requests concurrentes despachan 3 unidades cada una sobre un stock de 10.
Ambas usan el patrón `leer → calcular en Ruby → escribir`, sin lock:

```sql
-- T1                                         -- T2
BEGIN;                                        --
SELECT quantity_on_hand                       --
  FROM stock_items WHERE id = 42;             --
--   -> 10                                    --
--                                            BEGIN;
--                                            SELECT quantity_on_hand
--                                              FROM stock_items WHERE id = 42;
--                                            --   -> 10        ← el MISMO valor
UPDATE stock_items                            --
   SET quantity_on_hand = 7   -- 10 - 3       --
 WHERE id = 42;                               --
COMMIT;                                       --
--                                            UPDATE stock_items
--                                               SET quantity_on_hand = 7   -- 10 - 3
--                                             WHERE id = 42;
--                                            COMMIT;
-- Resultado: 7. Salieron 6 unidades, el sistema descontó 3.
```

Fijate que **nada acá viola READ COMMITTED**. Cada sentencia es correcta, cada
`SELECT` vio datos commiteados, cada `UPDATE` escribió sobre la versión más
nueva. La anomalía está en que el cálculo (`10 - 3`) lo hiciste en Ruby con un
valor que ya caducó. La base no sabe que 7 vino de una resta.

Es el mismo bug que en Java: `entity.setQty(entity.getQty() - 3); repo.save(entity);`
sin `@Version` ni `PESSIMISTIC_WRITE`. La diferencia es que en JPA quizá te
salvaba el dirty checking + `@Version` por costumbre del equipo; en Rails no hay
costumbre que te salve: `lock_version` sólo actúa si la tabla tiene la columna
**y** escribís con `save!`/`update!` (ver 3.2).

### 2.2 La demo, corrida de verdad

8 threads reales, 3 unidades cada uno, stock inicial 10, con y sin `FOR UPDATE`:

```text
SIN lock   -> qty final=4   errores=[]
CON lock   -> qty final=1   errores=[]
```

Sin lock quedaron 4: se aplicaron sólo 2 de los 8 descuentos (6 *lost updates*).
Con `SELECT ... FOR UPDATE` quedó 1: entraron exactamente 3 (3×3 = 9 de 10) y
los otros 5 vieron el saldo real y se rechazaron solos.

Ese segundo número es literalmente lo que asegura el test del repo,
`spec/integration/concurrency_spec.rb`:

```ruby
resultado = run_concurrently(8) do
  Stock::Issue.call(product:, warehouse:, quantity: 3, user:,
                    event_recorder: Outbox::NullRecorder.new)
end

expect(exitosos).to eq(3)
expect(fallidos).to eq(5)
expect(item.reload.quantity_on_hand).to eq(1)
expect(item.quantity_on_hand).to be >= 0        # LA invariante
```

### 2.3 Por qué el CHECK no alcanza como única defensa

`quantity_on_hand >= 0` está como CHECK constraint
(`db/migrate/20260830160600_create_stock_items.rb:77`) y evita el caso más
grave. Pero en el timeline de arriba **el CHECK nunca se dispara**: 7 es un
número perfectamente válido. El stock quedó mal sin violar ninguna constraint.
El CHECK te salva del desastre, no de la incorrección.

---

## 3. Las tres soluciones

### 3.1 Pesimista: `SELECT ... FOR UPDATE`

Es la que usa este repo para el camino crítico. `app/services/stock/apply_movement.rb:102`:

```ruby
def lock_stock_item!
  StockItem.lock.find(@stock_item_id)
end
```

SQL generado (verificado con `to_sql`):

```sql
SELECT "stock_items".* FROM "stock_items" WHERE "stock_items"."id" = $1 LIMIT 1 FOR UPDATE
```

El orden dentro de `ApplyMovement#call` (`:62`) es el que importa:

```ruby
transactional do
  next success(existing) if (existing = replayed_movement)   # idempotencia
  item = lock_stock_item!    # 1. BLOQUEAR
  validate!(item)            # 2. validar contra el estado YA bloqueado
  apply_to(item)             # 3. escribir la proyección
  movement = write_ledger_entry(item)   # 4. asiento inmutable
  publish_event(item, movement)         # 5. outbox
  success(movement)
end
```

**Validar después de bloquear** es todo el punto. Si validás antes, tenés un
TOCTOU (*time of check to time of use*) y volvés al lost update.

Un detalle que en la entrevista suma: `StockItem.lock.find(id)` bloquea **una
fila**. Postgres no hace *lock escalation* (a diferencia de SQL Server), así que
dos operaciones sobre productos distintos corren 100% en paralelo. El agregado
—en el sentido de DDD— es la unidad de contención, y acá el agregado es
`(producto, depósito)`. Está bien elegido: es lo más chico que preserva la
invariante.

#### Variantes de bloqueo a nivel fila

| Cláusula | Qué bloquea | Conflicto con | Cuándo la usás |
|---|---|---|---|
| `FOR UPDATE` | la fila, modo exclusivo | todo lo demás | vas a modificar la fila |
| `FOR NO KEY UPDATE` | igual pero deja pasar `FOR KEY SHARE` | todo menos `FOR KEY SHARE` | vas a modificar columnas que no son clave; lo toma solo un `UPDATE` normal |
| `FOR SHARE` | la fila, modo compartido | escritores | leés y necesitás que nadie escriba mientras tanto |
| `FOR KEY SHARE` | el más débil | sólo `FOR UPDATE` | lo toma Postgres solo al insertar una FK que apunta a la fila |

En Rails:

```ruby
StockItem.lock.find(id)                     # FOR UPDATE
StockItem.lock("FOR NO KEY UPDATE").find(id)
StockItem.lock("FOR SHARE").find(id)
StockItem.order(:id).lock("FOR UPDATE SKIP LOCKED").limit(200)
```

Dato que sorprende: **cuando insertás una fila hija, Postgres toma `FOR KEY SHARE`
sobre la fila padre** para que nadie la borre. Si tu transacción larga tiene un
`FOR UPDATE` sobre un `product`, todos los `INSERT` de `stock_movements` que
referencien ese producto se van a quedar esperando. Es una fuente de contención
invisible que no aparece en ninguna query tuya. `FOR NO KEY UPDATE` existe
justamente para no romper ese caso.

#### Modificadores de espera

```ruby
# NOWAIT: falla al toque si está tomada. app/models/application_record.rb:34
def lock_or_fail!(&)
  with_lock("FOR UPDATE NOWAIT", &)
rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid => e
  raise unless e.message.include?("could not obtain lock")
  raise ActiveRecord::LockWaitTimeout, "#{self.class.name}##{id} está bloqueado por otra operación"
end
```

El error que rescata, provocado a mano contra `stock_development`:

```text
ActiveRecord::LockWaitTimeout
PG::LockNotAvailable: ERROR:  could not obtain lock on row in relation "stock_items"
```

Aclaración honesta: `lock_or_fail!` vive en `ApplicationRecord` pero **hoy ningún
service del repo lo llama**. El camino crítico prefiere esperar hasta el
`lock_timeout` antes que devolver un 409 por contención normal; el helper está
para el caso "prefiero fallar ya" (un endpoint interactivo, un job que puede
reintentar más tarde).

```ruby
# SKIP LOCKED: saltea las tomadas. app/models/outbox_event.rb:27
def self.claim_batch(limit: 500)
  pending.where(attempts: ...MAX_ATTEMPTS).order(:id).limit(limit)
         .lock("FOR UPDATE SKIP LOCKED")
end
```

`SKIP LOCKED` es **la** primitiva de colas en SQL: N workers corren la misma
query y cada uno se lleva un lote distinto, sin coordinación externa, sin Redis
y sin que nadie espere. Es lo que hacen Solid Queue, GoodJob y Que por debajo.
Sin él, el worker 2 se encolaría detrás del 1 y agregar workers no escalaría
nada.

Y `lock_timeout` (10 s, seteado en `config/database.yml`) es el tercer
modificador, el global: si esperás más de eso, Postgres aborta la sentencia y
Rails levanta `ActiveRecord::LockWaitTimeout`, que
`app/services/application_service.rb:89` traduce a
`Result.failure(:locked, ...)` y `app/controllers/concerns/api/error_handling.rb:40`
convierte en un 409. Sin `lock_timeout`, un lock olvidado tiene todos tus
threads de Puma colgados hasta el `statement_timeout` (o para siempre).

#### Trampa verificada: `.lock` + `eager_load`

```ruby
StockItem.lock.eager_load(:product).limit(1).to_a
# ActiveRecord::StatementInvalid: PG::FeatureNotSupported:
#   ERROR:  FOR UPDATE cannot be applied to the nullable side of an outer join
```

`eager_load` genera un `LEFT OUTER JOIN` y Postgres prohíbe `FOR UPDATE` ahí.
Por eso `app/services/stock/transfers/dispatch.rb:33` usa `includes` y no
`eager_load`: `includes` sin `references` hace **preload** (queries separadas), y
el `FOR UPDATE` cae sólo sobre la tabla principal. Verificado:

```text
includes + lock emitió 2 queries:
  SELECT "stock_items".* FROM "stock_items" LIMIT 1 FOR UPDATE
  SELECT "products".*    FROM "products" WHERE "products"."id" = 5
```

O sea: **`includes` + `lock` bloquea la tabla principal y NADA MÁS**. Si creías
que estabas bloqueando también los `products`, no. Si necesitás eso, bloquealos
explícitamente y en orden.

### 3.2 Optimista: `lock_version`

`app/models/stock_item.rb:22` y `app/models/product.rb:9`:

```ruby
self.locking_column = "lock_version"
```

Rails lo detecta por convención (una columna `lock_version` integer alcanza; la
línea explícita documenta la intención). El `UPDATE` real que emite, capturado
con `ActiveSupport::Notifications`:

```sql
UPDATE "stock_items"
   SET "bin_location" = 'TEST-30', "updated_at" = '2026-08-30 20:08:45.560872',
       "lock_version" = 32
 WHERE "stock_items"."id" = 1
   AND "stock_items"."lock_version" = 31
```

Si el `UPDATE` afecta 0 filas, Rails levanta `ActiveRecord::StaleObjectError`.

#### Dónde se rompe la analogía con `@Version` de JPA

| | JPA / Hibernate | Rails / Active Record |
|---|---|---|
| Se activa con | `@Version` en el campo | columna `lock_version` (o `locking_column`) |
| Cuándo se chequea | en el **flush** (típicamente al commit) | en **cada `UPDATE`**, inmediatamente |
| Excepción | `OptimisticLockException` / `StaleStateException` | `ActiveRecord::StaleObjectError` |
| Entidades *detached* | el escenario canónico | **no existen**: no hay sesión de persistencia |
| Se puede saltear | `@Version` es difícil de esquivar | `update_column`, `update_all`, `update_counters` lo **saltean** |
| Bloqueo explícito | `em.lock(e, OPTIMISTIC_FORCE_INCREMENT)` | no hay equivalente directo |

Los dos que muerden:

1. **No hay flush diferido.** En JPA modificás la entidad, seguís trabajando y
   el choque aparece al commit. En Rails el choque aparece en el `save!` exacto,
   con el stack apuntando a la línea culpable. Es más fácil de depurar y hace
   que el orden de escrituras sea el orden de tus llamadas.
2. **`update_all` no toca `lock_version`.** Por eso
   `StockItem.atomically_decrement` (`app/models/stock_item.rb:115`) lo
   incrementa **a mano** dentro del SQL:

   ```ruby
   .update_all(["quantity_on_hand = quantity_on_hand - ?, " \
                "lock_version = lock_version + 1, " \
                "last_movement_at = ?, updated_at = ?", amount, Time.current, Time.current])
   ```

   Si no lo hicieras, un objeto ya cargado en memoria en otro proceso seguiría
   creyendo que su versión es válida y pisaría el cambio sin enterarse.

#### Optimistic locking sobre HTTP: 409 + `lock_version` = ETag/If-Match

El serializer devuelve la versión a propósito
(`app/serializers/stock_item_serializer.rb:23`):

```ruby
# `lock_version` SE DEVUELVE A PROPÓSITO: el cliente lo manda de vuelta en
# el PATCH y así habilitamos optimistic locking end-to-end sobre HTTP.
lock_version: object.lock_version
```

Y el controller lo consume (`app/controllers/api/v1/products_controller.rb:56`):

```ruby
product.lock_version = params[:lock_version] if params[:lock_version].present?
product.update!(product_params)
```

Si otro lo tocó, `StaleObjectError` sube y
`app/controllers/concerns/api/error_handling.rb:27` responde:

```json
{ "error": { "code": "conflict",
             "message": "El recurso fue modificado por otra operación. Recargá y reintentá." } }
```

con status **409 Conflict**. Es el mismo contrato que `ETag` + `If-Match`: en vez
de un hash opaco mandás un entero, y el 409 reemplaza al 412. Lo relevante es lo
que **evita**: el *last write wins* silencioso, donde dos operadores editan el
mismo producto y el segundo pisa al primero sin que nadie se entere.

En la UI web el mismo error se maneja distinto, porque el usuario es una persona
(`app/controllers/products_controller.rb:47`):

```ruby
rescue ActiveRecord::StaleObjectError
  redirect_to edit_product_path(@product),
              alert: "Otro usuario modificó este producto mientras lo editabas. Revisá los cambios."
```

### 3.3 UPDATE condicional atómico

`app/models/stock_item.rb:115`. La variante de máximo throughput: **una sola
sentencia**, con la regla de negocio adentro del `WHERE`.

```ruby
def self.atomically_decrement(stock_item_id, amount)
  updated = where(id: stock_item_id)
            .where("quantity_on_hand - quantity_reserved >= ?", amount)
            .update_all([...])
  updated == 1
end
```

Es correcto por lo de la sección 1.3: en READ COMMITTED, el `UPDATE` espera al
que tenga la fila y después **re-evalúa el `WHERE` sobre la versión nueva**. Si
la condición dejó de cumplirse, afecta 0 filas y devolvés `false`. Cero
round-trips extra, cero riesgo de deadlock (una sola fila, una sola sentencia).

Lo que pagás: no podés hacer lógica en Ruby entre el chequeo y la escritura, no
tenés el objeto cargado, y no podés escribir el asiento del ledger con el
`quantity_after` correcto sin volver a leer. Por eso el camino principal del repo
usa `FOR UPDATE` y esto queda como herramienta para el caso "descontá si podés".

El mismo patrón, en su versión más útil, es el contador correlativo
(`app/models/sequence_counter.rb:17`):

```sql
INSERT INTO sequence_counters (key, value, created_at, updated_at)
VALUES (?, 1, NOW(), NOW())
ON CONFLICT (key) DO UPDATE
  SET value = sequence_counters.value + 1, updated_at = NOW()
RETURNING value
```

Una sentencia, atómica, y como vive dentro de tu transacción un rollback también
revierte el número (a diferencia de `nextval`, que deja huecos). El test
`spec/integration/concurrency_spec.rb` verifica con 10 threads que salen
exactamente `1..10`, sin repetidos ni huecos.

Y la trampa que casi arruina esto, porque no es de concurrencia de base sino de
Rails: ese `INSERT ... RETURNING` se ejecuta con `select_value`, así que para el
**query cache** de Active Record es un `SELECT`. Dos llamadas con la misma clave
en la misma request devolvían el mismo número sin tocar la base. Por eso el
método va envuelto en `connection.uncached { ... }` + `clear_query_cache`
(`app/models/sequence_counter.rb:47`). El detalle completo está en
`docs/10-errores-comunes.md` §6.

### 3.4 Cuándo usar cada una

| | Pesimista (`FOR UPDATE`) | Optimista (`lock_version`) | UPDATE condicional |
|---|---|---|---|
| Costo si NO hay conflicto | un lock de fila (barato pero real) | cero | cero |
| Costo si HAY conflicto | esperás | perdés el trabajo, reintentás | `false`, decidís vos |
| Round-trips de la escritura | 2 (`SELECT FOR UPDATE` + `UPDATE`) | 2, o 1 si el cliente ya te mandó la versión | 1 |
| Riesgo de deadlock | ✅ sí, si tomás varios en distinto orden | ⚠️ sólo si escribís varias filas en distinto orden dentro de una tx | ❌ no (una fila, una sentencia) |
| Riesgo de starvation | posible con mucha contención | reintentos infinitos si hay mucho conflicto | no |
| Lógica compleja entre leer y escribir | ✅ | ✅ | ❌ |
| Varias filas en una operación | ✅ | ⚠️ una por una | ❌ |
| El usuario puede reintentar | irrelevante | ✅ requisito | ⚠️ |
| Se usa en este repo para | stock, reservas, transferencias, OCs | edición de catálogo vía API/UI | el contador correlativo (`SequenceCounter`); `atomically_decrement` está implementado y testeado, pero ningún service lo usa hoy |

Regla de bolsillo, tal como está escrita en `app/models/stock_item.rb:110`:

- 1 fila + condición expresable en SQL → **UPDATE condicional**.
- Varias filas / lógica compleja / hay que leer antes → **`SELECT FOR UPDATE`**.
- Conflictos raros y el usuario puede reintentar → **optimistic locking**.

Y una cuarta que no está en la lista: **contención alta sobre la misma fila** →
rediseñá el esquema (particionar el contador, agregar filas de "cubos"), porque
ninguna de las tres arregla una fila caliente.

---

## 4. CHECK constraints: por qué las validaciones de Rails no sirven bajo concurrencia

`db/migrate/20260830160600_create_stock_items.rb:77`:

```ruby
add_check_constraint :stock_items, "quantity_on_hand >= 0",
                     name: "stock_items_on_hand_non_negative"
add_check_constraint :stock_items, "quantity_reserved >= 0",
                     name: "stock_items_reserved_non_negative"
add_check_constraint :stock_items, "quantity_reserved <= quantity_on_hand",
                     name: "stock_items_reserved_lte_on_hand"
```

El modelo tiene **las mismas** reglas como validaciones
(`app/models/stock_item.rb:39`, y `reserved_cannot_exceed_on_hand`). No es
duplicación por descuido: cumplen funciones distintas.

| | Validación de Rails | CHECK constraint |
|---|---|---|
| Dónde corre | en **un** proceso Ruby | en Postgres |
| Cuándo | antes del `INSERT`/`UPDATE` | al aplicar la fila, dentro de la tx |
| Atómica respecto de la escritura | ❌ **no** | ✅ sí |
| Sirve para mensajes de error lindos | ✅ | ❌ (te da un `PG::CheckViolation`) |
| Te protege de `update_all`, `psql`, otro servicio, una migración | ❌ | ✅ |

El problema estructural es el mismo TOCTOU de siempre: la validación hace
`SELECT` (o lee el objeto en memoria), decide, y recién después escribe. Entre
esos dos momentos hay una ventana. El caso más citado es `validates :uniqueness`,
que es **imposible** de hacer correcto sin índice único.

Y acá va una historia que vale por el resto de la sección, porque el rescue
"obvio" **no alcanza** — y este repo lo tuvo mal. Así estaba escrito
`StockItem.find_or_provision!`:

```ruby
# ❌ La versión que ESTUVO viva en este repo: el rescue era decorativo.
def self.find_or_provision!(product:, warehouse:)
  find_by(product:, warehouse:) || create!(product:, warehouse:)
rescue ActiveRecord::RecordNotUnique
  # El otro proceso ganó la carrera: su fila ya está commiteada, la leemos.
  find_by!(product:, warehouse:)
end
```

Dos defectos, los dos reales.

**Trampa 1 — un rescue adentro de una transacción no sirve.** Los tres
llamadores (`Stock::Receive`, `Transfers::Dispatch`, `Purchasing::ReceiveOrder`)
invocan esto **dentro** de una transacción. En PostgreSQL, cuando una sentencia
falla, **toda la transacción queda abortada**: cualquier consulta posterior
muere. Reproducido contra `stock_development`:

```text
ActiveRecord::StatementInvalid: PG::InFailedSqlTransaction: ERROR:
current transaction is aborted, commands ignored until end of transaction block
```

O sea que el `find_by!` del rescate explotaba igual, y encima con un error más
difícil de leer que el original. Esto es muy distinto de MySQL o de la JVM con
JDBC, donde un error de sentencia **no** invalida la transacción; es la
diferencia que más sorprende viniendo de otro motor.

**Trampa 2 — no siempre es `RecordNotUnique`.** El modelo también tiene
`validates :product_id, uniqueness: { scope: :warehouse_id }`. Si el ganador
commitea justo antes de que corra **esa** validación, el perdedor recibe
`RecordInvalid`, no `RecordNotUnique`. La ventana es angosta pero existe, y el
rescue de una sola clase la deja pasar.

**Cómo quedó** (`app/models/stock_item.rb`, `find_or_provision!`):

```ruby
def self.find_or_provision!(product:, warehouse:)
  existing = find_by(product:, warehouse:)
  return existing if existing

  # requires_new: true -> SAVEPOINT. Sin esto, el rescue de abajo es inútil
  # cuando ya estamos dentro de una transacción (que es SIEMPRE, en la práctica).
  transaction(requires_new: true) { create!(product:, warehouse:) }
rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
  # El otro proceso ganó la carrera y su fila ya está commiteada.
  # El savepoint se revirtió, así que la conexión sigue usable.
  find_by!(product:, warehouse:)
end
```

El `requires_new: true` emite un `SAVEPOINT` (§6.2). Al fallar el `create!` se
revierte **sólo hasta el savepoint**: la transacción externa sigue viva y el
`find_by!` del rescue puede correr. Es el savepoint usado al revés de lo
habitual — no para descartar un pedazo de trabajo, sino para **sobrevivir a un
error esperado** sin llevarse puesta la transacción de afuera.

Confiás en el índice único (`add_index ..., unique: true`) y **rescatás el
choque**. `find_or_create_by!` sin esto es un bug esperando: los dos threads
pasan el `find`, los dos intentan el `create`, uno explota.

Lo que lo protege hoy: el ejemplo de 6 threads concurrentes de
`spec/integration/concurrency_spec.rb` (confirma que queda exactamente una fila)
más dos regresiones en `spec/models/stock_item_spec.rb` — una crea al "ganador"
**desde otra conexión** y verifica que la llamada sobrevive estando dentro de una
transacción, la otra fuerza el `RecordNotUnique`.

El mapeo a HTTP está en `app/services/application_service.rb:80`:
`RecordNotUnique → Result.failure(:duplicate, ...)` → 409. Con un detalle que
también se corrigió: ese `Result` ya **no** adjunta el `e.message` de
`PG::UniqueViolation`. Ese mensaje trae el nombre del índice, el de la tabla y el
valor que colisionó, y `ErrorSerializer` renderiza `details` tal cual: se estaba
filtrando estructura interna en el cuerpo del 409. Hoy el mensaje que sale es
genérico y el detalle completo va al log (`event: "service.duplicate"`).

**Lo que un CHECK no te da**: no te salva de estados *válidos pero incorrectos*
(el `7` del lost update). Es la última red, no la primera.

---

## 5. Deadlocks

### 5.1 Cómo se producen

Siempre igual: dos transacciones adquieren los mismos locks **en orden distinto**.

```text
T1: lock(item 7)  ... quiere lock(item 3)   → espera a T2
T2: lock(item 3)  ... quiere lock(item 7)   → espera a T1
```

Ciclo. Nadie avanza. En esta app el escenario natural es una transferencia
multi-producto: si la transferencia A trae las líneas `[p1, p2]` y la B trae
`[p2, p1]`, y cada una bloquea en el orden en que vienen, deadlock.

### 5.2 Un deadlock real, provocado en esta base

Corrí dos threads que bloquean `stock_items` 1 y 2 en orden cruzado. Esto es
literalmente lo que devolvió Postgres:

```text
ActiveRecord::Deadlocked
PG::TRDeadlockDetected: ERROR:  deadlock detected
DETAIL:  Process 17100 waits for ShareLock on transaction 9983; blocked by process 17103.
         Process 17103 waits for ShareLock on transaction 9982; blocked by process 17100.
HINT:  See server log for query details.
CONTEXT:  while locking tuple (0,8) in relation "stock_items"
```

Cómo se lee, campo por campo:

- **`ShareLock on transaction 9983`**: el proceso 17100 está esperando a que la
  transacción 9983 termine. En Postgres, esperar una fila bloqueada se
  implementa esperando el *transaction id* del que la tiene.
- **`blocked by process 17103`**: el PID del backend culpable. Se cruza con
  `pg_stat_activity`.
- **`while locking tuple (0,8) in relation "stock_items"`**: `(bloque, offset)`
  del `ctid`. Te dice qué fila, aunque no su clave primaria.
- **`HINT: See server log`**: el detalle jugoso (las **queries** exactas de cada
  proceso) va al log del servidor, no al cliente. Si vas a depurar deadlocks en
  producción, necesitás acceso a ese log: `log_min_error_statement` ya viene en
  `error` y por lo tanto la sentencia culpable se registra sola. Lo que sí
  conviene prender es `log_lock_waits` (viene en `off`, verificado en esta
  instancia), que loguea las esperas largas **antes** de que haya ciclo.

En el log del servidor, además, aparece qué transacción fue elegida como víctima.
Postgres siempre mata a una y deja seguir a la otra: **el deadlock nunca cuelga
el sistema**, produce un error en una transacción.

Cuándo se detecta: después de `deadlock_timeout`, que en esta instancia es el
default:

```bash
psql -d stock_development -c "show deadlock_timeout;"   # 1s
```

Ojo con el matiz: `deadlock_timeout` **no** es "cuánto espero por un lock". Es
"cuánto espero antes de gastar CPU buscando un ciclo". Bajarlo hace que el
chequeo (que es caro) corra más seguido; subirlo hace que un deadlock real tarde
más en resolverse. El default de 1 s casi nunca hay que tocarlo.

### 5.3 La solución: orden total determinístico

`app/services/stock/transfers/dispatch.rb:99`:

```ruby
# `.order(:id).lock` -> SELECT ... FOR UPDATE ORDER BY id.
def lock_items_in_order(product_ids, warehouse_id)
  StockItem.where(product_id: product_ids, warehouse_id:)
           .order(:id).lock.includes(:product).index_by(&:product_id)
end
```

Un solo `SELECT ... FOR UPDATE ORDER BY id` para **todos** los items del origen.
Si todas las transacciones piden los locks en el mismo orden total, **no puede
haber ciclo**: es una propiedad matemática, no una mejora estadística. Y como
además es una sola query, no hay ventana entre lock y lock.

La misma disciplina, aplicada a *tipos* de fila distintos, está en
`app/services/stock/release_reservation.rb:20`:

```ruby
reservation = StockReservation.lock.find(@reservation_id)
# Orden de locks: primero la reserva, después el item. SIEMPRE el mismo orden.
item = StockItem.lock.find(reservation.stock_item_id)
```

`CommitReservation` (`:33` y `:47`) toma exactamente el mismo orden
reserva → item. Si uno de los dos lo invirtiera, tendrías deadlocks
intermitentes imposibles de reproducir en desarrollo.

El test que lo protege (`spec/integration/concurrency_spec.rb`) dispara dos
transferencias con los mismos dos productos en orden cruzado y exige
`resultado[:errors]` vacío y dos `ok?`. Corrido recién:

```text
8 examples, 0 failures      # Finished in 2.18 seconds
```

**Reglas prácticas para no generar deadlocks:**

1. Un orden total y global sobre las filas. `ORDER BY id` es el más barato.
2. Un orden fijo entre **tablas** (siempre reserva antes que item, siempre
   transfer antes que stock_items).
3. Bloqueá lo más tarde posible y liberá lo antes posible (transacciones cortas).
4. Bloqueá **todo lo que vas a necesitar de una sola vez** cuando puedas: una
   query con `IN (...) ORDER BY id FOR UPDATE` en vez de N queries.
5. Cuidado con los locks implícitos: el `FOR KEY SHARE` de las FKs, y los
   `after_save` que escriben otra tabla (`PurchaseOrderLine#refresh_order_totals`
   toca el padre — si dos líneas de órdenes distintas se cruzan, el orden lo
   define el orden de las líneas).

### 5.4 Reintentar es válido, pero no es la solución

`app/jobs/application_job.rb:81`:

```ruby
retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5
retry_on ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5
```

Por qué el retry es legítimo: un deadlock es un fallo **transitorio**; la
transacción víctima se revirtió entera, así que reintentarla es seguro (siempre
que sea idempotente, y acá lo es por el `idempotency_key`).

Por qué no alcanza:

- El retry **no reduce** la tasa de deadlocks: la esconde. Si tu sistema hace
  100 deadlocks por minuto, con retry hace 100 deadlocks por minuto **y** el
  doble de trabajo.
- Cada deadlock cuesta `deadlock_timeout` (1 s) de espera pura. A escala eso es
  latencia p99 que no explicás.
- Con contención alta, los reintentos vuelven a chocar → *thundering herd*. El
  backoff polinómico + jitter (Rails aplica ~15% por defecto) mitiga, no resuelve.
- **El retry no funciona en una request HTTP síncrona**: en un job podés
  reintentar en 18 segundos; en un `POST` no. Ahí el usuario ve un 500.

La solución es el orden determinístico. El retry es el cinturón de seguridad.

### 5.5 Diagnóstico en vivo

Quién bloquea a quién, ahora mismo (verificado que corre en esta base):

```sql
SELECT blocked.pid  AS bloqueado,  blocked.query  AS query_bloqueada,
       blocking.pid AS bloqueante, blocking.query AS query_bloqueante,
       blocked.wait_event_type, blocked.wait_event
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS bp(pid) ON true
JOIN pg_stat_activity blocking ON blocking.pid = bp.pid;
```

Transacciones abiertas hace rato (las que causan bloat y retienen locks):

```sql
SELECT pid, state, now() - xact_start AS duracion, left(query, 80)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND now() - xact_start > interval '10 seconds'
ORDER BY duracion DESC;
```

Y el martillo, cuando ya sabés el PID:

```sql
SELECT pg_cancel_backend(17103);   -- cancela la query (educado)
SELECT pg_terminate_backend(17103); -- mata la conexión (bruto)
```

---

## 6. Transacciones en Rails: las trampas

### 6.1 El modelo mental que traés de Spring, y dónde se rompe

| | Spring `@Transactional` | Rails `transaction do ... end` |
|---|---|---|
| Cómo se aplica | anotación + proxy AOP | un bloque, explícito |
| Auto-invocación | ⚠️ **no funciona** (el proxy no intercepta llamadas internas) | funciona siempre, es un bloque |
| Propagación | `REQUIRED`, `REQUIRES_NEW`, `NESTED`, `SUPPORTS`... | `REQUIRED` implícito; `requires_new: true` ≈ `NESTED` (SAVEPOINT) |
| Rollback por default | sólo en `RuntimeException` (¡las *checked* commitean!) | **cualquier** excepción hace rollback |
| Rollback silencioso | `TransactionStatus#setRollbackOnly` | `raise ActiveRecord::Rollback` |
| Alcance | por `DataSource` / `TransactionManager` | **por conexión de Active Record** |

La última fila es importante y se olvida: en Rails la transacción vive en **la
conexión**, no en el thread ni en un contexto. Si dentro de un bloque
`transaction` abrís un thread nuevo, ese thread toma **otra conexión del pool** y
**no ve** lo que escribiste. Eso no es un detalle: es exactamente por lo que
`spec/support/concurrency.rb` tiene que desactivar las transactional fixtures
(sección 11). En Spring con un pool y `@Transactional` te pasa lo mismo, pero es
más fácil de olvidar en Ruby porque no hay anotación que te lo recuerde.

### 6.2 La trampa de `ActiveRecord::Rollback` en un bloque anidado

Verificado en Rails 8.1.3.1:

```ruby
ActiveRecord::Base.transaction do
  ins("externa")
  ActiveRecord::Base.transaction do        # SIN requires_new
    ins("anidada")
    raise ActiveRecord::Rollback
  end
  ins("despues")
end
```

```text
1) anidada sin requires_new -> ["externa", "anidada", "despues"]
```

**Todo commiteó, incluida la fila que "revertiste".** Y no hubo error, no hubo
warning, nada. Es el bug de concurrencia más silencioso de Rails.

Qué pasa: un `transaction` anidado **por default no abre nada** — se une a la de
afuera (equivalente a `PROPAGATION_REQUIRED`). El `raise
ActiveRecord::Rollback` es una excepción especial que el bloque `transaction`
**se traga** (por diseño: sirve para abortar sin propagar la excepción). Como el
bloque interno no tiene transacción propia, no hay nada que revertir, y como se
tragó la excepción, la de afuera ni se entera y sigue de largo.

Con `requires_new: true` el comportamiento es el esperado:

```text
2) requires_new: true        -> ["externa", "despues"]
```

Porque ahí sí hay un **SAVEPOINT**. El SQL emitido, capturado:

```text
BEGIN
INSERT INTO zz_tx_demo (tag) VALUES ('a')
SAVEPOINT active_record_1
INSERT INTO zz_tx_demo (tag) VALUES ('b')
RELEASE SAVEPOINT active_record_1
COMMIT
```

Es exactamente `PROPAGATION_NESTED` de Spring, con la misma implementación
(savepoints) y la misma advertencia: un savepoint **no** es una transacción
independiente. Si la externa hace rollback, se lleva puesto todo, savepoints
incluidos. Si querés una transacción realmente independiente necesitás **otra
conexión**, no `requires_new`.

Y el costo no es cero: cada `requires_new` son dos round-trips extra (SAVEPOINT
+ RELEASE) y un objeto de transacción más en el stack de Active Record. En un
loop de 10.000 iteraciones se nota.

### 6.3 El cambio de Rails 6.1 → 7.0: `return` dentro del bloque

```ruby
def con_return
  ActiveRecord::Base.transaction do
    ins("antes-del-return")
    return :salio
  end
end
```

```text
3) return adentro            -> ["antes-del-return"]     # COMMITEÓ
```

Historia corta: hasta Rails 6.0, un `return`/`break`/`throw` que saliera de un
bloque `transaction` hacía **rollback**. Rails 6.1 agregó un *deprecation
warning*. **Rails 7.0 cambió el comportamiento: ahora commitea.** El nuevo
comportamiento es el defendible (salir de un método no es "hubo un error"), pero
el cambio rompió código en silencio en medio mundo, porque el patrón

```ruby
def hacer_algo
  ActiveRecord::Base.transaction do
    return Result.failure(:sin_stock, "...") if item.available < n   # ⚠️
    item.update!(...)
  end
end
```

que **antes** revertía, ahora commitea lo que se haya escrito antes del `return`.
Si venís de un repo viejo o de tutoriales viejos, esto está en tu memoria muscular
y está mal.

### 6.4 Por qué acá usamos una excepción propia

`app/services/application_service.rb:46`, con el razonamiento completo en el
comentario del archivo:

```ruby
class BusinessRuleViolation < StandardError
  attr_reader :result

  def initialize(result)
    @result = result
    super(result.error.message)
  end
end
```

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

def fail!(code, message, **details)
  raise BusinessRuleViolation, Result.failure(code, message, **details)
end
```

Esto esquiva las dos trampas de arriba de una sola vez:

- No usa `return` → inmune al cambio de 7.0.
- No usa `ActiveRecord::Rollback` → inmune al problema del bloque anidado. Y esto
  es **crítico en este repo**, porque los services se llaman entre sí:
  `Transfers::Dispatch` → `ApplyMovement` son dos `transactional` anidados. Si
  `ApplyMovement` abortara con `ActiveRecord::Rollback`, la transacción de
  `Dispatch` **no se revertiría** y la transferencia quedaría a medias.
- La excepción viaja hasta el `rescue` de la transacción **más externa**, que
  hace rollback de todo y devuelve el `Result`. Afuera, el contrato sigue siendo
  "todo service devuelve un Result, nunca lanza por regla de negocio".

Fijate cómo los services propagan el fallo del anidado sin perder el código de
error (`app/services/stock/transfers/dispatch.rb:60`):

```ruby
fail!(move_out.error.code, move_out.error.message, **move_out.error.details) if move_out.failure?
```

### 6.5 Otras trampas de transacciones que hay que tener en la cabeza

- **Un `rescue` genérico adentro del bloque se come el rollback.** Si atrapás la
  excepción dentro del `transaction do`, la transacción **commitea** lo que
  haya. Es el equivalente exacto a atrapar la excepción antes de que el proxy de
  Spring la vea.
- **`raise ActiveRecord::Rollback` en la transacción más externa** funciona
  bien (revierte y no propaga), pero devuelve `nil` desde el bloque, así que el
  código de afuera tiene que saberlo.
- **`transaction(joinable: false)`** hace que los `transaction` anidados que
  vengan después se conviertan en savepoints reales en vez de unirse. Es lo que
  usan las transactional fixtures de los tests.
- **El mito de `after_commit` en los tests.** Vas a leer por todos lados que
  `after_commit` no corre bajo transactional fixtures. Era cierto **hasta Rails
  4** (de ahí la gema `test_after_commit`). Desde Rails 5 la transacción que
  envuelve el ejemplo se abre con `joinable: false`, así que lo que escribís
  adentro abre su propia transacción real y los callbacks **sí** se disparan.
  Verificado en este repo: un `after_commit` en un modelo dentro de un spec con
  `use_transactional_fixtures = true` corre, y `ActiveRecord.after_all_transactions_commit`
  también. Lo que las transactional fixtures sí rompen es **otro hilo con otra
  conexión** (sección 11): eso no se arregla con callbacks, se arregla apagando
  las fixtures transaccionales.
- **`isolation:` no se puede pedir al unirse** (verificado, sección 1.6).

---

## 7. Efectos secundarios: nunca adentro de la transacción

La regla: **dentro de una transacción sólo va SQL de tu base**. Nada de HTTP,
nada de mails, nada de encolar jobs, nada de escribir en S3.

Por qué:

1. **Sostenés locks mientras esperás la red.** Un webhook con 5 s de timeout son
   5 s con `FOR UPDATE` tomado sobre `stock_items`. Multiplicado por los threads
   de Puma, tenés la fila caliente inutilizable.
2. **No se puede revertir.** Si la transacción hace rollback después, el mail ya
   salió y el webhook ya notificó "se despacharon 100 unidades" de una
   transferencia que no existe.
3. **Al revés también rompe.** Con un adapter que encola fuera de tu transacción
   (Sidekiq/Redis), el worker puede levantar el job **antes** de que Postgres
   commitee y no encontrar la fila. Es el `RecordNotFound` intermitente clásico.

### 7.1 Las tres herramientas de Rails, en orden de fuerza

**`after_commit`** (callback de modelo). Corre cuando commitea la transacción
**más externa**. Es el mínimo aceptable para un efecto.
`app/models/purchase_order_line.rb:22` explica por qué la costumbre es usarlo
siempre en vez de `after_save`.

**`ActiveRecord.after_all_transactions_commit`** (Rails 7.2+). Un bloque
arbitrario, no atado a un modelo. Es lo que usa el outbox
(`app/services/outbox/recorder.rb:47`):

```ruby
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

Si esto fuera un `after_commit` de modelo dentro de una transacción anidada,
encolaría antes de que la externa termine. El SETNX del cache, además,
*debouncea*: 500 eventos en un lote encolan **un** job, no 500.

**`enqueue_after_transaction_commit`**, y acá hay una trampa de versión que este
repo se comió entera. **Este bug estuvo vivo acá; abajo está cómo se veía, cómo
se detectó y cómo se arregló.**

En Rails 7.2 esto era un interruptor global —
`config.active_job.enqueue_after_transaction_commit = :always` — y así estaba
escrito en `config/initializers/sidekiq.rb`. **Rails 8.1 removió esa config
global** y también los valores `:always` / `:never` / `:default`: hoy es un
atributo **por clase de job**. El railtie de Active Job incluso lo excluye a
propósito cuando vuelca `config.active_job` sobre `ActiveJob::Base` ("This config
can't be applied globally"), así que esa línea no fallaba, no avisaba y **no
hacía nada**:

```ruby
# Antes del arreglo:
Rails.application.config.active_job.enqueue_after_transaction_commit  # => :always
ActiveJob::Base.enqueue_after_transaction_commit                      # => false  ⚠️
```

Cómo se detectó: no mirando la config —que contestaba `:always` y te dejaba
tranquilo— sino preguntándole al **consumidor real** del valor,
`ActiveJob::Base.enqueue_after_transaction_commit`. Y corriéndolo: un
`perform_later` adentro de una transacción escribía la fila de la cola **al
instante** y sobrevivía al `ROLLBACK`.

**El arreglo.** Se borró la línea del initializer (`config/initializers/sidekiq.rb`
hoy sólo configura Redis y el death handler) y se puso el atributo de clase donde
corresponde, en `app/jobs/application_job.rb`:

```ruby
class ApplicationJob < ActiveJob::Base
  self.enqueue_after_transaction_commit = true   # o por job puntual
end
```

Estado actual, con `bin/rails runner`:

```text
config.active_job.enqueue_after_transaction_commit  => nil
ActiveJob::Base.enqueue_after_transaction_commit    => false
ApplicationJob.enqueue_after_transaction_commit     => true   ✅
```

Y el comportamiento, medido contra la base de desarrollo con el adapter de Solid
Queue:

```text
dentro de la tx:       0 jobs encolados
después del ROLLBACK:  0 jobs encolados     # antes: 1, y se ejecutaba igual
después del COMMIT:    1 job encolado
```

Guardátelo como ejemplo de categoría, porque es el tipo de defecto más caro: no
explotaba, no logueaba, no había deprecation warning, y la config que vos
escribiste te devolvía exactamente el valor que le pusiste. Lo único que
delataba el problema era medir el efecto, no leer la configuración.

Lo que salvó al repo de que esto fuera grave mientras estuvo vivo es que el
evento de dominio **no depende de acá**: el outbox usa
`after_all_transactions_commit` y escribe su fila dentro de la misma
transacción.

### 7.2 Por qué eso todavía no es un outbox

Aun con `enqueue_after_transaction_commit` bien puesto, la secuencia es:

```text
COMMIT (Postgres)  →  [ventana]  →  enqueue (Redis)
```

Si el proceso muere en esa ventana —microsegundos, pero existe—, o si Redis está
caído en ese instante, **el job se pierde y nadie se entera**. El estado de
negocio commiteó y el efecto nunca ocurrió. Es una pérdida silenciosa.

El outbox cierra la ventana porque el evento **es una fila más de tu
transacción**:

```text
BEGIN
  UPDATE stock_items ...
  INSERT INTO stock_movements ...
  INSERT INTO outbox_events ...      ← el evento commitea con el negocio, o no commitea
COMMIT
  → un relay (PublishPendingJob) lo publica después, con FOR UPDATE SKIP LOCKED
```

Si el relay muere, la fila sigue ahí y el próximo tick la levanta. El precio es
**at-least-once**: si el proceso muere después de publicar y antes de marcar
`published_at`, el evento sale dos veces, y el consumidor tiene que deduplicar
por `event_id`. Está todo escrito en `app/jobs/outbox/publish_pending_job.rb`.

La frase que conviene tener lista: *"exactly-once delivery no existe; lo que
existe es at-least-once delivery + idempotent processing"*.

Y la línea de decisión: **outbox** para eventos que no se pueden perder (movimientos
de stock, facturación); **`enqueue_after_transaction_commit`** para "mandale un mail
al usuario".

---

## 8. Transacciones largas: por qué procesamos en lotes

Una transacción abierta 10 minutos en Postgres te cuesta tres cosas:

1. **Retiene todos los locks** hasta el commit. No hay liberación temprana.
2. **Frena el VACUUM globalmente.** Mientras exista una transacción vieja,
   autovacuum no puede reciclar ninguna tupla muerta más nueva que su snapshot —
   **en toda la base, no sólo en las tablas que tocaste**. Las tablas se hinchan
   (*bloat*), los índices crecen, los planes empeoran. Esta es la razón #1 por
   la que una base Postgres "se pone lenta sin motivo".
3. **Si falla al final, perdés todo el trabajo.**

Se ve así (`xact_start` es lo que mirás vos; a quien le frena la mano al
vacuum es al `backend_xmin` de esa conexión):

```sql
SELECT pid, now() - xact_start AS duracion, state, left(query, 60)
FROM pg_stat_activity WHERE xact_start IS NOT NULL ORDER BY duracion DESC;
```

El caso peor es `idle in transaction`: una conexión que abrió `BEGIN`, hizo algo
y se quedó esperando —típicamente porque el código hizo una llamada HTTP adentro
de la transacción (sección 7)—. Por eso `config/database.yml` setea:

```yaml
variables:
  statement_timeout: 15000                    # mata cualquier query > 15s
  lock_timeout: 10000                         # no esperes locks eternamente
  idle_in_transaction_session_timeout: 30000  # mata transacciones zombies
```

Los tres son cinturones de seguridad, no optimizaciones. Sin
`idle_in_transaction_session_timeout`, un bug en un cliente te tiene el
autovacuum parado durante días.

El patrón correcto está en `app/services/stock/expire_reservations.rb`: **una
transacción por reserva**, no una para las 50.000.

```ruby
scope.in_batches(of: @batch_size) do |batch|
  batch.each do |reservation|
    result = ReleaseReservation.call(reservation:, expired: true, ...)   # <- su propia tx
    result.ok? ? expired += 1 : failed << { id: reservation.id, error: result.error.to_h }
  end
end
```

Tres propiedades: los locks duran milisegundos, un fallo aislado no arrastra al
resto (y queda registrado en `failed`), y `in_batches` pagina con `WHERE id > ?`
en vez de traer 50.000 objetos a memoria.

El mismo criterio en el relay del outbox: una transacción **por lote** de 200,
justamente porque los locks de `SKIP LOCKED` viven mientras dure la transacción.
Lote chico = transacción corta = otros workers pueden trabajar.

---

## 9. Advisory locks

Postgres te deja tomar locks sobre **números arbitrarios**, sin relación con
ninguna fila. Son *tuyos*: Postgres no interpreta el número, sólo garantiza
exclusión mutua.

```sql
SELECT pg_advisory_lock(hashtext('stock:rebuild'));      -- espera hasta obtenerlo
SELECT pg_try_advisory_lock(hashtext('stock:rebuild'));  -- true/false, no espera
SELECT pg_advisory_unlock(hashtext('stock:rebuild'));

SELECT pg_advisory_xact_lock(hashtext('...'));  -- se libera solo al COMMIT/ROLLBACK
```

Verificado en esta base:

```ruby
c = ActiveRecord::Base.connection
c.select_value("SELECT pg_try_advisory_lock(hashtext('stock:rebuild'))")  # => true
c.select_value("SELECT pg_advisory_unlock(hashtext('stock:rebuild'))")    # => true
```

**Este repo no usa advisory locks.** Rails sí: el migrator toma uno para
serializar `db:migrate` entre instancias que arrancan a la vez. Solid Queue, en
cambio, resuelve el mismo problema *sin* advisory locks —usa filas con índice
único (`solid_queue_recurring_executions`, `solid_queue_semaphores`)— y por eso
los jobs de `config/recurring.yml` corren una sola vez aunque tengas 10
servidores. Vale la pena saber que hay dos formas de hacer lo mismo: la fila
única sobrevive a un `pg_bouncer` en transaction pooling y queda auditada; el
advisory lock es más barato y desaparece solo.

Cuándo sirven:

- **Mutex distribuido sin Redis**: "que este recálculo nocturno corra en una sola
  máquina, aunque el cron lo dispare en las tres".
- **Serializar algo que no es una fila**: "un solo import de catálogo a la vez",
  "una sola reconstrucción de índice".
- **Bloquear una fila que todavía no existe**: no podés hacer `FOR UPDATE` sobre
  algo que vas a insertar; sí podés tomar `pg_advisory_xact_lock(hashtext(sku))`.
- Reemplazo de `SELECT FOR UPDATE` cuando la contención es sobre un *concepto*
  y no sobre una fila concreta.

Trampas:

- **La versión `pg_advisory_lock` (no `_xact_`) se libera al cerrar la sesión, no
  al commit.** Con un pool de conexiones, "la sesión" es una conexión reciclada:
  si te olvidás de desbloquear, el lock queda tomado y aparece en otra request
  que reusa esa conexión. Salvo que sepas muy bien lo que hacés, usá
  **`pg_advisory_xact_lock`**.
- **Con PgBouncer en `transaction pooling`, los advisory locks de sesión están
  rotos**, porque la conexión de backend cambia entre statements. Los `_xact_`
  sí funcionan.
- `hashtext` devuelve un `int4`: hay colisiones. Para un mutex operativo da
  igual; para algo por-entidad, usá la variante de dos enteros
  (`pg_advisory_xact_lock(clase, id)`).

En Java, el equivalente conceptual es un `SELECT ... FOR UPDATE` sobre una tabla
de "locks" o un lock de ZooKeeper/Redisson. Los advisory locks son lo mismo, sin
tabla y sin infraestructura extra.

---

## 10. El modelo de concurrencia de Ruby

### 10.1 GVL: qué se solapa y qué no

CRuby (que es lo que corre acá: `ruby 3.3.6 [x86_64-linux]`) tiene un **Global VM
Lock**. Los threads de Ruby son threads del sistema operativo de verdad, pero
**sólo uno ejecuta bytecode de Ruby a la vez**.

| Operación | ¿Se solapa entre threads? |
|---|---|
| Ejecutar Ruby (calcular, serializar, comparar) | ❌ **no** (GVL) |
| Esperar una query de Postgres | ✅ sí (la extensión `pg` libera el GVL) |
| Esperar una llamada HTTP | ✅ sí |
| Leer/escribir archivos | ✅ sí |
| `sleep` | ✅ sí |
| Código C de una gema que no libera el GVL | ❌ no |

Para una app Rails típica esto **no es tan grave como suena**, porque el 60-80%
del tiempo de una request es esperar a la base. Con 3-5 threads, mientras uno
espera un `SELECT`, otro serializa JSON. Por encima de eso el rendimiento se
aplana y la latencia empeora (más threads compitiendo por el mismo GVL).

Dónde se rompe la analogía con Java: en la JVM, 8 threads en 8 cores hacen 8
veces el trabajo de CPU. En CRuby, no. **El paralelismo real en Ruby son
procesos**, no threads. Por eso Puma tiene *workers*.

Corolario que importa acá: **el GVL no te protege de nada a nivel de base**. Dos
threads con dos conexiones a Postgres ejecutan dos transacciones concurrentes de
verdad. Todo lo de este documento aplica igual. Y las estructuras de datos en
memoria compartida (un `Hash` de clase, un cache) **sí** necesitan sincronización:
el GVL garantiza que no se corrompa la VM, no que tu `hash[k] += 1` sea atómico.

### 10.2 Puma: workers × threads

`config/puma.rb`:

```ruby
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count
```

Este archivo **no llama a `workers`**, así que tal como está corre en modo
*single*: 1 proceso × N threads. `.env.example` sugiere `RAILS_MAX_THREADS=5` y
tiene `WEB_CONCURRENCY=2` comentado. Para producción querés los dos:

```yaml
# .env
WEB_CONCURRENCY=2     # procesos (paralelismo real, uno por core aprox.)
RAILS_MAX_THREADS=5   # threads por proceso (concurrencia de IO)
```

La cuenta de conexiones que hay que saber decir de memoria:

```text
conexiones = WEB_CONCURRENCY × RAILS_MAX_THREADS × cantidad_de_bases × cantidad_de_máquinas
```

Rails 8 corre con **4 bases** (`primary`, `cache`, `queue`, `cable`) y **cada una
abre su propio pool**. Con 2 workers × 5 threads × 4 bases = **40 conexiones por
máquina**. Con 3 máquinas, 120 — y el `max_connections` default de Postgres es
100. De ahí sale el clásico:

```text
PG::ConnectionBad: FATAL:  sorry, too many clients already
```

`config/database.yml` ata el pool a los threads (`max_connections:
ENV.fetch("RAILS_MAX_THREADS") { 5 }`) para que nunca haya menos conexiones que
threads. Si el pool es más chico, los threads se pelean y aparece
`ActiveRecord::ConnectionTimeoutError` después de `checkout_timeout: 5`. A
escala, la respuesta es **PgBouncer en transaction pooling** (con la advertencia
de los advisory locks de sesión y de los prepared statements).

### 10.3 `Current` vs un ThreadLocal a mano

`app/models/current.rb`:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :api_token
  attribute :request_id
  attribute :user_agent
  attribute :ip_address

  # El usuario puede venir de una sesión web o de un token de API.
  def user = session&.user || api_token&.user
end
```

`ActiveSupport::CurrentAttributes` es un singleton con alcance de thread/fiber,
igual que un `ThreadLocal` o el `RequestContextHolder` de Spring. **La
diferencia, que es toda la diferencia:** Rails lo **resetea automáticamente** al
final de cada request y de cada job, vía el executor.

Por qué eso importa tanto: Puma reusa los threads de su pool. Con un ThreadLocal
a mano, si alguien se olvida de limpiar, la request N+1 hereda los datos de la N
— o sea, **el usuario B ve el `Current.user` del usuario A**. No es un bug de
performance, es una fuga de datos entre usuarios. Es exactamente el bug que
`ThreadLocal` + thread pool produce en Spring, y por el que existe
`ThreadLocal#remove` en el `finally`.

`app/jobs/application_job.rb` lo hace explícito de todas formas:

```ruby
ensure
  Current.reset
```

**Regla de uso** (está en el comentario del archivo): `Current` es para contexto
transversal (usuario, request_id, IP). **No** para pasar parámetros de negocio
entre capas — eso convierte argumentos explícitos en dependencias globales
invisibles y te arruina los tests. Es el mismo abuso que hacerle `static` a todo
en Java.

---

## 11. Cómo testear concurrencia de verdad

### 11.1 Por qué un test "normal" no sirve

`use_transactional_fixtures = true` (el default de RSpec/Rails) envuelve **cada
ejemplo en una transacción que nunca commitea**. Como la transacción vive en la
conexión (sección 6.1), un thread nuevo toma **otra** conexión del pool y no ve
absolutamente nada de lo que creaste. El test no falla: **encuentra la base
vacía y pasa en verde**.

Ese es el falso verde que hace que un test de concurrencia mal escrito sea peor
que no tener test.

### 11.2 El helper del repo

`spec/support/concurrency.rb:25`:

```ruby
def run_concurrently(count)
  barrier = Concurrent::CyclicBarrier.new(count)
  results = Array.new(count)
  errors  = Array.new(count)

  threads = Array.new(count) do |i|
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do   # su propia conexión
        barrier.wait                                          # arrancan juntos
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

Cuatro decisiones, todas necesarias:

1. **`with_connection`**: cada thread necesita su propia conexión, o no hay
   concurrencia real de base.
2. **`CyclicBarrier`**: los threads arrancan lo más cerca posible en el tiempo.
   Sin la barrera, el thread 1 termina antes de que el 8 arranque y no hay
   carrera que testear.
3. **`rescue` por thread**: una excepción en un thread de Ruby que nadie hace
   `join` se pierde en silencio. Acá se junta en `errors` y el test la asegura
   vacía.
4. **`clear_active_connections!`**: si no devolvés las conexiones al pool, el
   pool se agota y el **siguiente** test falla por `ConnectionTimeoutError`, en
   otro archivo, y perdés media hora.

Y la limpieza, porque sin transacción envolvente hay que borrar a mano:

```ruby
config.around(:each, :concurrency) do |example|
  self.use_transactional_tests = false
  example.run
  tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
  ActiveRecord::Base.connection.execute("TRUNCATE #{...} RESTART IDENTITY CASCADE")
end
```

El pool de test está subido a propósito (`config/database.yml`,
`max_connections: 15` en `test`) porque estos specs levantan hasta 10 threads.
Con el default de 5, el sexto thread se cuelga esperando checkout y el test falla
con `ConnectionTimeoutError` — que es, irónicamente, el mismo síntoma que vas a
ver en producción si dimensionás mal el pool.

### 11.3 Qué se cubre y cuánto tarda

```bash
export PATH="/opt/rbenv/versions/3.3.6/bin:$PATH"
bundle exec rspec spec/integration/concurrency_spec.rb
```

```text
Concurrencia sobre el stock
  prevención de deadlocks en transferencias
    dos transferencias cruzadas con los mismos productos NO se traban
  optimistic locking
    el segundo escritor recibe StaleObjectError
  contador correlativo sin huecos
    10 threads generan 10 referencias distintas y consecutivas
  creación concurrente del stock_item
    no crea filas duplicadas para el mismo par producto/depósito
  LOST UPDATE: 8 egresos simultáneos sobre 10 unidades
    NUNCA deja el stock en negativo y sólo prosperan los que caben
    el ledger sigue cerrando exactamente después de la tormenta
  idempotencia bajo concurrencia
    la misma clave desde 5 threads aplica UNA sola vez
  reservas concurrentes
    no se puede reservar dos veces la misma unidad

Finished in 2.18 seconds (files took 1.69 seconds to load)
8 examples, 0 failures
```

Truco para forzar el choque cuando la ventana es muy chica: **ensanchala a
propósito**. El spec de optimistic locking mete un `sleep 0.05` entre el `find` y
el `update!`. No es trampa: es la única forma determinística de reproducir una
carrera de microsegundos.

Lo que **no** cubre y hay que reconocerlo en una entrevista: estos tests
verifican propiedades bajo la concurrencia que el test genera. No son una prueba
de ausencia de races. Para eso se complementan con el invariante global:
`StockItems::Reconciliation` compara la proyección contra el `SUM` del ledger y
`Stock::ReconcileBalancesJob` la corre todas las noches (`config/recurring.yml`).
Un test de concurrencia dice "no encontré el bug"; la reconciliación dice "si
hay un bug, me entero".

---

## Errores que ves en producción

**1. `PG::TRDeadlockDetected: deadlock detected` intermitente, siempre en la
misma operación multi-fila.**
Síntoma: 500 esporádicos, imposibles de reproducir en dev, siempre en
transferencias o recepciones de varias líneas.
Causa: dos transacciones toman los mismos locks en distinto orden.
Arreglo: orden total determinístico — `ORDER BY id` en el `FOR UPDATE`
(`app/services/stock/transfers/dispatch.rb:99`), y un orden fijo entre tablas
(reserva → item, siempre). El `retry_on ActiveRecord::Deadlocked` es el cinturón,
no el arreglo.

**2. El stock queda en un número que no cierra con el ledger, sin ningún error.**
Síntoma: `StockItems::Reconciliation` devuelve filas; nadie vio una excepción.
Causa: alguien escribió `quantity_on_hand` sin pasar por `ApplyMovement`
(típicamente un `update_all`, un `update_column` o una corrección manual por
`psql`), o un lost update por leer-calcular-escribir sin lock.
Arreglo: todo cambio de cantidad pasa por `Stock::ApplyMovement`; el job nocturno
alerta, y **no auto-corrige por default** (auto-corregir esconde el bug).

**3. `ActiveRecord::LockWaitTimeout` en cascada durante un pico.**
Síntoma: muchos 409 `:locked` a la vez, todos sobre el mismo producto.
Causa: fila caliente. Un producto muy vendido serializa todas las operaciones.
Arreglo: transacciones más cortas (nada de HTTP adentro), mover trabajo al
`after_commit`, y si sigue: `atomically_decrement` para el camino simple (una
sentencia en vez de dos), o rediseñar (cubos de stock por depósito).

**4. `PG::ConnectionBad: FATAL: sorry, too many clients already`.**
Síntoma: aparece al agregar la tercera máquina o al subir `RAILS_MAX_THREADS`.
Causa: `WEB_CONCURRENCY × RAILS_MAX_THREADS × 4 bases × N máquinas` superó
`max_connections`.
Arreglo: hacer la cuenta antes de escalar; PgBouncer en transaction pooling; y no
olvidar que `cache`, `queue` y `cable` abren sus propios pools.

**5. Un test de concurrencia que pasa en verde sin ejercitar un solo lock.**
Síntoma: el spec con threads nunca falla — ni siquiera si le sacás el `.lock` al
service.
Causa: transactional fixtures. La transacción del ejemplo no commitea, los
threads toman otra conexión, encuentran la base vacía y no hay carrera.
Arreglo: `use_transactional_tests = false` para ese spec y limpieza con
`TRUNCATE` (`spec/support/concurrency.rb`). Ojo con el mito inverso: `after_commit`
**sí** corre bajo transactional fixtures desde Rails 5 (la transacción del test
es `joinable: false`).

**6. Un `raise ActiveRecord::Rollback` que no revierte nada.**
Síntoma: datos parciales commiteados después de una regla de negocio que falló,
sin error en el log.
Causa: el `raise` está en un `transaction` anidado sin `requires_new: true`; el
bloque se tragó la excepción y la externa siguió.
Arreglo: `ApplicationService::BusinessRuleViolation` — una excepción propia que
sube hasta el `rescue` de la transacción externa
(`app/services/application_service.rb:46`).

**7. Un `return` adentro de un `transaction do` que commitea.**
Síntoma: código que "funcionaba" en Rails 6 y en 7+ deja basura a medias.
Causa: Rails 7.0 cambió `return`/`break` de rollback a commit.
Arreglo: no salir del bloque con `return`; usar `next` (dentro del bloque) o una
excepción. El repo usa `next success(...)` y `fail!`.

**8. `PG::UniqueViolation` en `stock_items` bajo doble POST.**
Síntoma: 500 en picos, dos requests idénticas simultáneas.
Causa: `find_or_create_by!` sin rescue — los dos threads pasan el `find`.
Arreglo (**✅ corregido en este repo**): `StockItem.find_or_provision!`
(`app/models/stock_item.rb`), que confía en el índice único y rescata el choque
releyendo la fila ganadora. Ojo con las dos trampas del rescue ingenuo, que acá
estuvieron vivas y hoy están cerradas (§4): hace falta
`transaction(requires_new: true)` —un SAVEPOINT— para que el rescue sirva de algo
estando dentro de una transacción, y hay que rescatar **también**
`RecordInvalid`, no sólo `RecordNotUnique`. Regresiones en
`spec/models/stock_item_spec.rb`.

**9. La base "se puso lenta" y `autovacuum` no limpia nada.**
Síntoma: tablas hinchadas, planes que empeoran, disco creciendo.
Causa: una transacción vieja abierta (típicamente `idle in transaction` por una
llamada HTTP adentro de una transacción) bloquea el vacuum **de toda la base**.
Arreglo: `idle_in_transaction_session_timeout` (ya está en `config/database.yml`),
efectos afuera de la transacción, y lotes en vez de transacciones gigantes.

**10. `PG::FeatureNotSupported: FOR UPDATE cannot be applied to the nullable side
of an outer join`.**
Síntoma: explota al agregar un `includes` con `references` o un `eager_load` a
una query que ya tenía `.lock`.
Arreglo: usar `includes` sin `references` (preload = queries separadas) y
bloquear explícitamente las otras tablas si hace falta.

**11. Fuga de contexto entre requests (el usuario B ve datos del A).**
Síntoma: rarísimo, no reproducible, aparece bajo carga.
Causa: un `Thread.current[:algo]` a mano en un pool de threads reusados.
Arreglo: `ActiveSupport::CurrentAttributes` (`app/models/current.rb`), que Rails
resetea solo al final de cada request y de cada job.

**12. Un job que corre para una transacción que hizo rollback.**
Síntoma: el worker procesa una orden o un movimiento que en la base no existe
(`RecordNotFound` intermitente), o manda un mail por algo que se revirtió.
Causa: `perform_later` adentro de la transacción, con el enqueue inmediato.
Este bug **estuvo vivo acá**: la línea
`config.active_job.enqueue_after_transaction_commit = :always` de
`config/initializers/sidekiq.rb` no lo evitaba, porque Rails 8.1 removió esa
config global y `ActiveJob::Base.enqueue_after_transaction_commit` seguía en
`false`.
Arreglo (**✅ ya aplicado**): se borró la línea del initializer y
`app/jobs/application_job.rb` declara `self.enqueue_after_transaction_commit = true`.
Verificado: `ApplicationJob.enqueue_after_transaction_commit # => true`, y un
`perform_later` dentro de una transacción que hace rollback ya no encola nada
(§7.1). Para lo que directamente no se puede perder, outbox.

---

## Cómo responder esto en una entrevista

**"Dos usuarios venden la última unidad al mismo tiempo. ¿Qué hacés?"**

> Bloqueo pesimista de la fila del agregado y valido **después** de bloquear.
> `StockItem.lock.find(id)` genera `SELECT ... FOR UPDATE`, así que el segundo
> se queda esperando en el `SELECT` y cuando entra lee el saldo real, no el
> viejo. Es `Stock::ApplyMovement`, el único lugar del sistema que cambia una
> cantidad. Bloqueo una sola fila —el par producto/depósito—, así que dos
> productos distintos siguen corriendo 100% en paralelo; Postgres no escala
> locks a la tabla.
>
> Abajo de eso tengo dos redes más: un CHECK constraint `quantity_on_hand >= 0`
> —porque una validación de Rails corre en un proceso Ruby y no es atómica—, y
> un ledger append-only contra el que reconcilio todas las noches.
>
> El trade-off: serializo las operaciones sobre el mismo producto. Si un SKU se
> vuelve una fila caliente, eso es un cuello de botella, y ahí pasaría a un
> `UPDATE` condicional de una sola sentencia o rediseñaría el esquema.

**"¿Optimista o pesimista?"**

> Depende de la probabilidad de conflicto y de quién puede reintentar.
> **Pesimista** cuando el conflicto es probable y el conflicto es caro: stock,
> reservas, transferencias. Pago un lock que casi siempre voy a necesitar.
> **Optimista** cuando el conflicto es raro y hay un humano que puede reintentar:
> editar la ficha de un producto. Ahí el costo en el camino feliz es cero, y
> cuando hay choque devuelvo 409 con el `lock_version` en el JSON — que es
> exactamente `ETag` + `If-Match`, y evita el *last write wins* silencioso.
>
> La diferencia con `@Version` de JPA que siempre aclaro: en Rails el chequeo
> ocurre en **cada `UPDATE`**, no en el flush, porque no hay sesión de
> persistencia ni dirty checking diferido. Y `update_all`/`update_column`
> **saltean** el optimistic locking, así que si escribís SQL crudo tenés que
> incrementar `lock_version` a mano — en este repo lo hace
> `StockItem.atomically_decrement`.

**"¿Cómo evitás deadlocks?"**

> Orden total y determinístico de adquisición. En las transferencias
> multi-producto uso una sola query `... WHERE product_id IN (...) ORDER BY id
> FOR UPDATE`: si todas las transacciones piden en el mismo orden, no puede
> haber ciclo. Es una garantía, no una mejora estadística. Y mantengo un orden
> fijo también entre tablas: siempre reserva antes que stock_item.
>
> Reintento con backoff (`retry_on ActiveRecord::Deadlocked`), pero eso es el
> cinturón de seguridad, no la solución: el retry no baja la tasa de deadlocks,
> la esconde, cada uno cuesta el `deadlock_timeout` de 1 s, y en una request HTTP
> síncrona no podés reintentar en 18 segundos. Si veo deadlocks en el log, busco
> el orden de locks, no subo los reintentos.
>
> Para diagnosticar: `pg_blocking_pids()` cruzado con `pg_stat_activity` te dice
> quién bloquea a quién ahora; y el log del servidor —no el mensaje al cliente—
> tiene las queries exactas de las dos transacciones.

**"¿Qué nivel de aislamiento usás y por qué no SERIALIZABLE?"**

> READ COMMITTED, el default. Con SERIALIZABLE me ahorraría pensar en locks,
> pero Postgres implementa SSI: no bloquea, rastrea dependencias y **aborta a
> posteriori** con `could not serialize access due to read/write dependencies`.
> Eso significa que **toda** transacción necesita un bucle de reintento, y con
> alta concurrencia sobre la misma fila la tasa de abortos sube. Prefiero locks
> explícitos: son más código, pero el comportamiento es predecible y localizado.
>
> Dos cosas que aclaro siempre: Postgres **no tiene dirty reads** ni siquiera en
> READ COMMITTED —`READ UNCOMMITTED` se comporta como READ COMMITTED—, y su
> REPEATABLE READ es snapshot isolation, o sea que también elimina phantoms, a
> diferencia del mínimo que exige el estándar. Y no es lo mismo que el
> REPEATABLE READ de MySQL, que usa gap locks y donde una lectura bloqueante
> (`SELECT ... FOR UPDATE`) no lee el snapshot sino la última versión
> commiteada.
>
> Lo que REPEATABLE READ **no** te da es write skew: dos transacciones que leen
> lo mismo y escriben filas distintas rompen una invariante que cruza filas. Eso
> sólo lo tapa SERIALIZABLE.

**"Explicame la trampa de `ActiveRecord::Rollback`."**

> Un `transaction` anidado sin `requires_new: true` **no abre nada**: se une a la
> de afuera. Y el bloque `transaction` **se traga** `ActiveRecord::Rollback` por
> diseño. Resultado: el `raise` no revierte nada y la transacción externa
> commitea igual, sin error, sin warning. Lo verifiqué en Rails 8.1: las tres
> filas quedan escritas.
>
> Con `requires_new: true` sí funciona, porque emite un `SAVEPOINT` — es
> `PROPAGATION_NESTED` de Spring, con la misma advertencia: si la externa hace
> rollback se lleva todo puesto, un savepoint no es una transacción
> independiente.
>
> En este repo los services se anidan (`Transfers::Dispatch` llama a
> `ApplyMovement`), así que uso una excepción propia,
> `ApplicationService::BusinessRuleViolation`, que viaja hasta el `rescue` de la
> transacción más externa. Eso me cubre también el otro cambio: desde Rails 7.0
> un `return` adentro de un bloque `transaction` **commitea** (antes hacía
> rollback), y ese cambio rompió mucho código en silencio.

**"¿Por qué no encolás el job adentro de la transacción?"**

> Porque con un adapter que no es transaccional —Sidekiq sobre Redis— el job se
> encola al instante: si la transacción hace rollback, el worker procesa una
> orden que no existe; y al revés, el worker puede levantarlo antes del COMMIT y
> tirar `RecordNotFound`. La herramienta es
> `enqueue_after_transaction_commit`, que difiere el encolado hasta el COMMIT
> para cualquier adapter. Ojo con la versión: en Rails 7.2 era la config global
> `config.active_job.enqueue_after_transaction_commit`, y en 8.1 la removieron —
> hoy es un atributo por clase de job. Este repo tenía puesta la forma vieja, que
> no hace absolutamente nada y encima te contesta `:always` si le preguntás a la
> config; lo arreglé borrando esa línea del initializer y poniendo
> `self.enqueue_after_transaction_commit = true` en `ApplicationJob`. Lo cuento
> porque es el tipo de bug que no avisa: no explota, no loguea, no hay
> deprecation warning, y sólo lo ves si medís el efecto o le preguntás a
> `ActiveJob::Base.enqueue_after_transaction_commit`.
>
> Pero eso **todavía no es un outbox**: entre el COMMIT y el enqueue hay una
> ventana de microsegundos donde, si el proceso muere o Redis está caído, el job
> se pierde y nadie se entera. Para eventos que no se pueden perder escribo el
> evento como una fila más en la misma transacción (`outbox_events`) y un relay
> lo publica después con `FOR UPDATE SKIP LOCKED`. El precio es at-least-once, así
> que el consumidor deduplica por `event_id`. Saber dónde está esa línea —outbox
> para movimientos de stock, `enqueue_after_transaction_commit` para un mail— es
> la respuesta madura.

**"¿Cómo testeás esto?"**

> Con threads reales y conexiones reales. Un test de concurrencia que no abre
> conexiones separadas no está testeando concurrencia. Y hay que **desactivar las
> transactional fixtures**: la transacción del test nunca commitea, así que el
> thread nuevo toma otra conexión, no ve nada y el test pasa en verde sin haber
> ejercitado un solo lock. Ese falso verde es peor que no tener test.
>
> Mi helper usa una `CyclicBarrier` para que arranquen juntos, un `rescue` por
> thread (una excepción en un thread sin `join` se pierde en silencio), y
> devuelve las conexiones al pool al final o el test siguiente falla por
> checkout. El pool de test está en 15 para que entren 10 threads.
>
> Son 8 ejemplos que corren en ~2,3 segundos y cubren lost update, reservas
> dobles, creación concurrente del stock_item, idempotencia, optimistic locking,
> el contador sin huecos y el deadlock de transferencias cruzadas. Y los
> complemento con un invariante global: un job nocturno compara la proyección
> contra el `SUM` del ledger. Los tests dicen "no encontré el bug"; la
> reconciliación dice "si hay uno, me entero".

**"¿El GVL de Ruby te protege de las races?"**

> No, y esa es la confusión más común. El GVL garantiza que sólo un thread
> ejecute bytecode de Ruby a la vez, pero **la extensión `pg` lo libera mientras
> espera la base**: dos threads tienen dos conexiones y dos transacciones
> concurrentes de verdad. Todo el problema de locking existe igual.
>
> Lo que sí cambia es el paralelismo de CPU: en la JVM 8 threads usan 8 cores,
> en CRuby no. Por eso el paralelismo real en Ruby son procesos —los *workers* de
> Puma— y los threads sirven para solapar IO. La cuenta que hay que tener en la
> cabeza es `WEB_CONCURRENCY × RAILS_MAX_THREADS × cantidad de bases × máquinas`
> contra el `max_connections` de Postgres; en Rails 8 son 4 bases, y ahí es donde
> aparece el `too many clients already`.
>
> Y para estado por request uso `CurrentAttributes`, no un ThreadLocal a mano:
> Rails garantiza el reset al final de la request y del job. Con un pool de
> threads reusados, un ThreadLocal sin limpiar es una fuga de datos entre
> usuarios, que es el mismo bug que en Spring con `RequestContextHolder`.

---

## Para seguir

- `docs/03-base-de-datos-y-activerecord.md` — MVCC, columnas generadas, índices
  parciales, `schema.rb` vs `structure.sql`, pool y réplicas.
- `docs/04-optimizacion-de-queries.md` — planes de ejecución, N+1 y por qué una
  query lenta adentro de una transacción es un problema de concurrencia.
- `docs/05-solid-y-patrones.md` — por qué los casos de uso son objetos con
  `call`, y cómo eso hace que la transacción tenga un solo dueño.
- `docs/10-errores-comunes.md` §6 — el query cache comiéndose un
  `INSERT ... RETURNING`, que es la otra mitad de la historia de `SequenceCounter`
  (§3.3).
- `docs/11-api-rest-serializacion-e-idempotencia.md` §7 — idempotencia sobre
  HTTP: la `Idempotency-Key`, la tabla `idempotency_keys` y cómo se combina con
  los locks de acá.
- Los comentarios de `app/services/stock/apply_movement.rb`,
  `app/services/application_service.rb`, `app/models/stock_item.rb`,
  `db/migrate/20260830160600_create_stock_items.rb` y
  `spec/support/concurrency.rb`: son la fuente de verdad de todo lo de acá.
