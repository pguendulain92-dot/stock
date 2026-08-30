# Rate limiting: teoría, algoritmos e implementación

Acá tenés por qué un rate limiter no es "un contador con TTL": en qué capa va,
qué algoritmo elegís y qué te cuesta cada uno, cómo se elige el discriminador
(la parte que más se equivoca), por qué el store tiene que ser compartido y
atómico, y cómo se rompe todo cuando confiás en `X-Forwarded-For`.

Está escrito sobre las dos capas reales de este repo: `Rack::Attack` en el borde
(`config/initializers/rack_attack.rb`) y `ActionController#rate_limit` nativo de
Rails 8 en los controllers (`app/controllers/api/v1/base_controller.rb`). Todos
los números que ves salieron de correr la app en `localhost:3001` con Redis
7.0.15 y de leer el código de `actionpack-8.1.3.1` y `rack-attack-6.8.0`
instalados en esta máquina. Cuando digo "corta en la request 21", lo corrí.

Venís de Java: el mapa mental es Bucket4j + Resilience4j + el
`RequestRateLimiter` de Spring Cloud Gateway. Te marco dónde la analogía se
rompe, que es donde se cometen los errores.

---

## 1. Por qué existe: no es una sola cosa

El rate limiting resuelve seis problemas distintos que la gente mete en la misma
bolsa. Si no sabés cuál estás resolviendo, elegís mal el límite y el
discriminador.

| Problema | Qué pasa si no lo limitás | Discriminador correcto |
|---|---|---|
| **Credential stuffing** | Un atacante prueba 50.000 pares usuario/clave filtrados de otro sitio | IP **y** email (ver §4.4) |
| **Ataque dirigido a una cuenta** | Un botnet con 5.000 IPs prueba 10 claves cada una contra `ana@empresa.com` | email (el de IP no lo ve) |
| **Scraping** | Te copian el catálogo entero; tu competencia tiene tus precios | token / IP + endpoint |
| **Costo** | Cada `/api/v1/reports/valuation` es una agregación sobre toda la tabla; 100 clientes concurrentes te funden la CPU de Postgres | token, con costo por endpoint |
| **Fairness** | Un cliente con un bug en su retry loop consume el 90% de tus workers y los otros 200 clientes ven timeouts | token/tenant |
| **Cascada de fallas** | Un pico satura Puma, se llena el backlog, los health checks empiezan a fallar, el balanceador saca instancias, lo que quedó recibe más carga | global (load shedding) |

Fijate que los últimos dos no son *seguridad*: son **disponibilidad**. Y eso
cambia la respuesta correcta cuando el limitador falla (§5.5).

### 1.1 Rate limiting vs sus primos

Estos cinco patrones se confunden todo el tiempo. En una entrevista te van a
pedir que los distingas.

| Patrón | Qué mide | Qué hace | Equivalente Java |
|---|---|---|---|
| **Rate limiting** | requests por unidad de tiempo, por cliente | rechaza con 429 | Bucket4j, `RequestRateLimiter` de Spring Cloud Gateway |
| **Throttling** | igual, pero *demora* en vez de rechazar | encola / duerme al cliente | `RateLimiter.acquire()` de Guava (bloquea) |
| **Load shedding** | salud del *servidor* (latencia, cola, CPU) | tira requests **sin importar de quién sean** | Netflix `concurrency-limits` (AIMD/Gradient), CoDel |
| **Circuit breaker** | tasa de error de una *dependencia* | deja de llamar a lo que ya está roto | `@CircuitBreaker` de Resilience4j |
| **Bulkhead** | concurrencia por *pool* | aísla, para que una dependencia lenta no se coma todos los threads | `@Bulkhead`, pools separados |

Diferencias que importan:

- **Rate limiting es por cliente; load shedding es por servidor.** Un rate
  limiter perfectamente configurado no te salva de un pico legítimo de 10.000
  clientes distintos: para eso necesitás load shedding. Este repo tiene rate
  limiting, no tiene load shedding (lo hace el balanceador con su cola).
- **Throttling (demorar) es casi siempre una mala idea en HTTP.** Si demorás la
  request, seguís ocupando un thread de Puma y una conexión. El atacante te
  consume recursos igual. Demorar sirve cuando el cliente es un consumidor de
  cola que vos controlás, no cuando es una request web. Rechazá rápido.
- **Circuit breaker protege al de *abajo*; rate limiting protege al de
  *arriba*.** Son direcciones opuestas.

> **Donde se rompe la analogía con Java.** En Spring vos ponés `@RateLimiter` en
> un método de servicio y Resilience4j interpone un proxy AOP. En Rails no hay
> proxies: `rate_limit` es azúcar sobre `before_action` (lo vas a ver literal en
> §8.1), y `Rack::Attack` es un middleware Rack. No hay contenedor de DI, no hay
> `BeanPostProcessor`, no hay bytecode instrumentado. Todo es composición
> explícita de objetos que responden a `call`. Eso hace el stack mucho más fácil
> de leer (`bin/rails middleware` te lo imprime entero) y mucho más difícil de
> "activar por accidente".

---

## 2. Dónde limitar: cinco capas, cinco precios

Cada capa sabe cosas distintas y cuesta cosas distintas. La regla es: **limitá
lo más afuera que puedas con la información que tenés**.

| Capa | Qué sabe | Qué NO sabe | Costo de rechazar | Latencia típica |
|---|---|---|---|---|
| **CDN / WAF** (Cloudflare, CloudFront) | IP, ASN, país, JA3, path, headers | quién es el usuario, de qué plan | ~0 para vos: ni te enterás | µs, en el borde de red |
| **Load balancer** (ALB, nginx `limit_req`) | IP, path, headers | identidad de negocio | ~0 tu app | µs |
| **Middleware Rack** (`Rack::Attack`) | IP resuelta, path, método, headers, **body parseado** | usuario autenticado, plan, tenant | 1 worker de Puma ocupado ~3 ms | **2,9 ms** medidos |
| **Controller** (`rate_limit`) | **todo**: usuario, token, scopes, tenant, plan | — | 1 worker + routing + auth (2 SELECT) | **12 ms** medidos |
| **Base de datos** (constraint, cuota en tabla) | todo + estado histórico | — | conexión + transacción | decenas de ms |

Los números de la tabla son reales, medidos con `curl` contra el repo corriendo
en desarrollo:

```bash
# request permitida (200), endpoint /api/v1/reports/reconciliation
  total=0.016466s code=200
  total=0.013032s code=200
  total=0.012024s code=200

# bloqueada por CAPA 2 (rate_limit del controller): ya pagó auth + routing
  total=0.013872s code=429
  total=0.011793s code=429
  total=0.011410s code=429

# bloqueada por CAPA 1 (Rack::Attack sobre POST /session)
  total=0.002955s code=429
  total=0.003374s code=429
  total=0.002829s code=429
```

Cortar en el borde sale ~4× más barato que cortar en el controller, y eso es en
un endpoint *barato*. En `/api/v1/reports/valuation` (una agregación sobre todo
el inventario) la diferencia es de otro orden.

El `Server-Timing` que devuelve el 429 de Rack::Attack lo confirma desde
adentro:

```text
server-timing: cache_read.active_support;dur=0.30, cache_increment.active_support;dur=0.43,
               throttle.rack_attack;dur=0.14, rack.attack;dur=0.00
x-runtime: 0.001452
```

1,45 ms de tiempo Rails total, de los cuales 0,73 ms son las dos idas a Redis:
el `cache_read` es el chequeo de ban del `Fail2Ban` de la blocklist y el
`cache_increment` es el contador del throttle. El resto del stack (routing,
controller, ActiveRecord, vistas) ni se ejecutó.

### 2.1 Por qué este repo necesita las DOS capas

No es redundancia: **cada capa puede responder una pregunta que la otra no
puede**.

```text
                    ┌─────────────────────────────────────────┐
  Internet ────────▶│ (en prod: CDN/WAF + ALB — fuera de este │
                    │  repo, pero es la primera línea real)   │
                    └───────────────────┬─────────────────────┘
                                        ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ Proceso Puma                                                     │
  │                                                                  │
  │  ActionDispatch::RemoteIp    ← resuelve X-Forwarded-For          │
  │  ┌────────────────────────────────────────────────┐              │
  │  │ CAPA 1 · Rack::Attack                          │  ~3 ms       │
  │  │  sabe: IP real, path, método, params, headers  │              │
  │  │  NO sabe: quién sos                            │              │
  │  └────────────────────┬───────────────────────────┘              │
  │                       ▼                                          │
  │  routing → controller → authenticate_api_token!  ← 2 SELECT      │
  │  ┌────────────────────────────────────────────────┐              │
  │  │ CAPA 2 · ActionController#rate_limit           │  ~12 ms      │
  │  │  sabe: current_api_token, user, scopes, plan   │              │
  │  └────────────────────┬───────────────────────────┘              │
  │                       ▼                                          │
  │                    la acción                                     │
  └──────────────────────────────────────────────────────────────────┘
```

- **Capa 1** absorbe el volumen bruto: escaneo de vulnerabilidades, fuerza bruta
  de login, floods anónimos. No necesita saber quién sos porque su trabajo es
  que el que no es nadie no te tire abajo.
- **Capa 2** aplica **política comercial**: "este token es del plan free, tiene
  20 reportes por minuto". Esa información sólo existe después de autenticar.

Un ejemplo concreto del repo: `Api::V1::ReportsController` limita a 20/min *por
token* (`app/controllers/api/v1/reports_controller.rb:11-15`). Rack::Attack no
podría hacer eso sin volver a resolver el token contra la base — o sea, sin
duplicar la autenticación en el middleware. Esa resolución son dos `SELECT`
(el `ApiToken` por digest y su `User`) más, a lo sumo una vez por minuto, el
`UPDATE` de `ApiToken#touch_usage!` (`app/models/api_token.rb:77-81`). Y a la
inversa: la capa 2 nunca ve
un request con un token inválido, porque `authenticate_api_token!` ya devolvió
401 y cortó la cadena (esto tiene una consecuencia fea; ver §8.3).

### 2.2 El stack real, y una sorpresa

```bash
$ bin/rails middleware
use ActionDispatch::HostAuthorization
use Rack::Sendfile
use ActionDispatch::Static
use Propshaft::Server
use ActionDispatch::Executor
use ActionDispatch::ServerTiming
use ActiveSupport::Cache::Strategy::LocalCache::Middleware
use Rack::Runtime
use Rack::MethodOverride
use ActionDispatch::RequestId
use ActionDispatch::RemoteIp
use Rack::Attack                      ← el nuestro (config/application.rb:52)
use Propshaft::QuietAssets
use Rails::Rack::Logger
...
use Rack::TempfileReaper
use Rack::Attack                      ← ¿¿otra vez??
use Bullet::Rack
run Stock::Application.routes
```

`Rack::Attack` aparece **dos veces**. No es un bug del repo: la gema trae un
railtie que se agrega solo al final del stack.

```ruby
# rack-attack-6.8.0/lib/rack/attack/railtie.rb
initializer "rack-attack.middleware" do |app|
  app.middleware.use(Rack::Attack)
end
```

Y `config/application.rb:52` inserta una segunda instancia en la posición
correcta. ¿Por qué no cuenta doble? Por esta guarda:

```ruby
# rack-attack-6.8.0/lib/rack/attack.rb:104-107
def call(env)
  return @app.call(env) if !self.class.enabled || env["rack.attack.called"]

  env["rack.attack.called"] = true
  ...
```

La primera instancia (la de después de `RemoteIp`) marca el `env` y la segunda es
un passthrough. Funciona, pero es una capa de cebolla fantasma, y es exactamente
el tipo de cosa que te hace perder tres horas el día que cambie el comportamiento
entre versiones.

**Cómo se saca la duplicada, y por qué la solución obvia falla.** La clave está en
cómo Rails aplica las operaciones sobre el stack:
`Rails::Configuration::MiddlewareStackProxy` guarda **dos** listas —
`@operations` y `@delete_operations`— y `merge_into` corre **primero todas las
operaciones y después todas las de borrado** (`railties-8.1.3.1/lib/rails/configuration.rb:88-94`).
`delete`, `move_before` y `move_after` van en la segunda lista; `use`,
`insert_before` e `insert_after` en la primera.

O sea que un `config.middleware.delete Rack::Attack` **no** corre antes que el
railtie: corre *al final de todo*, y como `MiddlewareStack#delete` usa `reject!`
(`actionpack-8.1.3.1/lib/action_dispatch/middleware/stack.rb:131-133`), te borra
**las dos**. Simulado con el stack real:

```text
hoy (insert_after):     RequestId, RemoteIp, Attack, Logger, TempfileReaper, Attack
insert_after + delete:  RequestId, RemoteIp, Logger, TempfileReaper       ← ¡ninguna!
sólo move_after:        RequestId, RemoteIp, Attack, Logger, TempfileReaper
```

La receta que funciona es la tercera: **borrá el `insert_after` de
`application.rb:52` y dejá sólo `move_after`**, que mueve la instancia que puso
el railtie en vez de agregar otra.

```ruby
# config/application.rb — reemplazo del insert_after
config.middleware.move_after ActionDispatch::RemoteIp, Rack::Attack
```

Funciona porque `move_after` está en `@delete_operations` (corre después del
`use` del railtie) y `MiddlewareStack#move_after` saca **una** sola instancia
(`delete_at` sobre el primer índice) y la reinserta en la posición pedida. Queda
un único `Rack::Attack`, justo después de `RemoteIp`. Y siempre: **verificalo con
`bin/rails middleware`**, que es la única fuente de verdad del stack armado.

> **Analogía Java y dónde se rompe.** El stack Rack es la `FilterChain` de
> Servlet, y `insert_after` es el `@Order`. La diferencia: en Spring el orden lo
> resolvés con anotaciones y auto-configuración, y verlo requiere debuggear o
> `ApplicationContext` reflection. Acá lo imprimís con un comando y es una lista
> ordenada de objetos. La contra: en Spring un filtro mal ordenado normalmente
> te explota; en Rack un middleware mal ordenado **funciona silenciosamente
> mal** (§6.3).

---

## 3. Los algoritmos

Cinco algoritmos, y sólo cinco. Todo lo demás es una variante.

### 3.1 Fixed window (ventana fija)

Es lo que usa `Rack::Attack`. La ventana se calcula dividiendo el epoch por el
período, así que las ventanas están **alineadas al reloj absoluto**, no al
primer request del cliente.

```text
funcion permitir(cliente, limite, periodo):
    ventana = floor(ahora_epoch / periodo)
    clave   = "#{cliente}:#{ventana}"
    n       = INCR(clave)
    si n == 1: EXPIRE(clave, periodo)
    devolver n <= limite
```

La implementación real es exactamente eso:

```ruby
# rack-attack-6.8.0/lib/rack/attack/cache.rb:69-74
def key_and_expiry(unprefixed_key, period)
  @last_epoch_time = Time.now.to_i
  # Add 1 to expires_in to avoid timing error
  expires_in = (period - (@last_epoch_time % period) + 1).to_i
  ["#{prefix}:#{(@last_epoch_time / period).to_i}:#{unprefixed_key}", expires_in]
end
```

Dos detalles finos que vale la pena entender:

1. La clave lleva el **índice de ventana** (`epoch / period`), no el nombre del
   cliente solo. Cuando la ventana cambia, la clave cambia, y el contador
   arranca de cero sin borrar nada.
2. El TTL **no es el período**: es *lo que queda de la ventana actual*. Por eso
   Redis lo puede dejar expirar solo.

Las claves reales después de 24 requests contra `/api/v1/reports/reconciliation`:

```bash
$ redis-cli -n 0 --scan --pattern '*'
rack-attack:rack::attack:5960376:req/ip:127.0.0.1                      => 24  ttl=208
rack-attack:rack::attack:29801881:api/heavy-reports:127.0.0.1          => 24  ttl=28
rack-attack:rack::attack:496698:api/token:3f465533...b25d9             => 24  ttl=3508
ratelimit:rate-limit:api/v1/reports:reports:3                          => 24  ttl=54
ratelimit:rate-limit:api_v1:api-global:3                               => 24  ttl=54
```

Leé la clave `rack-attack:rack::attack:5960376:req/ip:127.0.0.1`:
`rack-attack` es el `namespace:` del `RedisCacheStore`
(`config/initializers/rack_attack.rb:74`), `rack::attack` es el `prefix` de
`Rack::Attack::Cache`, `5960376` es el índice de ventana (`epoch / 300`, porque
`req/ip` tiene `period: 5.minutes`), `req/ip` es el nombre del throttle y
`127.0.0.1` el discriminador. TTL 208 s = lo que le quedaba a esa ventana de 300.

#### El problema del borde de ventana, con números

```ruby
period = 60; limit = 100
1_800_000_059 / 60  # => 30000000   (hh:mm:59, último segundo de la ventana)
1_800_000_060 / 60  # => 30000001   (hh:mm+1:00, primer segundo de la siguiente)
```

100 requests en el último segundo de una ventana + 100 en el primer segundo de
la siguiente = **200 requests en 2 segundos**, y ninguna viola el límite de
100/min. La tasa pico efectiva es de 100 req/s cuando el límite nominal es 1,67
req/s: **60× el límite declarado**.

Y no es teórico. Esto me pasó *sin querer* midiendo el throttle de login
(`logins/ip`, 5 cada 20 s). Ocho POST seguidos a `/session` desde dev, lentos
porque el primer request compila las vistas:

```text
1 -> 422    5 -> 422
2 -> 422    6 -> 422
3 -> 422    7 -> 422
4 -> 422    8 -> 422      ← ningún 429
```

```bash
$ redis-cli --scan --pattern '*logins*'
rack-attack:rack::attack:89405646:logins/ip:127.0.0.1
rack-attack:rack::attack:89405647:logins/ip:127.0.0.1   # dos ventanas
```

Los 8 intentos cayeron a caballo del borde (5 en una ventana, 3 en la otra) y
**nadie fue bloqueado**. Repitiendo la misma tanda dentro de una sola ventana:

```text
1 -> 422 (t=124ms)    5 -> 422 (t=606ms)
2 -> 422 (t=241ms)    6 -> 429 (t=621ms)   ← acá sí
3 -> 422 (t=364ms)    7 -> 429 (t=634ms)
4 -> 422 (t=488ms)    8 -> 429 (t=647ms)
```

Para un límite de login, esa diferencia importa: significa que el atacante que
sincroniza con el reloj obtiene el doble de intentos por ventana.

**Cuándo alcanza igual:** cuando el límite es una red de contención gruesa
(`req/ip: 300/5min`) y el 2× no cambia nada. **Cuándo no alcanza:** cuando el
límite es la defensa principal contra fuerza bruta, o cuando el cliente paga por
el límite y el 2× es plata.

### 3.2 Sliding window log

Guardás el timestamp de cada request en un sorted set y contás los que caen en
la ventana móvil.

```text
funcion permitir(cliente, limite, periodo):
    ahora = ahora_ms()
    ZREMRANGEBYSCORE clave -inf (ahora - periodo)     # tirá los viejos
    n = ZCARD clave
    si n < limite:
        ZADD clave ahora ahora
        EXPIRE clave periodo
        devolver true
    devolver false
```

**Exacto**: no hay borde de ventana, la garantía es literal ("nunca más de N en
cualquier intervalo de duración P"). **Caro**: `O(N)` de memoria por cliente. Con
1000 req/hora por cliente y 50.000 clientes son 50 millones de miembros en
sorted sets: cientos de MB de Redis y latencias de `ZREMRANGEBYSCORE` que se
notan.

Se usa cuando N es chico y la exactitud es cara de perder: "3 resets de
contraseña por hora", "5 intentos de 2FA", "1 factura por día". Para
`req/ip: 300/5min` es un desperdicio.

### 3.3 Sliding window counter (el de Cloudflare)

El compromiso: dos contadores de ventana fija (la actual y la anterior) e
**interpolación lineal**.

```text
estimado = anterior * ((periodo - transcurrido_en_actual) / periodo) + actual
permitir si estimado <= limite
```

Numérico, con límite 100/min, a las 12:01:15 (llevás 15 s de la ventana actual,
así que a la anterior le queda un peso de 45/60 = 0,75):

| `anterior` | `actual` | estimado | decisión |
|---|---|---|---|
| 80 | 30 | 80·0,75 + 30 = **90** | permitir |
| 100 | 30 | 100·0,75 + 30 = **105** | rechazar |
| 100 | 0 | **75** | permitir (razonable: ya pasaron 15 s) |

Memoria: dos enteros por cliente (`O(1)`). Error medido por Cloudflare en
producción: <0,003% de requests mal clasificadas. Asume que el tráfico dentro de
la ventana anterior fue **uniforme**, que es falso para ráfagas, pero el error
es acotado y siempre conservador si la ráfaga fue al principio.

Es el mejor default cuando querés "un fixed window sin el borde" y no te importa
la ráfaga. No hay implementación de esto en el repo; si tuvieras que agregarla,
va en Lua igual que el token bucket de abajo.

### 3.4 Token bucket (Stripe, AWS, GitHub)

Un balde de capacidad `C` que se rellena a `R` tokens por segundo. Cada request
consume tokens; si no alcanzan, se rechaza. **Permite ráfagas hasta `C` y
después te fuerza a la tasa `R`.** Eso es exactamente lo que querés para un
cliente legítimo: el que arranca su batch nocturno puede meter 100 requests de
golpe y después bajar a 10/s, sin que lo trates como un atacante.

El truco de implementación: no hace falta un timer que rellene. Guardás
`(tokens, ultimo_timestamp)` y **calculás el relleno cuando llega el request**.

```text
funcion permitir(cliente, R, C, costo):
    (tokens, ts) = LEER(cliente)  o  (C, ahora) si no existe
    tokens = min(C, tokens + (ahora - ts) * R)
    si tokens >= costo:
        tokens -= costo;  GUARDAR(cliente, tokens, ahora);  devolver permitido
    sino:
        GUARDAR(cliente, tokens, ahora)
        devolver rechazado, retry_after = ceil((costo - tokens) / R)
```

Eso son 3 operaciones sobre Redis (leer, calcular, escribir) que **tienen que ser
atómicas**. Con `GET` + `SET` desde Ruby, dos procesos leen el mismo estado y
los dos gastan el mismo token. La solución es Lua: Redis ejecuta el script
entero como una unidad, single-threaded, sin nadie en el medio.

```lua
-- token_bucket.lua — atómico. KEYS[1]=bucket  ARGV=rate, capacity, now, cost
local key      = KEYS[1]
local rate     = tonumber(ARGV[1])   -- tokens por segundo
local capacity = tonumber(ARGV[2])   -- tamaño de la ráfaga permitida
local now      = tonumber(ARGV[3])   -- epoch float, lo manda el cliente
local cost     = tonumber(ARGV[4])   -- cuánto cuesta ESTE endpoint

local bucket = redis.call("HMGET", key, "tokens", "ts")
local tokens = tonumber(bucket[1])
local ts     = tonumber(bucket[2])

if tokens == nil then          -- balde nuevo: arranca lleno
  tokens = capacity
  ts     = now
end

local delta = math.max(0, now - ts)
tokens = math.min(capacity, tokens + delta * rate)

local allowed = 0
if tokens >= cost then
  tokens  = tokens - cost
  allowed = 1
end

redis.call("HSET", key, "tokens", tokens, "ts", now)
-- TTL = lo que tarda un balde vacío en llenarse. Ni un segundo más:
-- si no expiran, las claves de clientes que se fueron te llenan Redis.
redis.call("EXPIRE", key, math.ceil(capacity / rate) + 1)

local retry_after = 0
if allowed == 0 then
  retry_after = math.ceil((cost - tokens) / rate)
end

return { allowed, math.floor(tokens), retry_after }
```

Y del lado Ruby, con la gema `redis` que ya está en el `Gemfile.lock` (5.4.1):

(El script iría en un archivo propio, por ejemplo `lib/token_bucket.lua`; no
existe en este repo, es el código que escribirías si reemplazaras la ventana
fija por token bucket.)

```ruby
class TokenBucket
  SCRIPT = File.read(Rails.root.join("lib/token_bucket.lua"))

  def initialize(redis) = (@redis = redis; @sha = nil)

  def allow?(key, rate:, capacity:, cost: 1)
    @sha ||= @redis.script(:load, SCRIPT)
    allowed, tokens, retry_after =
      @redis.evalsha(@sha, keys: [key], argv: [rate, capacity, Time.now.to_f, cost])
    [allowed == 1, tokens, retry_after]
  rescue Redis::CommandError => e
    # NOSCRIPT: Redis se reinició y perdió el script cache. Recargá y reintentá.
    raise unless e.message.include?("NOSCRIPT")
    @sha = nil
    retry
  end
end
```

Corrido de verdad contra el Redis de esta máquina (`rate=2 tok/s`,
`capacity=10`, `cost=1`):

```text
  req  1  allowed=1  tokens_restantes= 9  retry_after=0s
  req  2  allowed=1  tokens_restantes= 8  retry_after=0s
  ...
  req 10  allowed=1  tokens_restantes= 0  retry_after=0s
  req 11  allowed=0  tokens_restantes= 0  retry_after=1s   ← ráfaga agotada
  req 12  allowed=0  tokens_restantes= 0  retry_after=1s

-- 3 segundos después (se rellenaron 2*3 = 6 tokens) --
  req  1  allowed=1  tokens_restantes= 5
  req  5  allowed=1  tokens_restantes= 1

Hash en Redis: {"tokens"=>"1.0066084861755371", "ts"=>"1788121255.3944094"}  TTL=6
```

Cuatro cosas que se ven ahí y hay que saber explicar:

- **El estado son floats, no enteros.** En Redis quedó `tokens=1.0066…`: el
  relleno es `(ahora - ts) * rate` y `ahora` tiene decimales. El
  `math.floor(tokens)` del `return` es sólo para la respuesta; el balde guarda la
  fracción, que es justamente lo que hace que el relleno sea continuo y no a
  saltos de un token.
- **La ráfaga inicial es `capacity`, no `rate`.** El balde arranca lleno. Si eso
  te molesta (un cliente nuevo no debería poder mandar 10 de una), arrancalo en
  0 o en `capacity/2`. Es una decisión de producto.
- **`now` lo manda el cliente Ruby**, no `redis.call("TIME")`. Es a propósito:
  usar `TIME` adentro del script lo vuelve no determinista y rompe la
  replicación por comandos en Redis viejo. En Redis 7 con replicación por
  efectos ya no es un problema, pero el reloj del app server puede driftear
  respecto de otros app servers: si te importa, usá `TIME` y asumí Redis ≥ 5.
- **`cost` es el parámetro que separa un rate limiter de juguete de uno
  pensado.** `GET /api/v1/products` cuesta 1; `GET /api/v1/reports/valuation`
  cuesta 25. Es el modelo de Stripe y de la API GraphQL de GitHub. Con ventana
  fija no podés hacer esto sin declarar un throttle por endpoint.

### 3.5 Leaky bucket

Un balde con un agujero: las requests entran a una **cola** y salen a tasa
constante `R`. Si la cola está llena, se descarta.

```text
funcion permitir(cliente, R, C):
    fuga = (ahora - ultimo) * R
    nivel = max(0, nivel - fuga)
    si nivel + 1 <= C:
        nivel += 1; ultimo = ahora; devolver true
    devolver false
```

Matemáticamente es el dual del token bucket ("leaky bucket as a meter" ≡ token
bucket). La diferencia práctica está en la variante **"as a queue"**: ahí no
rechazás, *encolás y servís a tasa fija*, lo que da una salida perfectamente
suave. Eso es lo que querés cuando el que está aguas abajo tiene su propia cuota
(un proveedor de SMS que te acepta 10/s) — pero introduce latencia y una cola que
puede crecer. En HTTP casi nunca lo querés (§1.1). En un job de Sidekiq que
llama a una API externa, sí.

### 3.6 La tabla que te van a pedir

| Algoritmo | Precisión | Memoria/cliente | Ráfagas | Ops Redis | Dónde se usa |
|---|---|---|---|---|---|
| **Fixed window** | ✗ hasta 2× en el borde | 1 entero | permite 2× accidental | 1-2 (`INCR`+`EXPIRE`) | `Rack::Attack`, `rate_limit` de Rails |
| **Sliding window log** | ✓ exacto | O(N) timestamps | ✗ ninguna | 3-4 (`ZREM`+`ZCARD`+`ZADD`) | límites chicos y críticos (2FA, resets) |
| **Sliding window counter** | ~ error <0,003% | 2 enteros | ✗ ninguna | 2-3 (script) | Cloudflare |
| **Token bucket** | ✓ | 2 valores (hash) | ✓ **controladas**, hasta `capacity` | 1 (script Lua) | Stripe, AWS, GitHub |
| **Leaky bucket (queue)** | ✓ | cola + 2 valores | ✗ las suaviza | 1 (script) | shaping hacia un proveedor externo |

Criterio de elección en una frase: **si el cliente es humano o un browser,
ventana (fija o deslizante) alcanza; si el cliente es una integración que hace
batches, token bucket, porque si no le rompés el caso de uso legítimo.**

---

## 4. El discriminador: la decisión que más se equivoca

El algoritmo se elige una vez. El discriminador —**por quién contás**— se elige
por endpoint, y es donde están los bugs.

### 4.1 Por IP: útil, y con dos agujeros grandes

**NAT / CGNAT.** Una universidad, una empresa o un ISP móvil salen a internet
por un puñado de IPs. Un límite de 300/5min por IP significa que 4.000 empleados
de un cliente comparten 300 requests. Los vas a bloquear a todos por culpa de
uno. Peor: no lo vas a notar en tus métricas globales, sólo en un ticket de
soporte tres semanas después.

**IPv6.** Un ISP le da a un cliente residencial un **/64 como mínimo** (muchas
veces un /56 o un /48). Eso es:

```ruby
2**64  # => 18446744073709551616 direcciones para un solo abonado
```

Limitar por dirección IPv6 completa es **exactamente igual a no limitar**: el
atacante rota de dirección sin costo. Tenés que agregar al prefijo:

```ruby
require "ipaddr"

# Agrupá IPv6 al /64 (o /56 si querés ser más agresivo). IPv4 se deja como está.
def rate_limit_bucket(ip)
  addr = IPAddr.new(ip)
  addr.ipv6? ? "#{addr.mask(64)}/64" : ip
rescue IPAddr::InvalidAddressError
  ip  # entrada basura: que caiga en su propio balde, no que explote
end

rate_limit_bucket("2001:db8:abcd:1234::1")                    # => "2001:db8:abcd:1234::/64"
rate_limit_bucket("2001:db8:abcd:1234:ffff:ffff:ffff:ffff")   # => "2001:db8:abcd:1234::/64"
rate_limit_bucket("2001:db8:abcd:9999::1")                    # => "2001:db8:abcd:9999::/64"
rate_limit_bucket("203.0.113.7")                              # => "203.0.113.7"
```

(Corrido y verificado; `IPAddr#mask` está en la stdlib, no hace falta gema.)

Este repo **no** hace esa agregación: `config/initializers/rack_attack.rb:158`
usa `&:remote_ip` crudo. Con tráfico IPv4 no se nota; el día que actives IPv6 en
el balanceador, el límite por IP deja de existir.

### 4.2 Por usuario, por token, por tenant

- **Por usuario** (`current_user.id`): correcto para la UI. Requiere sesión, o
  sea capa 2.
- **Por token** (`current_api_token.id`): lo correcto para una API. La identidad
  de una integración es su **credencial**, no su IP — porque la IP la comparten
  todos los contenedores del cliente y cambia con cada deploy que hacen.
- **Por tenant**: cuando vendés por empresa, el límite es de la empresa y se
  reparte entre sus tokens. Si limitás por token, el cliente evade la cuota
  emitiendo 50 tokens.
- **Por endpoint**: los límites por costo. `api/writes` en
  `config/initializers/rack_attack.rb:208` hace justamente eso (120/min para
  todo lo que no sea `GET`/`HEAD`, contra 1000/hora para el total).

En capa 1 no tenés el `id` del token, así que el repo usa el **hash** del token:

```ruby
# config/initializers/rack_attack.rb:193-203
throttle("api/token", limit: 1_000, period: 1.hour) do |req|
  next unless req.path.start_with?("/api/")

  if (auth = req.get_header("HTTP_AUTHORIZATION")) && auth.start_with?("Bearer ")
    Digest::SHA256.hexdigest(auth.delete_prefix("Bearer "))
  else
    "anon-#{req.remote_ip}"
  end
end
```

**Hashear no es opcional.** El discriminador termina en la clave de Redis, en los
logs de la app, en el dashboard de tu APM y en el `MONITOR` de cualquiera que
tenga acceso a Redis. Un token en texto plano ahí es una filtración de
credenciales.

### 4.3 Combinar discriminadores

Cuando combinás, la clave es la concatenación, y ahí hay una trampa clásica:

```ruby
# MAL: "ab" + "c" y "a" + "bc" generan la misma clave
key = "#{tenant}#{user}"

# BIEN: separador que no puede aparecer en ninguna parte
key = "#{tenant}:#{user}"
```

Y `Rack::Attack` normaliza *todo* discriminador antes de usarlo:

```ruby
# rack-attack-6.8.0/lib/rack/attack.rb:92-94
@throttle_discriminator_normalizer = lambda do |discriminator|
  discriminator.to_s.strip.downcase
end
```

O sea: el `.downcase.strip` que hace el bloque de `logins/email`
(`config/initializers/rack_attack.rb:178`) es **redundante** — pero dejarlo
explícito está bien, porque el normalizador es global y alguien lo puede
desactivar.

### 4.4 El caso del login: por IP **y** por email

Este es el ejemplo canónico y te lo van a preguntar. Son **dos amenazas
distintas** y ningún límite solo cubre las dos:

| Ataque | Forma | ¿Lo ve el límite por IP? | ¿Lo ve el límite por email? |
|---|---|---|---|
| **Fuerza bruta clásica** | 1 IP, 1 cuenta, 10.000 claves | ✓ sí | ✓ sí |
| **Credential stuffing** | 1 IP, 10.000 cuentas, 1 clave c/u | ✓ sí | ✗ no (1 intento por email) |
| **Ataque distribuido a 1 cuenta** | 5.000 IPs, 1 cuenta, 2 claves c/u | ✗ no (2 por IP) | ✓ sí |

El repo declara los dos (`config/initializers/rack_attack.rb:170-180`):

```ruby
throttle("logins/ip", limit: 5, period: 20.seconds) do |req|
  req.remote_ip if req.path == "/session" && req.post?
end

throttle("logins/email", limit: 6, period: 15.minutes) do |req|
  if req.path == "/session" && req.post?
    req.params.dig("session", "email_address")&.to_s&.downcase&.strip&.presence
  end
end
```

**Y el segundo no funciona.** Este es el bug real más interesante del repo, y es
del tipo que no falla nunca: falla en silencio, para siempre.

El formulario de login (`app/views/sessions/new.html.erb:7`) es
`form_with url: session_path` — **sin modelo**, o sea **sin scope**. Los campos
se serializan planos: `email_address=...&password=...`. No hay ningún
`params["session"]`. El `dig("session", "email_address")` devuelve `nil`
siempre, y un discriminador `nil` hace que `Rack::Attack::Throttle#matched_by?`
retorne `false` sin contar nada:

```ruby
# rack-attack-6.8.0/lib/rack/attack/throttle.rb:26-27
discriminator = discriminator_for(request)
return false unless discriminator
```

Comprobado con `curl`, mirando qué claves aparecen en Redis:

```bash
# Con params ANIDADOS (lo que el throttle espera):
$ curl -X POST localhost:3001/session --data-urlencode "session[email_address]=Ana@Empresa.com " -d "session[password]=x"
$ redis-cli --scan --pattern '*'
rack-attack:rack::attack:1986792:logins/email:ana@empresa.com   ← existe
rack-attack:rack::attack:5960376:req/ip:127.0.0.1
rack-attack:rack::attack:89405649:logins/ip:127.0.0.1

# Con params PLANOS (lo que manda el formulario real):
$ curl -X POST localhost:3001/session -d "email_address=Ana@Empresa.com&password=x"
$ redis-cli --scan --pattern '*'
rack-attack:rack::attack:5960376:req/ip:127.0.0.1               ← el de email NO aparece
rack-attack:rack::attack:89405649:logins/ip:127.0.0.1
```

(De paso se ve la normalización funcionando: `"Ana@Empresa.com "` → clave
`ana@empresa.com`.)

El arreglo es de una línea —`req.params["email_address"]`— pero la lección es
más grande: **un discriminador `nil` desactiva el throttle sin un solo warning**.
Lo mismo pasa con `password-resets/email`
(`config/initializers/rack_attack.rb:184-186`), que lee
`params.dig("password", "email_address")` mientras
`app/views/passwords/new.html.erb:8-10` también usa `form_with url:` sin modelo y
manda `email_address` plano.

Cómo se detecta: **nunca declares un throttle nuevo sin verificar que la clave
aparece en el store.** Un `redis-cli --scan` después de un request de prueba es
el smoke test entero.

---

## 5. El store: compartido, atómico y con una política de falla

### 5.1 MemoryStore multiplica tu límite por la cantidad de workers

Con `WEB_CONCURRENCY=4`, cuatro procesos de Puma, cuatro `MemoryStore`
independientes. Un límite de 100 se vuelve **hasta 400** — y encima
*inconsistente*, porque el reparto de conexiones entre workers no es uniforme y
cambia con cada deploy. Peor todavía: no es determinista, así que el bug se
manifiesta como "a veces me bloquea y a veces no" y nadie lo puede reproducir.

El repo lo maneja explícitamente y **avisa fuerte**
(`config/initializers/rack_attack.rb:70-91`):

```ruby
self.cache.store =
  if ENV["REDIS_URL"].present?
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"], namespace: "rack-attack", ...)
  else
    Rails.logger.warn(
      "[RackAttack] Sin REDIS_URL: usando MemoryStore. " \
      "Los contadores NO se comparten entre procesos; los límites reales " \
      "quedan multiplicados por la cantidad de workers. NO USAR EN PRODUCCIÓN."
    )
    ActiveSupport::Cache::MemoryStore.new
  end
```

> **Donde se rompe la analogía con Java.** En una app Spring típica tenés **un
> proceso JVM con N threads**, y un `ConcurrentHashMap` o un Bucket4j local
> alcanza para todo el nodo. En Ruby cada worker de Puma es un **proceso
> separado** (fork, sin memoria compartida): lo que en Java sería estado
> compartido por default, acá es estado replicado por default. Es la fuente #1
> de errores de un javero en Rails: cualquier variable de clase, cualquier cache
> en memoria, cualquier contador, existe una vez **por worker**.

### 5.2 `INCR` + `EXPIRE`: la race, y cómo se resuelve

La versión ingenua tiene un bug clásico:

```ruby
count = redis.incr(key)
redis.expire(key, period) if count == 1   # ← si el proceso muere acá...
```

Si el proceso muere (deploy, OOM kill, timeout) entre `INCR` y `EXPIRE`, la
clave queda **sin TTL, para siempre**. Ese cliente queda bloqueado
permanentemente y nadie sabe por qué. Ni siquiera hace falta que muera: si dos
procesos hacen `INCR` a la vez y los dos ven `count != 1`, ninguno pone el TTL.

Rails lo resuelve con `EXPIRE ... NX` en pipeline. Este es el código que corre de
verdad cuando llamás `RedisCacheStore#increment`:

```ruby
# activesupport-8.1.3.1/lib/active_support/cache/redis_cache_store.rb:456-481
# (abreviado: se omite la línea que resuelve el nodo en Redis::Distributed)
def change_counter(key, amount, options)
  redis.then do |c|
    expires_in = options[:expires_in]
    if expires_in
      if supports_expire_nx?                      # Redis >= 7.0
        count, _ = c.pipelined do |pipeline|
          pipeline.incrby(key, amount)
          pipeline.call(:expire, key, expires_in.to_i, "NX")
        end
      else                                        # fallback para Redis viejo
        count, ttl = c.pipelined do |pipeline|
          pipeline.incrby(key, amount)
          pipeline.ttl(key)
        end
        c.expire(key, expires_in.to_i) if ttl < 0
      end
    else
      count = c.incrby(key, amount)
    end
    count
  end
end
```

`EXPIRE key ttl NX` = "poné el TTL sólo si no tiene uno". Es idempotente, así que
no importa cuántos procesos lo manden ni en qué orden. El Redis de esta máquina
es 7.0.15, así que se toma la rama buena.

**Pero fijate que sigue siendo un pipeline, no una transacción.** Un pipeline
manda los dos comandos juntos para ahorrar round-trips; no garantiza atomicidad
ni aislamiento. Si el proceso muere después del `INCRBY` y antes de que Redis
procese el `EXPIRE`, la clave queda sin TTL igual. La ventana es de microsegundos
y `EXPIRE NX` la hace autocorregible en el siguiente request... salvo que ese
request caiga en otra ventana (otra clave). En la práctica no muerde; si te
importa de verdad, va en Lua:

```lua
-- fixed_window.lua — INCR + EXPIRE realmente atómicos
local n = redis.call("INCR", KEYS[1])
if n == 1 then redis.call("EXPIRE", KEYS[1], ARGV[1]) end
return n
```

`Rack::Attack` tiene su propia red de contención para stores que devuelven `nil`
al incrementar una clave inexistente:

```ruby
# rack-attack-6.8.0/lib/rack/attack/cache.rb:76-89
# (abreviado: se omiten los enforce_store_*! que validan que el store exista)
def do_count(key, expires_in)
  result = store.increment(key, 1, expires_in: expires_in)
  if result.nil?
    store.write(key, 1, expires_in: expires_in)   # ← no atómico: puede perder cuentas
  end
  result || 1
end
```

Ese `write` bajo concurrencia pisa cuentas. Con Redis no se ejecuta nunca; con
un store casero, sí.

### 5.3 Por qué Solid Cache (Postgres) no va acá

Este repo usa Solid Cache como `Rails.cache` en desarrollo y producción
(`config/environments/development.rb:32`, `config/environments/production.rb:50`),
y está bien para cachear reportes. Para contadores de rate limiting **no**:

- Es **una escritura por request** contra tu base principal (o su base de
  cache), o sea WAL, vacuum y contención de fila sobre las claves calientes.
- Tu rate limiter existe para protegerte de un pico de tráfico. Ponerlo sobre la
  base que ese pico está por saturar es exactamente el acoplamiento que querías
  evitar.
- El `increment` de Solid Cache funciona, pero **no es un `INCR` atómico de una
  sola operación**: `SolidCache::Store#increment` llama a
  `SolidCache::Entry.lock_and_write`, que abre una transacción, hace un
  `SELECT ... FOR UPDATE` sobre la fila de la clave y recién después escribe
  (`solid_cache-1.0.10/app/models/solid_cache/entry.rb:70-79`). Una IP atacante
  genera una fila caliente y todos los requests de esa IP se serializan sobre
  ese lock.

Por eso `Api::V1::BaseController::RATE_LIMIT_STORE`
(`app/controllers/api/v1/base_controller.rb:46-57`) prefiere Redis y sólo cae a
`Rails.cache` como último recurso.

**Y acá hay una trampa de configuración que conviene mirar de frente.** Ese Redis
es *opcional*: la rama buena depende de `ENV["REDIS_URL"]`, y en este repo
`REDIS_URL` viene comentada en `.env.example:44`. Si no la exportás, esto es lo
que te queda (verificado con `bin/rails runner` sin `REDIS_URL`):

```text
Rack::Attack.cache.store                      => ActiveSupport::Cache::MemoryStore
Api::V1::BaseController::RATE_LIMIT_STORE     => SolidCache::Store
SessionsController.cache_store                => SolidCache::Store
```

O sea: la capa 1 queda con contadores **por proceso** (§5.1) y la capa 2 queda
contando sobre **Postgres**, que es justamente lo que este apartado desaconseja.
Peor todavía: `SessionsController` y `PasswordsController` declaran su
`rate_limit` **sin `store:`** (`app/controllers/sessions_controller.rb:5`,
`app/controllers/passwords_controller.rb:4`), así que usan
`config.action_controller.cache_store` — Solid Cache — pase lo que pase con
`REDIS_URL`. El límite de login de la UI cuenta contra tu base de datos.

No es fatal en desarrollo. En producción es una línea de `.env` que, si falta,
te deja el rate limiting funcionando "más o menos" sin un solo error. Es el
mismo patrón que el NullStore de §5.4: **el control de seguridad se degrada en
silencio.**

### 5.4 El NullStore: el fallo silencioso de seguridad

```ruby
# app/controllers/api/v1/base_controller.rb:40-45 (comentario del repo)
# ⚠️ UN RATE LIMITER SOBRE UN NULL STORE NO LIMITA NADA, Y NO AVISA.
```

Es literal. Mirá la implementación de Rails:

```ruby
# actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:76-77
count = store.increment(cache_key, 1, expires_in: within)
if count && count > to
```

`NullStore#increment` devuelve `nil`. `nil && ...` es `nil`, falsy, no entra
nunca. **El límite queda desactivado y no hay un solo log.** Y esto no es
rebuscado: `config.cache_store = :null_store` es una línea que alguien pone en
`development.rb` para debuggear un problema de cache, y se olvida de sacar.

Por eso el repo elige el store explícitamente y loguea cuando detecta un
NullStore. Regla general: **cualquier control de seguridad que pueda quedar
desactivado sin ruido, tiene que verificarse en el arranque.**

### 5.5 Fail-open vs fail-closed

Redis se cae. ¿Qué hacés?

| | **Fail open** (dejar pasar) | **Fail closed** (rechazar todo) |
|---|---|---|
| Riesgo | tráfico sin límite mientras dure la caída | **caída total del servicio** por una caída del cache |
| Cuándo | el límite protege de *abuso* y hay otras capas (CDN, LB) | el límite protege un recurso que **no puede** sobrecargarse (un proveedor externo que te cobra, una cuota legal) |

Este repo elige **fail open**, y en dos lugares distintos:

```ruby
# config/initializers/rack_attack.rb:79-83 — explícito
error_handler: ->(method:, returning:, exception:) {
  Rails.logger.error("[RackAttack] Redis caído (#{method}): #{exception.class}")
},
connect_timeout: 1, read_timeout: 0.2, write_timeout: 0.2
```

```ruby
# activesupport-8.1.3.1/lib/active_support/cache/redis_cache_store.rb:490-495 — implícito
def failsafe(method, returning: nil)
  yield
rescue ::Redis::BaseError, ConnectionPool::Error, ConnectionPool::TimeoutError => error
  @error_handler&.call(method: method, exception: error, returning: returning)
  returning          # ← nil
end
```

El `returning` es `nil`, `nil && nil > to` es falsy, **la request pasa**. O sea:
el `rate_limit` de Rails es fail-open por construcción, lo declares o no. Es una
decisión razonable de default pero **tenés que saber que la tomaste**.

Los timeouts de 200 ms son la otra mitad de la decisión, y son igual de
importantes: sin ellos, un Redis lento (no caído — *lento*) le agrega su latencia
a **cada request**, y tu rate limiter se convierte en tu cuello de botella. 200 ms
es generoso para un `INCR` en la misma red; si se pasa, algo está mal y preferís
seguir sin contar.

---

## 6. `X-Forwarded-For`: por qué nunca se confía sin más

### 6.1 Cómo decide Rails cuál es la IP del cliente

`ActionDispatch::RemoteIp` toma la cadena de `X-Forwarded-For` (más `Client-Ip`
y `REMOTE_ADDR`), le saca los proxies de confianza y se queda con el que sobra
más a la derecha:

```ruby
# actionpack-8.1.3.1/lib/action_dispatch/middleware/remote_ip.rb:129-170
def calculate_ip
  remote_addr   = sanitize_ips(ips_from(@req.remote_addr)).last
  client_ips    = sanitize_ips(ips_from(@req.client_ip)).reverse!
  forwarded_ips = sanitize_ips(@req.forwarded_for || []).reverse!
  ...
  ips = forwarded_ips + client_ips
  ips.compact!
  filter_proxies(ips + [remote_addr]).first || ips.last || remote_addr
end
```

La lista de confianza por defecto (`RemoteIp::TRUSTED_PROXIES`,
`remote_ip.rb:40-49`) son ocho CIDR, no ocho direcciones sueltas — el prefijo es
la mitad del dato:

```text
127.0.0.0/8   ::1        fc00::/7        10.0.0.0/8
172.16.0.0/12 192.168.0.0/16  169.254.0.0/16  fe80::/10
```

O sea: loopback (v4 y v6), rangos privados RFC 1918, ULA IPv6 y link-local. **No
hay una sola IP pública ahí.** Y en este repo,
`config.action_dispatch.trusted_proxies` está en **`nil`** (verificado con
`bin/rails runner`), así que se usan sólo esos defaults.

Cuándo importa eso y cuándo no — corrido contra `RemoteIp::GetIp` de este repo:

```text
REMOTE_ADDR      X-Forwarded-For                    remote_ip resultante
203.0.113.9      "9.9.9.9, 198.51.100.7"            198.51.100.7   ✓ el cliente real
203.0.113.9      "198.51.100.7"                     198.51.100.7   ✓ el cliente real
198.51.100.7     "1.2.3.4"                          1.2.3.4        ✗ spoofeado
203.0.113.9      "198.51.100.7, 203.0.113.50"       203.0.113.50   ✗ es el proxy
```

Las dos primeras filas son un ALB con IP pública que **agrega** (no reemplaza) el
peer real al final de la cadena: como el algoritmo se queda con el que sobra más
a la derecha, devuelve al cliente correcto **aunque el balanceador no esté en
`trusted_proxies`**. Incluso si el cliente inventa su propio `X-Forwarded-For`,
el valor que agrega el ALB queda a la derecha y gana.

Donde muerde de verdad son las otras dos:

- **Fila 3**: alguien llega **directo a Puma** y manda el header. No hay nadie
  que agregue el peer real, así que el único valor de la cadena es el inventado.
  Esto no lo arregla `trusted_proxies`: lo arregla el firewall.
- **Fila 4**: **dos o más saltos con IP pública**. Si el proxy intermedio no está
  en `trusted_proxies`, el que "sobra más a la derecha" es *ese proxy*, y todo el
  tráfico que pasa por él comparte un contador.

### 6.2 El experimento del spoofing

`X-Forwarded-For` **lo manda el cliente**. Es un header HTTP común y corriente:
cualquiera lo puede escribir. Desde `127.0.0.1` (que está en la lista de
confianza) contra el repo corriendo:

```bash
$ for ip in 1.2.3.4 5.6.7.8 9.10.11.12; do
    for i in $(seq 1 7); do
      curl -s -o /dev/null -w "%{http_code} " -H "X-Forwarded-For: $ip" \
        -X POST localhost:3001/session -d "email_address=ana@empresa.com&password=x"
    done; echo "  <- XFF=$ip"
  done

$ redis-cli --scan --pattern '*logins*'
rack-attack:rack::attack:89405649:logins/ip:9.10.11.12   => 7
rack-attack:rack::attack:89405649:logins/ip:1.2.3.4      => 7
rack-attack:rack::attack:89405649:logins/ip:5.6.7.8      => 7
```

**Tres contadores independientes**, uno por IP inventada. Un atacante que pueda
llegar directo a tu app —o que atraviese un proxy que pasa `X-Forwarded-For` tal
cual, sin agregarle el peer real— tiene un balde nuevo de 5 intentos por cada
valor que se le ocurra. El rate limit por IP deja de existir.

La defensa NO es "no uses XFF". Son dos defensas distintas, arreglan cosas
distintas, y confundirlas es lo que hace que la gente configure
`trusted_proxies` creyendo que se protege de esto:

**1. Que nadie pueda hablar con Puma sin pasar por el proxy.** Ésta es la que
arregla el experimento de arriba, y es de red, no de Rails. Mientras el atacante
llegue directo, el único valor de la cadena `X-Forwarded-For` es el que él
escribió, y ninguna configuración de `trusted_proxies` lo cambia: él *es* el
primer salto. Security group / firewall que sólo acepte tráfico del balanceador.

**2. Que la lista de proxies de confianza coincida con tu topología.** Esto es lo
que arregla la fila 4 de la tabla de §6.1: los saltos intermedios con IP pública
tienen que estar en la lista, si no `remote_ip` te devuelve el proxy en vez del
cliente. Con **un solo** salto que agrega el peer real (el caso ALB → Rails) no
hace falta tocar nada; lo verificamos arriba.

Y acá va la trampa que casi nadie ve la primera vez: **asignar
`trusted_proxies` no agrega, REEMPLAZA.** Mirá el constructor del middleware
(`remote_ip.rb:67-74`):

```ruby
@proxies = if custom_proxies.blank?
  TRUSTED_PROXIES          # ← los ocho defaults
elsif custom_proxies.respond_to?(:any?)
  custom_proxies           # ← SÓLO lo tuyo. Los defaults desaparecen.
else
  raise(ArgumentError, ...)  # un valor suelto en vez de un enumerable
end
```

La propia documentación del método lo dice: *"passing an enumerable will
**replace** the default set of trusted proxies"*. Si escribís sólo el CIDR de tu
ALB, `127.0.0.1` deja de ser confiable — y entonces tus health checks locales, tu
`curl` desde la máquina y cualquier sidecar pasan a contar como clientes. Lo que
querés casi siempre es esto:

```ruby
# config/application.rb — lo que agregarías si tenés proxies encadenados
config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + [ IPAddr.new("198.51.100.0/24") ]
```

Y ojo con el `raise`: pasar **un solo** `IPAddr` en vez de un array levanta
`ArgumentError` al arrancar. Es de los pocos errores de esta área que sí son
ruidosos.

Regla dura: **cada CIDR que agregás es un agujero potencial.** Si confiás en
`0.0.0.0/0`, `remote_ip` pasa a ser literalmente lo que el cliente diga.

### 6.3 El bug del orden del middleware

El instinto es `insert_before 0`: cortar lo antes posible. Es la trampa que
documenta `config/application.rb:33-52`, y es un bug real y sutil.

`Rack::Attack::Request` hereda de `Rack::Request`, que **no tiene `remote_ip`**:
tiene `ip`, que es la IP del **peer TCP**. Detrás de un balanceador, el peer TCP
es el balanceador. Resultado: **todos tus usuarios comparten un contador** y el
primero que haga 300 requests deja afuera al planeta. En tus dashboards se ve
como "el sitio anda mal para todos" y el rate limiter ni figura como sospechoso.

Por eso el repo inserta **después** de `RemoteIp`:

```ruby
# config/application.rb:52
config.middleware.insert_after ActionDispatch::RemoteIp, Rack::Attack
```

y expone la IP resuelta con un monkey patch mínimo:

```ruby
# config/initializers/rack_attack.rb:45-51
class Rack::Attack
  class Request < ::Rack::Request
    def remote_ip
      @remote_ip ||= (env["action_dispatch.remote_ip"] || ip).to_s
    end
  end
end
```

`RemoteIp` deja en el `env` un objeto lazy; el `.to_s` es el que dispara
`calculate_ip`. El `|| ip` es el fallback para cuando el middleware no corrió
(tests que arman un `env` a mano).

Perdés muy poco insertando ahí: seguís antes del routing, de la sesión, de las
cookies y de los controllers. Ganás la única cosa sin la cual el rate limiter no
sirve: saber a quién estás contando.

---

## 7. `Rack::Attack` en detalle

### 7.1 Las cuatro primitivas y su orden de evaluación

```ruby
# rack-attack-6.8.0/lib/rack/attack.rb:111-130
if configuration.safelisted?(request)
  @app.call(env)                                   # 1. pasa, sin evaluar nada más
elsif configuration.blocklisted?(request)
  configuration.blocklisted_responder.call(request) # 2. 403
elsif configuration.throttled?(request)
  configuration.throttled_responder.call(request)   # 3. 429
else
  configuration.tracked?(request)                   # 4. sólo mide
  @app.call(env)
end
```

| Primitiva | Qué hace | Cuándo la usás |
|---|---|---|
| `safelist` | permite siempre, **corta la evaluación** | health checks, red interna, assets |
| `blocklist` | 403 siempre | IPs conocidas, escáneres, bots |
| `throttle` | cuenta y devuelve 429 al pasarse | el rate limiting propiamente dicho |
| `track` | **no bloquea**, sólo emite el evento | calibrar un límite antes de activarlo |

En el repo (`config/initializers/rack_attack.rb`):

```ruby
safelists  = ["permitir health checks", "permitir assets", "permitir red interna"]
blocklists = ["bloquear escaneo de vulnerabilidades"]
throttles  = ["req/ip", "logins/ip", "logins/email", "password-resets/email",
              "api/token", "api/writes"]
tracks     = ["api/heavy-reports"]
```

El safelist de health checks (`:99-101`) no es una optimización, es una
**precondición de disponibilidad**: si limitás `/up`, el balanceador ve fallar el
health check, saca la instancia de rotación, la carga se concentra en las que
quedan, y el rate limiter te tira el servicio abajo solo. Hay un test que lo
fija (`spec/requests/api/v1/rate_limiting_spec.rb:98-101`: 400 GET a `/up`,
todos 200).

### 7.2 Detalle fino: `throttled?` hace short-circuit

```ruby
# rack-attack-6.8.0/lib/rack/attack/configuration.rb:93-97
def throttled?(request)
  @throttles.any? { |_name, throttle| throttle.matched_by?(request) }
end
```

`any?` corta en el primer `true`. Consecuencia práctica: si `logins/ip` bloquea,
**`logins/email` no se evalúa y su contador no se incrementa**. El orden de
declaración define qué regla "gana" y qué contadores quedan incompletos. Si
alertás sobre `logins/email`, vas a ver menos eventos de los que hubo.

`tracked?` en cambio usa `each_value` (`configuration.rb:99-103`): entre tracks no
hay short-circuit, se evalúan **todos**. Pero ojo con el "siempre": mirá el
`else` del snippet de §7.1 — `tracked?` vive ahí, así que una request
safelisteada, bloqueada o throttleada **no cuenta en ningún track**. Si estás
calibrando un límite nuevo con `track` mientras otro throttle ya está cortando,
tus números de calibración están sesgados hacia abajo.

### 7.3 Fail2Ban y Allow2Ban

Los dos son bloqueos **adaptativos**: N eventos sospechosos dentro de `findtime`
⇒ baneado `bantime` para **todo el sitio**, no sólo para la ruta que disparó la
alarma. La diferencia entre ellos es sutil y se pregunta:

```ruby
# fail2ban.rb:37-44 — bloquea YA, en el request que llegó a maxretry
def fail!(discriminator, bantime, findtime, maxretry)
  count = cache.count("#{key_prefix}:count:#{discriminator}", findtime)
  ban!(discriminator, bantime) if count >= maxretry
  true                              # ← el request actual TAMBIÉN se bloquea
end

# allow2ban.rb:15-22 — deja pasar este, banea a partir del próximo
def fail!(discriminator, bantime, findtime, maxretry)
  count = cache.count("#{key_prefix}:count:#{discriminator}", findtime)
  ban!(discriminator, bantime) if count >= maxretry
  false                             # ← "we may not block them this time"
end
```

- **`Fail2Ban`**: el bloque devuelve `true` para requests **inequívocamente
  maliciosas**. Cada `true` cuenta y el request se bloquea siempre.
- **`Allow2Ban`**: el bloque devuelve `true` para requests **normales pero
  contables**. No se bloquean; cuando se pasan de `maxretry`, el cliente queda
  baneado a partir de ahí. Es "rate limiting con castigo largo": ideal para
  scraping, donde la request individual es legítima y lo sospechoso es el patrón.

El repo usa `Fail2Ban` contra escáneres (`config/initializers/rack_attack.rb:126-133`):
3 sondas de `/wp-admin`, `/.env`, `/.git` o `..` en 10 minutos ⇒ 1 hora de ban
total. Verificado por test: `GET /.env` ⇒ 403
(`spec/requests/api/v1/rate_limiting_spec.rb:93-96`).

Ojo con dos cosas:

- Un ban de Fail2Ban es **global para esa IP**. Con una IP de CGNAT compartida
  por un edificio, baneás a todos. Por eso el filtro tiene que ser de patrones
  que un usuario legítimo **jamás** dispara. `/.env` califica; "3 errores 404"
  no.
- `Fail2Ban.filter` usa el `cache` global de `Rack::Attack`, así que hereda su
  política de fallo: si Redis se cae, nadie está baneado.

### 7.4 Los responders

`throttled_responder` recibe el `Rack::Attack::Request` y devuelve una tripleta
Rack. Los datos del match están en `env["rack.attack.match_data"]`, que arma
`Throttle#annotate_request_with_matched_data`:

```ruby
{ discriminator:, count:, period:, limit:, epoch_time: }
```

El del repo (`config/initializers/rack_attack.rb:230-254`) calcula el
`Retry-After` a partir de la alineación de la ventana fija:

```ruby
retry_after = period.positive? ? (period - (now % period)) : 60
```

Que es exactamente lo correcto para ventana fija: **el tiempo que falta para que
la ventana rote**, no el período completo. Verificado en vivo:

```bash
$ curl -D - -X POST localhost:3001/session -d "email_address=a@b.c&password=x"
HTTP/1.1 429 Too Many Requests
content-type: application/json; charset=utf-8
retry-after: 17
ratelimit-limit: 5
ratelimit-remaining: 0
ratelimit-reset: 17

{"error":{"code":"rate_limit_exceeded",
          "message":"Demasiadas solicitudes. Reintentá en 17 segundos.",
          "details":{"retry_after":17,"limit":5,"window_seconds":20}}}
```

Fijate que el body es **JSON**, no una página de error HTML. Es deliberado y
tiene test (`spec/requests/api/v1/rate_limiting_spec.rb:86-91`): el cliente de
una API tiene que poder parsear el error con el mismo código con el que parsea
todo lo demás. Un 429 que devuelve HTML rompe el parser del cliente y le tapa la
causa real.

### 7.5 Observabilidad con ActiveSupport::Notifications

`Rack::Attack` publica en el bus de eventos de Rails (el mismo de
`sql.active_record` y `process_action.action_controller`):

```ruby
# rack-attack-6.8.0/lib/rack/attack.rb:39-47
def instrument(request)
  if notifier
    event_type = request.env["rack.attack.match_type"]
    notifier.instrument("#{event_type}.rack_attack", request: request)
    notifier.instrument("rack.attack", request: request)  # deprecado
  end
end
```

Los nombres reales son `throttle.rack_attack`, `blocklist.rack_attack`,
`track.rack_attack`, `safelist.rack_attack`. El repo se suscribe con un regex y
filtra por tipo (`config/initializers/rack_attack.rb:268-284`):

```ruby
ActiveSupport::Notifications.subscribe(/rack_attack/) do |name, _start, _finish, _id, payload|
  req = payload[:request]
  next if req.nil?
  match_type = req.env["rack.attack.match_type"]
  next unless %i[throttle blocklist].include?(match_type)

  Rails.logger.warn(
    event: "rack_attack.#{match_type}",
    rule: req.env["rack.attack.matched"],
    ip: req.remote_ip, path: req.path, method: req.request_method,
    user_agent: req.user_agent&.truncate(120),
    discriminator: req.env["rack.attack.match_discriminator"].to_s.truncate(64)
  )
end
```

El `truncate(64)` del discriminador no es cosmético: evita que un discriminador
enorme (un header de 8 KB) te llene el log.

Sin esto el rate limiting es una caja negra, y el día que un cliente escriba "me
están cortando" no tenés con qué responder. `rule` + `discriminator` es
exactamente lo que necesitás para contestar en 30 segundos.

> **Analogía Java.** `ActiveSupport::Notifications` es Micrometer +
> `ApplicationEventPublisher` en un solo bus. La diferencia: es **síncrono y en
> el mismo thread** por default. Si tu suscriptor hace I/O lento, se lo estás
> agregando a la request. Logueá, no llames a una API desde acá.

---

## 8. `rate_limit` de Rails 8: 25 líneas y una trampa

### 8.1 El código completo

Es todo lo que hay. Vale la pena leerlo entero porque explica los tres
comportamientos que sorprenden:

```ruby
# actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:66-90
def rate_limit(to:, within:, by: -> { request.remote_ip }, with: -> { raise TooManyRequests },
               store: cache_store, name: nil, scope: nil, **options)
  before_action -> { rate_limiting(to:, within:, by:, with:, store:, name:,
                                   scope: scope || controller_path) }, **options
end

def rate_limiting(to:, within:, by:, with:, store:, name:, scope:)
  by = by.is_a?(Symbol) ? send(by) : instance_exec(&by)

  cache_key = ["rate-limit", scope, name, by].compact.join(":")
  count = store.increment(cache_key, 1, expires_in: within)
  if count && count > to
    ActiveSupport::Notifications.instrument("rate_limit.action_controller",
        request:, count:, to:, within:, by:, name:, scope:, cache_key:) do
      with.is_a?(Symbol) ? send(with) : instance_exec(&with)
    end
  end
end
```

Lo que se deduce leyendo:

- **Es un `before_action`.** Hereda `only:`/`except:`, el orden de declaración y
  la semántica de halting: si `with:` hace `render` o `redirect_to`, la cadena se
  corta.
- **`by:` y `with:` se `instance_exec`an en el controller.** Por eso
  `-> { current_api_token&.id }` funciona: es el `self` de la instancia del
  controller, no el de la clase.
- **Ventana fija sin alineación al reloj**: `expires_in: within` sobre un
  `increment`. La ventana arranca con el primer request del cliente y dura
  `within`. Es distinto de `Rack::Attack` (que alinea a `epoch / period`) y en la
  práctica es *mejor*: el borde no es predecible, así que el atacante no puede
  sincronizar con él.
- **Fail open**, por lo que vimos en §5.5.

### 8.2 La clave, y la trampa real

`["rate-limit", scope, name, by].compact.join(":")` con **`scope || controller_path`**.

`controller_path` adentro del lambda se resuelve **en la instancia del controller
que atiende el request**, no en la clase donde declaraste el límite. Verificado:

```text
instancia.controller_path      = "api/v1/reports"
clase base.controller_path     = "api/v1/base"
clase reports.controller_path  = "api/v1/reports"
método definido en             = AbstractController::Base
```

O sea: si `BaseController` declara un `rate_limit` sin `scope:` ni `name:`, y
`ReportsController` (que hereda) declara otro sin `name:`, **los dos producen
literalmente la misma clave**:

```text
SIN name (los dos límites, en el mismo request):
  base    -> rate-limit:api/v1/reports:3
  reports -> rate-limit:api/v1/reports:3      ← IDÉNTICA
CON name/scope (lo que hace el repo):
  base    -> rate-limit:api_v1:api-global:3
  reports -> rate-limit:api/v1/reports:reports:3
```

Comparten contador, y como los dos `before_action` corren en el mismo request,
**cada request lo incrementa dos veces**. Un límite de 20 corta en 11. Simulado
con el mismo `increment` que usa Rails:

```text
request  1 -> contador=2  200        request  9 -> contador=18  200
request  2 -> contador=4  200        request 10 -> contador=20  200
...                                  request 11 -> contador=22  429   ← acá
```

Es exactamente lo que documenta el repo en
`app/controllers/api/v1/base_controller.rb:59-74` ("lo comprobamos: /reports
(20/min) cortaba en la request 11"). El arreglo es dar `name:` distinto a cada
límite, y `scope:` explícito cuando querés que un límite se comparta entre varios
controllers:

```ruby
# app/controllers/api/v1/base_controller.rb:75-79 — techo global de TODA la API v1
rate_limit to: 600, within: 1.minute,
           name: "api-global", scope: :api_v1,
           by: -> { current_api_token&.id || request.remote_ip },
           store: RATE_LIMIT_STORE,
           with: -> { rate_limited!(60) }

# app/controllers/api/v1/reports_controller.rb:11-15 — límite propio del endpoint caro
rate_limit to: 20, within: 1.minute,
           name: "reports",
           by: -> { current_api_token&.id || request.remote_ip },
           store: RATE_LIMIT_STORE,
           with: -> { rate_limited!(60) }
```

Con eso arreglado, el corte cae donde tiene que caer. 24 requests con `curl` y un
token válido:

```text
 1 -> 200   ...  19 -> 200
20 -> 200
21 -> 429   ← el límite es 20, corta en la 21. Correcto.
22 -> 429
23 -> 429
24 -> 429
```

Y las dos claves conviven en Redis, cada una con su cuenta:

```text
ratelimit:rate-limit:api/v1/reports:reports:3  => 24  ttl=54
ratelimit:rate-limit:api_v1:api-global:3       => 24  ttl=54
```

(El `3` final es el `id` del `ApiToken`. Los dos llegaron a 24 porque el límite
global sigue contando aunque el de reportes ya haya cortado: el `before_action`
de `api-global` corre **antes** y no hace `halt`.)

**Por qué la trampa es tan fácil de pisar:** Rails no te avisa. No hay un
`ArgumentError` por dos `rate_limit` sin `name` en la misma jerarquía. El síntoma
es "el límite corta antes de lo que dice el doc", y sin mirar la clave de cache
no hay forma de deducirlo. Regla: **si en una jerarquía de controllers hay más de
un `rate_limit`, `name:` es obligatorio.** El propio docstring de Rails lo dice
(`rate_limiting.rb:37-38`), pero como advertencia, no como validación.

### 8.3 Orden respecto de la autenticación (y un agujero)

En `BaseController`, `include Api::TokenAuthentication` (línea 15) registra
`before_action :authenticate_api_token!` **antes** de que la línea 75 registre el
`before_action` del rate limit. Los callbacks corren en orden de registro:
**primero autentica, después limita**. Eso es lo que permite que `by:` use
`current_api_token&.id`.

La contra, verificada: **un request con token inválido nunca llega al rate
limiter**. `authenticate_api_token!` hace `render` y corta la cadena. Tres
requests con tokens falsos:

```bash
$ curl -H "Authorization: Bearer stk_token_falso_numero_1" localhost:3001/api/v1/reports/reconciliation
401
$ redis-cli --scan --pattern '*'
rack-attack:rack::attack:496698:api/token:99d6d8be...  => 1
rack-attack:rack::attack:496698:api/token:940918d1...  => 1
rack-attack:rack::attack:496698:api/token:aac4dce3...  => 1
rack-attack:rack::attack:5960376:req/ip:127.0.0.1      => 3
rack-attack:rack::attack:29801884:api/heavy-reports:127.0.0.1 => 3
# NO hay ninguna clave "ratelimit:rate-limit:..."   ← la capa 2 nunca corrió
```

Y peor: mirá los tres `api/token` distintos. El throttle de capa 1 discrimina por
**hash del token**, así que **cada token adivinado estrena su propio balde de
1000/hora**. La única barrera real contra la enumeración de tokens es
`req/ip: 300/5min` — 3.600 intentos por hora por IP, y sin agregación IPv6 (§4.1)
eso es efectivamente infinito.

El arreglo: un throttle específico para **requests que fallan la
autenticación**, discriminado por IP (o `/64`), tipo `Allow2Ban` con un ban
largo. Es el mismo razonamiento que el límite de login por IP, aplicado a la API.

### 8.4 `SessionsController`: leé el código, no el comentario

```ruby
# app/controllers/sessions_controller.rb:3-6
# Rate limit NATIVO de Rails sobre el login: la segunda capa, después de
# Rack::Attack. Acá contamos por IP + email juntos, que es más preciso.
rate_limit to: 10, within: 3.minutes, only: :create,
           with: -> { redirect_to new_session_path, alert: "Demasiados intentos..." }
```

El comentario dice "por IP + email juntos". **El código no pasa `by:`**, y el
default es `-> { request.remote_ip }` (`rate_limiting.rb:66`). O sea: cuenta
**sólo por IP**. Igual que `PasswordsController`
(`app/controllers/passwords_controller.rb:4`).

No es catastrófico —la capa 1 ya limita por IP y el 10/3min agrega un techo— pero
es un recordatorio de que **un comentario no es un test**. Si querés lo que el
comentario promete:

```ruby
rate_limit to: 10, within: 3.minutes, only: :create, name: "login-ip-email",
           by: -> { "#{request.remote_ip}:#{params[:email_address].to_s.downcase.strip}" },
           with: -> { redirect_to new_session_path, alert: "Demasiados intentos." }
```

Pero ojo: eso es **más permisivo**, no más estricto. Una IP puede probar 10
claves *por cada email*. Como defensa contra credential stuffing es peor que
contar sólo por IP. Si querés las dos cosas, necesitás **dos** `rate_limit` con
`name:` distinto — que es justamente lo que hace la capa 1 con `logins/ip` y
`logins/email`.

---

## 9. La respuesta correcta: 429 y sus cabeceras

Un 429 pelado es hostil. El cliente no sabe cuánto esperar, así que reintenta
enseguida, y vos gastás recursos rechazando lo mismo cien veces por segundo.

| Cabecera | Qué dice | Ejemplo |
|---|---|---|
| `Retry-After` | segundos (o fecha HTTP) hasta poder reintentar | `Retry-After: 17` |
| `RateLimit-Limit` | cuota de la ventana | `RateLimit-Limit: 5` |
| `RateLimit-Remaining` | cuánto queda | `RateLimit-Remaining: 0` |
| `RateLimit-Reset` | segundos hasta que se resetee la cuota | `RateLimit-Reset: 17` |

**Precisión sobre el número de RFC.** El comentario del repo
(`config/initializers/rack_attack.rb:228`) cita "RFC 9331". Ese número
corresponde a otra cosa (ECN/L4S). Las cabeceras `RateLimit-*` vienen del trabajo
del grupo **httpapi** de la IETF (`draft-ietf-httpapi-ratelimit-headers`).
Verificá el número antes de citarlo en documentación pública o en una entrevista:
lo importante es el **contenido semántico** de los tres campos, y que existen
tres convenciones en circulación:

1. `RateLimit-Limit` / `-Remaining` / `-Reset` — lo que usa este repo.
2. `X-RateLimit-*` — el de facto (GitHub, Twitter). El `X-` está deprecado desde
   RFC 6648 pero es lo que más se ve.
3. `RateLimit: limit=100, remaining=50, reset=30` — un solo *structured field*,
   la forma a la que apunta el draft nuevo.

Elegí una y documentala. Devolver las tres es peor que devolver una.

**Devolvé las cabeceras en las respuestas exitosas también**, no sólo en el 429.
Un cliente bien hecho baja su ritmo cuando ve `RateLimit-Remaining: 3`; si sólo
se entera al recibir el 429, ya se pegó contra la pared. Este repo sólo las
manda en el 429 (`config/initializers/rack_attack.rb:237-245`), que es lo mínimo
aceptable pero no lo ideal.

### 9.1 Qué hace un cliente bien hecho

```ruby
# Consumidor de la API con backoff exponencial + jitter completo.
require "net/http"

# La excepción tiene que llevarse el dato del server, no la respuesta entera:
# `raise MiError, resp` guardaría la respuesta como MENSAJE, y `e.response` no
# existe en StandardError. Es el error clásico al escribir esto de memoria.
class TooManyRequests < StandardError
  attr_reader :retry_after

  def initialize(retry_after)
    @retry_after = retry_after.to_i   # nil.to_i => 0, así que no hace falta guarda
    super("429 Too Many Requests")
  end
end

def con_reintentos(max: 5)
  intento = 0
  begin
    resp = yield
    raise TooManyRequests.new(resp["Retry-After"]) if resp.code.to_i == 429
    resp
  rescue TooManyRequests => e
    intento += 1
    raise if intento > max

    # 1) Si el server dijo cuánto esperar, HACELE CASO. Es la fuente de verdad.
    # 2) Si no dijo nada (retry_after == 0), backoff exponencial acotado.
    base = e.retry_after.positive? ? e.retry_after : [ 2**intento, 60 ].min
    # 3) JITTER COMPLETO, no "base + random". Si 500 clientes se bloquean en el
    #    mismo segundo y todos esperan "base + un poquito", vuelven todos juntos
    #    y te generan un segundo pico idéntico al primero (thundering herd).
    sleep(rand * base)
    retry
  end
end

con_reintentos { Net::HTTP.post_form(URI("http://localhost:3001/session"),
                                     "email_address" => "a@b.c", "password" => "x") }
```

Corrido contra el repo con el throttle de login ya agotado:

```text
  intento 1: 429, Retry-After=3s, duermo 0.12s
  intento 2: 429, Retry-After=2s, duermo 0.17s
  intento 3: 429, Retry-After=2s, duermo 0.07s
  intento 4: 429, Retry-After=2s, duermo 0.33s
  intento 5: 429, Retry-After=2s, duermo 1.59s
  final: 422        ← pasó la ventana, el server volvió a atender
```

Los tres puntos, en orden de importancia:

1. **Respetá `Retry-After`.** Reintentar antes es puro desperdicio.
2. **Exponencial, con techo.** Sin techo, el reintento 10 espera 17 minutos.
3. **Jitter completo (`rand * base`), no aditivo (`base + rand`).** Es la
   diferencia entre dispersar la carga y sincronizarla. Es el mismo razonamiento
   que en los reintentos de jobs (ver `docs/07-colas-jobs-y-mensajeria.md`).

Y del lado servidor: **no loguees a nivel `error` cada 429**. Un ataque te genera
millones y te funde el pipeline de logs. Loguealo agregado (una línea por regla y
por minuto) o a nivel `warn` como hace el repo.

---

## 10. Cómo se eligen los números

No los inventes. El procedimiento es:

**1. Medí primero con `track`.** Ésa es la razón de ser de la primitiva:

```ruby
# config/initializers/rack_attack.rb:219-221
track("api/heavy-reports", limit: 20, period: 1.minute) do |req|
  req.remote_ip if req.path.start_with?("/api/v1/reports/")
end
```

Un `track` con `limit`/`period` emite el evento **sólo cuando se pasa del
límite** (internamente es un `Throttle` con `type: :track`,
`rack-attack-6.8.0/lib/rack/attack/track.rb:11-16`), pero **no bloquea nada**.
Lo dejás dos semanas en producción, contás cuántos clientes *legítimos* lo
habrían tocado, y recién ahí lo convertís en `throttle`. Activar un límite a
ciegas es la forma más rápida de romperle la integración a tu mejor cliente un
viernes.

**2. Trabajá con percentiles, no con promedios.** El promedio te miente: si el p50
de tus clientes hace 5 req/min y uno hace 5.000, el promedio no describe a nadie.
El límite razonable sale del p99 de los clientes legítimos, con margen:

```sql
-- `api_request_logs` NO existe en este repo: es la tabla de logs / warehouse
-- donde habrías volcado los eventos de rack_attack (§7.5).
SELECT
  percentile_cont(0.50) WITHIN GROUP (ORDER BY reqs) AS p50,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY reqs) AS p95,
  percentile_cont(0.99) WITHIN GROUP (ORDER BY reqs) AS p99,
  max(reqs)                                          AS pico
FROM (
  SELECT token_id, date_trunc('minute', created_at) AS minuto, count(*) AS reqs
  FROM api_request_logs
  WHERE created_at > now() - interval '14 days'
  GROUP BY 1, 2
) por_minuto;
```

Regla práctica: **límite ≈ p99 × 2**, redondeado a un número que se pueda decir
en voz alta (100, 500, 1000). Que sea "lindo" importa: va en la documentación
pública y los clientes lo van a hardcodear.

**3. Límites por plan, no un número global.** El límite es parte del producto. Y
acá viene la limitación concreta de la API de Rails, que conviene saber **antes**
de diseñar la feature: **`rate_limit` no acepta un callable en `to:`**. El
chequeo es `count && count > to` (`rate_limiting.rb:77`), o sea que compara
contra el valor tal cual; `to:` no se `instance_exec`a como `by:` y `with:`. Si
le pasás un lambda no explota al declararlo: explota en el **primer request**,
con `ArgumentError: comparison of Integer with Proc failed` (comprobado).

Las tres salidas reales:

```ruby
# a) Un rate_limit por plan, con la condición en `if:` (es un before_action,
#    así que acepta las opciones de siempre).
LIMITES = { "free" => 100, "pro" => 1_000, "enterprise" => 10_000 }.freeze

LIMITES.each do |plan, tope|
  rate_limit to: tope, within: 1.hour, name: "plan-#{plan}",
             by: -> { current_api_token&.id },
             if: -> { current_api_token&.user&.plan == plan },
             store: RATE_LIMIT_STORE,
             with: -> { rate_limited!(60) }
end

# b) El chequeo a mano en un before_action, usando el mismo store.
# c) Subirlo a la capa 1: `Rack::Attack` SÍ acepta callables en `limit:` y
#    `period:` (throttle.rb:61-67), y ahí el tope puede depender del request.
```

(En este repo `User` **no** tiene columna `plan` —el schema tiene `role`, con
check constraint de `admin/manager/operator/viewer`, `db/schema.rb:330-341`—, así
que lo de arriba es el diseño, no código que corra hoy.)

La opción (c) es la más barata en runtime, pero sólo sirve si el plan se puede
derivar del request **sin tocar la base**: si tenés que resolver el token contra
Postgres para saber el plan, ya estás pagando lo que la capa 1 existía para
ahorrar.

**4. Comunicalos.** Tres cosas, mínimo:
- La documentación de la API dice el número, la ventana y el discriminador
  ("1000 requests por hora **por token**", no "1000 requests por hora").
- Las cabeceras `RateLimit-*` en **todas** las respuestas.
- Un aviso proactivo cuando un cliente pasa el 80% sostenido. Un cliente que se
  entera de su límite cuando lo golpea es un ticket de soporte; uno que se entera
  antes es un upsell.

---

## 11. Cómo se testea

Tres problemas específicos, y cómo los resuelve
`spec/requests/api/v1/rate_limiting_spec.rb`.

**Problema 1: el estado se filtra entre ejemplos.** Los contadores viven en un
cache que sobrevive al ejemplo. Sin limpiarlo, el test 2 arranca con la cuenta
del test 1 y falla de forma intermitente. Es la causa #1 de flakiness acá.

```ruby
# spec/requests/api/v1/rate_limiting_spec.rb:17-20
before do
  Rails.cache.clear
  Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)
end
```

(En test, `config.cache_store = :memory_store` — `config/environments/test.rb:35`
— así que `Rails.cache.clear` alcanza para la capa 2.)

**Problema 2: Rack::Attack contamina *todos* los demás specs.** Una suite de
requests hace cientos de llamadas desde `127.0.0.1`: sin apagarlo, empiezan a
aparecer 429 al azar en specs que no tienen nada que ver.

```ruby
# config/environments/test.rb:71-73
config.after_initialize do
  Rack::Attack.enabled = false
end
```

```ruby
# spec/requests/api/v1/rate_limiting_spec.rb:70-74 — y se prende sólo acá
around do |example|
  Rack::Attack.enabled = true
  example.run
  Rack::Attack.enabled = false
end
```

Usá `around`, no `before`/`after`: si el ejemplo levanta una excepción, el
`around` igual restaura el estado. Un `after` también corre, pero el `around` deja
la intención explícita en un solo bloque.

**Problema 3: probar el límite exacto, no "por ahí bloquea".** El test tiene que
fijar el borde: la request `N` pasa, la `N+1` no.

```ruby
# spec/requests/api/v1/rate_limiting_spec.rb:23-31
it "corta EXACTAMENTE al superar el límite de reportes (20/min)" do
  20.times do
    get "/api/v1/reports/reconciliation", headers: headers
    expect(response).to have_http_status(:ok)
  end

  get "/api/v1/reports/reconciliation", headers: headers
  expect(response).to have_http_status(:too_many_requests)
end
```

Y el test de regresión del bug de §8.2, que es el que más valor tiene de toda la
suite porque el bug es invisible:

```ruby
# spec/requests/api/v1/rate_limiting_spec.rb:49-53
it "los distintos rate_limit NO comparten contador (name: distinto)" do
  15.times { get "/api/v1/reports/reconciliation", headers: headers }
  # Con el bug, en la request 11 ya devolvía 429.
  expect(response).to have_http_status(:ok)
end
```

Resultado real de la suite:

```bash
$ bundle exec rspec spec/requests/api/v1/rate_limiting_spec.rb
Randomized with seed 35078

API v1 · Rate limiting
  capa 2: ActionController#rate_limit (por token, por controller)
    el contador es POR TOKEN: otro token arranca de cero
    corta EXACTAMENTE al superar el límite de reportes (20/min)
    los distintos rate_limit NO comparten contador (name: distinto)
    devuelve Retry-After y un cuerpo accionable
  capa 1: Rack::Attack (borde, antes de Rails)
    limita los intentos de login por IP
    el cuerpo del 429 es JSON parseable, no una página de error
    NUNCA limita el health check (si lo limitás, el balanceador te saca de rotación)
    bloquea rutas de escaneo de vulnerabilidades

Finished in 1.72 seconds (files took 1.82 seconds to load)
8 examples, 0 failures
```

(El orden de los ejemplos cambia entre corridas porque la suite está en modo
aleatorio. Que los ejemplos pasen **en cualquier orden** es justamente lo que
prueba que el `before` de limpieza y el `around` de `Rack::Attack.enabled`
hacen su trabajo.)

**El borde de ventana SÍ se puede testear**, y conviene, porque es el defecto que
más sorprende. `Rack::Attack::Cache#key_and_expiry` usa `Time.now.to_i` directo
y `travel_to` de ActiveSupport lo estubea, así que las dos capas responden al
reloj falso. Verificado contra el throttle real del repo (`req/ip`, 300/5min):

```ruby
travel_to(Time.utc(2026, 1, 1, 12, 0, 59)) do
  300.times { throttle.matched_by?(request) }
  throttle.matched_by?(request)   # => true   (la 301 corta)
end

travel_to(Time.utc(2026, 1, 1, 12, 5, 0)) do
  throttle.matched_by?(request)   # => false  (ventana nueva, contador en 0)
end
```

**Lo que NO se puede testear bien con RSpec:** la concurrencia real entre workers
(cada uno es un proceso; el request spec corre en uno solo) y el comportamiento
con Redis caído. Para eso: `redis-cli DEBUG SLEEP 5` en un entorno de staging, y
`--scan` para inspeccionar claves como hicimos en todo este documento. **Un
`redis-cli --scan` después de un request de prueba es el smoke test más barato y
más efectivo que existe para rate limiting.**

---

## Errores que ves en producción

**1. MemoryStore en producción.** Síntoma: el límite de 100 no corta hasta ~380
requests, y no siempre en el mismo número. Causa: cada worker de Puma tiene su
contador. En este repo la causa concreta sería **`REDIS_URL` sin exportar**: el
inicializador cae a `MemoryStore` (y la capa 2 cae a Solid Cache, §5.3). Arreglo:
store compartido (Redis). Detección: `Rack::Attack.cache.store` en la consola de
producción tiene que decir `RedisCacheStoreProxy` —Rack::Attack envuelve el store
en un proxy— y no `MemoryStore`.

**2. `Rack::Attack` insertado antes de `ActionDispatch::RemoteIp`.** Síntoma: a
partir de cierto volumen, *todos* los usuarios reciben 429 al mismo tiempo,
aleatoriamente. Causa: `Rack::Request#ip` es el peer TCP = el balanceador; todo
el tráfico comparte un contador. Arreglo: `insert_after ActionDispatch::RemoteIp`
(`config/application.rb:52`) y el helper `remote_ip`
(`config/initializers/rack_attack.rb:45-51`). Detección: `bin/rails middleware` y
mirar el orden; o `redis-cli --scan` y ver una sola IP en todas las claves.

**3. `X-Forwarded-For` confiable de más.** Dos variantes distintas, y se
confunden. (a) Alguien llega **directo a Puma** y manda el header a mano: el rate
limit por IP se evade entero. Demostrado en §6.2: tres XFF inventados, tres
contadores. Arreglo: firewall — `trusted_proxies` no ayuda acá. (b) Tenés
**proxies encadenados con IP pública** que no están en `trusted_proxies`:
`remote_ip` devuelve la IP del proxy y todo el tráfico que pasa por él comparte
contador (§6.1, fila 4). Arreglo: `config.action_dispatch.trusted_proxies` con
los CIDR **exactos** — y acordate de que asignarlo **reemplaza** los defaults, no
los agrega (`remote_ip.rb:67-74`), así que sumale `TRUSTED_PROXIES` si querés
conservar loopback y RFC 1918. En este repo está en `nil` (sólo los defaults:
RFC 1918 + loopback + ULA + link-local).

**4. Dos `rate_limit` sin `name:` en la misma jerarquía de controllers.**
Síntoma: el límite corta a la mitad del número documentado (20 corta en 11).
Causa: `["rate-limit", scope, name, by].compact.join(":")` produce la misma clave
y cada request incrementa dos veces. Arreglo: `name:` distinto en cada
declaración. Detección: `redis-cli --scan --pattern 'ratelimit:*'` — si ves menos
claves que `rate_limit` declarados, hay colisión.

**5. Discriminador que devuelve `nil` siempre.** Síntoma: **ninguno**, el
throttle simplemente no existe. Causa: el bloque lee un parámetro con la forma
equivocada (`params.dig("session", "email_address")` contra un formulario que
manda `email_address` plano — §4.4). Arreglo: verificar la forma real de los
params. Detección: **la clave del throttle no aparece en Redis**. Este bug está
vivo en `config/initializers/rack_attack.rb:174-186` para `logins/email` y
`password-resets/email`.

**6. `NullStore` bajo `rate_limit`.** Síntoma: ninguno, el límite no limita.
Causa: `increment` devuelve `nil` y `nil && nil > to` es falsy
(`rate_limiting.rb:77`). Arreglo: elegir el store explícitamente y loguear si no
sirve, como hace `app/controllers/api/v1/base_controller.rb:46-57`.

**7. El health check limitado.** Síntoma: el balanceador saca instancias de
rotación durante un pico y el incidente se convierte en una caída total. Causa:
`/up` cae bajo el throttle general. Arreglo: `safelist`
(`config/initializers/rack_attack.rb:99-101`) **y un test que lo fije**
(`spec/requests/api/v1/rate_limiting_spec.rb:98-101`).

**8. 429 que devuelve HTML.** Síntoma: el cliente de la API loguea un error de
parseo de JSON y el equipo pierde horas buscando el bug equivocado. Arreglo:
`throttled_responder` que devuelve el mismo formato de error que el resto de la
API (`config/initializers/rack_attack.rb:230-254`), con test
(`spec/requests/api/v1/rate_limiting_spec.rb:86-91`).

**9. 429 sin `Retry-After`.** Síntoma: el cliente reintenta en loop y multiplica
la carga justo cuando estás saturado. Arreglo: `Retry-After` calculado sobre lo
que le queda a la ventana, no el período completo.

**10. Reintentos sin jitter del lado cliente.** Síntoma: la carga llega en
oleadas perfectamente sincronizadas cada N segundos; el gráfico parece un peine.
Arreglo: jitter completo (`sleep(rand * base)`), no aditivo.

**11. Rate limiting por IP con IPv6 sin agregar al /64.** Síntoma: el límite por
IP deja de funcionar cuando activás IPv6, sin ningún cambio en tu código. Causa:
un abonado tiene 2^64 direcciones. Arreglo: `IPAddr#mask(64)` en el
discriminador (§4.1).

**12. Ban por IP con clientes detrás de CGNAT.** Síntoma: un cliente corporativo
entero se queda afuera por culpa de un solo usuario. Causa: `Fail2Ban` banea la
IP, y esa IP es un edificio. Arreglo: filtros de ban que un usuario legítimo
jamás dispare, safelist de los CIDR de clientes grandes, y preferir el
discriminador por credencial donde exista.

**13. Enumeración de tokens sin límite.** Síntoma: nada visible; en el log, miles
de 401 desde una IP. Causa: la capa 2 nunca corre (el 401 corta antes) y el
throttle de capa 1 discrimina por hash del token, así que cada token adivinado
estrena su balde (§8.3). Arreglo: un throttle de fallos de autenticación
discriminado por IP.

**14. Suscriptor de `ActiveSupport::Notifications` que hace I/O.** Síntoma: la
latencia p99 sube justo cuando hay un ataque. Causa: el bus es síncrono y en el
mismo thread; mandar cada evento a una API externa le suma esa latencia a la
request. Arreglo: logueá, y agregá/exportá aparte.

---

## Cómo responder esto en una entrevista

**1. "¿Qué algoritmo de rate limiting usarías y por qué?"**

> Depende del cliente. Para tráfico de browser, **ventana fija** alcanza: es un
> `INCR` con TTL, cuesta una operación de Redis y el defecto —hasta 2× en el
> borde de ventana— es irrelevante cuando el límite es una red de contención
> gruesa. Para una API de integración uso **token bucket**, porque permite
> ráfagas controladas hasta `capacity` y después fuerza la tasa `rate`: un
> cliente que corre un batch nocturno de 100 requests es legítimo y un fixed
> window lo trata como atacante. Además el token bucket me deja cobrar **costos
> distintos por endpoint** (un reporte agregado cuesta 25 tokens, un GET simple
> cuesta 1), que es el modelo de Stripe. El precio es que hay que implementarlo
> en Lua para que sea atómico, y que el estado son dos valores en vez de un
> entero.
> **Trade-off:** exactitud y expresividad contra simplicidad operativa. Fixed
> window lo depurás con `redis-cli GET`; el token bucket necesita que entiendas
> el script.

**2. "Tenés un límite de 100 requests por minuto. ¿Puede un cliente hacer 200 en
un segundo sin violarlo?"**

> Con ventana fija, sí, y es el defecto clásico. Las ventanas están alineadas al
> reloj (`epoch / period`), así que 100 requests a las 12:00:59 y 100 a las
> 12:01:00 caen en ventanas distintas: 200 requests en 2 segundos, tasa pico de
> 100 req/s contra un límite nominal de 1,67 req/s. Lo vi en vivo en este repo:
> 8 intentos de login contra un límite de 5/20s no dispararon **ningún** 429
> porque cayeron a caballo del borde. Se arregla con **sliding window counter**
> —interpolás la ventana anterior por el tiempo que le queda de peso— que cuesta
> dos enteros por cliente y, según los números que publicó Cloudflare, menos de
> 0,003% de requests mal clasificadas.
> **Trade-off:** el sliding window counter asume tráfico uniforme dentro de la
> ventana anterior, lo cual es falso para ráfagas; el error es acotado y siempre
> conservador.

**3. "¿Por qué dos capas de rate limiting? ¿No es redundante?"**

> No, porque cada capa puede responder una pregunta que la otra no puede. El
> middleware Rack corre antes del routing, la sesión y la autenticación: rechaza
> en ~3 ms y sabe IP, path y headers, pero **no sabe quién sos**. El
> `rate_limit` del controller corre después de autenticar: cuesta ~12 ms porque
> ya pagaste el routing y dos queries, pero es el **único lugar** donde tenés el
> token, el usuario, el tenant y el plan. Los números son medidos en este repo.
> La de afuera absorbe el volumen bruto (escaneo, fuerza bruta, floods
> anónimos); la de adentro aplica la política comercial ("plan free: 20 reportes
> por minuto"). Y en producción hay una tercera todavía más afuera: CDN/WAF, que
> es la que de verdad te salva de un DDoS, porque Rack::Attack ya te está
> costando un worker de Puma.
> **Trade-off:** dos capas es más superficie de configuración y más lugares donde
> equivocarse. Se paga con tests que fijen el comportamiento de cada una.

**4. "¿Por qué limitar el login por IP *y* por email? ¿No alcanza con uno?"**

> Cubren amenazas distintas. El de IP frena el credential stuffing: una máquina
> probando miles de pares usuario/clave. El de email frena el ataque distribuido
> contra **una** cuenta: un botnet de 5.000 IPs probando dos claves cada una — el
> límite por IP no lo ve porque cada IP hace dos requests. Necesitás los dos.
> Y una advertencia práctica: el discriminador por email tiene que **normalizarse**
> (downcase + strip), o el atacante evade el límite cambiando el casing. En este
> repo el throttle por email está declarado pero **no funciona**, porque lee
> `params.dig("session", "email_address")` y el formulario manda `email_address`
> plano: el discriminador es `nil` y `Rack::Attack` saltea el throttle sin
> avisar. Lo detecté mirando qué claves aparecían en Redis después de un POST.
> **Trade-off:** contar por email te expone a que un atacante bloquee una cuenta
> ajena a propósito (DoS de cuenta). Por eso el límite por email es más laxo y
> con ventana más larga (6 cada 15 min acá), y por eso nunca bloqueás la cuenta:
> limitás los intentos.

**5. "¿Qué hacés si Redis se cae?"**

> Es una decisión de producto, no técnica, y hay que tomarla explícitamente.
> **Fail open** (dejar pasar) si el límite protege de abuso y tenés otras capas:
> preferís tráfico sin límite un rato antes que un 500 masivo. **Fail closed** si
> el límite protege un recurso que no puede sobrecargarse — un proveedor externo
> que te cobra por request, una cuota regulatoria. Este repo elige fail open, y
> en dos niveles: el `error_handler` explícito del `RedisCacheStore`, y el
> `failsafe` de ActiveSupport que devuelve `nil` — y como Rails evalúa
> `count && count > to`, un `nil` deja pasar. O sea que **el `rate_limit` de
> Rails es fail-open lo declares o no**; conviene saberlo. La otra mitad de la
> decisión son los timeouts: 200 ms de read/write, porque un Redis *lento* (no
> caído) le agrega su latencia a cada request y convierte tu limitador en tu
> cuello de botella.

**6. "¿Cómo elegís los números?"**

> Midiendo, nunca inventando. Primero pongo la regla en modo `track`: cuenta y
> emite el evento pero no bloquea. Lo dejo dos semanas en producción y miro
> cuántos clientes **legítimos** habrían tocado el límite. Trabajo con
> percentiles, no promedios: el límite sale del p99 de los clientes legítimos por
> ~2, redondeado a un número que se pueda decir en voz alta, porque va a la
> documentación pública. Después son límites **por plan**, porque el límite es
> parte del producto, no una defensa. Y los comunico en tres lugares: el doc de
> la API (diciendo el discriminador, no sólo el número: "1000 por hora **por
> token**"), las cabeceras `RateLimit-*` en **todas** las respuestas —no sólo en
> el 429, porque el cliente tiene que poder frenar antes de chocar—, y una alerta
> proactiva al cliente que pasa el 80% sostenido.
> **Trade-off:** medir primero te cuesta dos semanas de exposición sin
> protección. Si la amenaza es activa, activás un límite deliberadamente laxo hoy
> y lo ajustás con datos después.

**7. "¿Por qué no confiás en `X-Forwarded-For`?"**

> Porque es un header que manda el cliente: cualquiera lo escribe. Lo probé en
> este repo mandando tres valores inventados desde `curl` y obtuve **tres
> contadores independientes** en Redis: el límite por IP deja de existir. La
> defensa no es ignorar el header —lo necesitás, si no todos tus usuarios son el
> balanceador— sino entender qué arregla cada cosa.
> `ActionDispatch::RemoteIp` toma la cadena de XFF, filtra los proxies confiables
> y se queda con el que sobra más a la derecha. Con **un solo** salto que
> *agrega* el peer real al final —un ALB típico— eso ya te devuelve al cliente
> correcto aunque el balanceador no esté en `trusted_proxies`, porque el valor
> que él agrega queda a la derecha del que inventó el cliente; lo verifiqué
> armando las cuatro combinaciones. `trusted_proxies` importa cuando tenés
> **varios saltos con IP pública**: ahí, si el intermedio no está en la lista,
> `remote_ip` devuelve el proxy y todos comparten contador. Y lo del spoofing
> puro lo arregla el firewall, no Rails: si alguien puede hablar con Puma sin
> pasar por el balanceador, él es el primer salto y no hay configuración que te
> salve.
> **Trade-off:** cada CIDR que agregás a `trusted_proxies` es un agujero
> potencial. La lista tiene que ser lo más chica posible y revisarse cuando
> cambia la infraestructura.
