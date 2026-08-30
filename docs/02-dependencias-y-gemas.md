# Dependencias: qué gema hace qué y por qué la elegimos

Acá tenés el `Gemfile` de este repo recorrido entrada por entrada: qué problema resuelve
cada gema, cuál era la alternativa, por qué elegimos ésta, y el equivalente en el mundo
Java cuando existe. Antes de eso, cómo funciona Bundler de verdad —resolución, lockfile,
grupos, `require: false`— porque ahí es donde un javero traduce mal desde Maven.

Todos los números salen de correr los comandos contra este repo (Ruby 3.3.6, Rails 8.1.3.1,
Bundler 4.0.9, PostgreSQL 16.13). Cuando una medición contradice lo que dice el comentario
del código, lo digo. Verificando este documento aparecieron **tres lugares** donde lo que se
afirmaba no aguantaba la medición —`oj` sin enganchar (§17), el comentario del `Gemfile` sobre
el `COUNT(*)` de pagy (§18) y la config de `bullet` en test (§27)—. **Los tres ya están
arreglados en el repo**, y cada sección cuenta cómo se veía el bug, cómo se detectó y cómo
quedó: el hallazgo vale más que el parche. Los comentarios del `Gemfile` y de `config/` son la
fuente de verdad del *por qué*; este documento agrega el *cómo se comprueba*.

---

## 0. Los números de este repo

Todo medido acá adentro, no copiado de un blog:

| Medición | Valor | Cómo se obtuvo |
|---|---|---|
| Gemas instaladas (resueltas) | **155** | `bundle list \| grep -c '^  \*'` |
| Dependencias directas en el `Gemfile` | **46** | sección `DEPENDENCIES` de `Gemfile.lock` |
| Boot sin bootsnap | **2.39 s** | `time DISABLE_BOOTSNAP=1 bin/rails runner nil` |
| Boot con bootsnap caliente | **1.23 s** | `time bin/rails runner nil` |
| Primer boot con bootsnap (cache frío) | **3.23 s** | idem, tras borrar `tmp/cache/bootsnap` |
| Tamaño del cache de bootsnap | **16 MB** | `du -sh tmp/cache/bootsnap` |
| Archivos cargados al bootear (dev) | **2115** | `$LOADED_FEATURES.size` |
| RSS de un proceso booteado (dev) | **94 MB** | `/proc/self/status` |
| Costo de cargar rubocop + brakeman | **+16 MB, +404 archivos** | `require` a mano y medir |
| Un hash de bcrypt (cost 12) | **233 ms** | `Benchmark.realtime` |
| Suite de RuboCop | 194 archivos, 0 ofensas | `bin/rubocop` |
| Brakeman | 20 controllers, 22 models, 0 warnings, 1.5 s | `bin/brakeman --quiet` |
| bundler-audit | 1237 advisories, 0 vulnerabilidades | `bin/bundler-audit check` |

Guardá el `+16 MB / +404 archivos`: es la justificación entera de `require: false`, y es la
respuesta que te van a pedir en la entrevista.

---

# Parte I — Bundler

## 1. El Gemfile no es un pom.xml

La analogía funciona para arrancar y se rompe en cuatro lugares importantes.

| | Maven / Gradle | Bundler |
|---|---|---|
| Declaración | `pom.xml` | `Gemfile` |
| Resultado resuelto | árbol efímero (`dependency:tree`) | `Gemfile.lock`, **versionado en git** |
| Aislamiento | classloaders, shading, uber-jars | **ninguno**: un proceso, un `$LOAD_PATH` |
| Conflictos | "nearest wins", silencioso | **falla la resolución**, ruidoso |
| Scopes | `compile` / `provided` / `test` | `group`s, que la app elige cargar |
| Ejecutar | `mvn exec` | `bundle exec` |

### 1.1 La ruptura importante: no existe el classloader

En la JVM podés tener Guava 19 y Guava 31 en el mismo proceso si están en classloaders
distintos, o si sombreaste uno. En Ruby **no**. `require "nokogiri"` mete constantes en el
único espacio global de constantes del proceso. Una sola versión de cada gema, siempre.

Consecuencia directa: donde Maven resuelve un conflicto de versiones eligiendo la más
cercana en el árbol y sigue adelante (y te enterás en runtime con un `NoSuchMethodError`),
Bundler **se niega a instalar**. Es más molesto y es mucho mejor: el error aparece en
`bundle install`, no en producción a las tres de la mañana.

### 1.2 El operador pesimista `~>`

```ruby
gem "pagy", "~> 9.3"        # >= 9.3,   < 10.0    (permite 9.4, 9.9)
gem "sidekiq", "~> 8.0"     # >= 8.0,   < 9.0
gem "rails", "~> 8.1.3", ">= 8.1.3.1"   # >= 8.1.3.1, < 8.2
```

La regla: `~>` deja variar **el último componente que escribiste**. `~> 9.3` libera el
segundo nivel; `~> 9.3.1` sólo liberaría el tercero. Es la versión declarativa de lo que en
Maven hacés a mano con rangos `[9.3,10.0)`, y en Gradle con `9.3.+`.

Esto no es teoría acá. Mirá la salida real:

```bash
$ bundle outdated
Gem               Current  Latest  Requested  Groups
diff-lcs          1.6.2    2.0.0
ferrum            0.17.2   0.18.0
marcel            1.2.1    2.1.0
pagy              9.4.0    43.6.2  ~> 9.3     default
redis             5.4.1    6.0.0   ~> 5.3     default
shoulda-matchers  6.5.0    8.0.1   ~> 6.4     test
```

Pagy está en 9.4.0 y publica 43.6.2. El `~> 9.3` nos deja en la serie 9.x a propósito: la
API de pagy cambió fuerte después de la 9 y actualizar es una migración, no un bump. Fijate
también que `diff-lcs`, `ferrum` y `marcel` aparecen **sin** columna `Requested`: son
dependencias transitivas, nadie las declaró, y por eso no tienen restricción propia.

### 1.3 Qué hay realmente adentro del `Gemfile.lock`

716 líneas, cinco secciones, y cada una responde una pregunta distinta:

```text
GEM / specs      -> el grafo resuelto completo, con las dependencias de cada gema
PLATFORMS        -> para qué arquitecturas está resuelto este lock
DEPENDENCIES     -> lo que vos pediste (las 46 líneas del Gemfile)
CHECKSUMS        -> sha256 de cada .gem                       <- integridad de supply chain
RUBY VERSION     -> ruby 3.3.6
BUNDLED WITH     -> 4.0.9
```

Tres cosas que no tienen equivalente directo en Maven:

**`PLATFORMS`.** Nuestro lock declara nueve:

```text
aarch64-linux  aarch64-linux-gnu  aarch64-linux-musl  arm-linux-gnu
arm-linux-musl  arm64-darwin  x86_64-darwin  x86_64-linux-gnu  x86_64-linux-musl
```

Un `.gem` puede traer binarios ya compilados por plataforma. El lock tiene que listar la
plataforma donde vas a **desplegar**, no sólo donde desarrollás. Si tu equipo usa MacBooks
ARM y el CI corre en `x86_64-linux`, y el lock sólo tiene `arm64-darwin`, el build de Docker
explota. Se arregla con `bundle lock --add-platform x86_64-linux`. Y ojo con
`musl` vs `gnu`: es Alpine vs Debian, y son binarios distintos.

**`CHECKSUMS`.** Cada gema con su sha256:

```text
pg (1.6.3-x86_64-linux) sha256=5d9e188c8f7a0295d162b7b88a768d8452a899977d44f3274d1946d67920ae8d
```

Si alguien republica una versión con contenido distinto, `bundle install` falla. Maven tiene
`.sha1` sueltos al lado del artefacto y nadie los mira; acá está adentro del archivo que
commiteás y revisás en el pull request.

**`BUNDLED WITH`.** La versión de Bundler que generó el lock. Si tu CI tiene una Bundler más
vieja, te avisa. No hay nada parecido en Maven —el `mvn` que corre es el que haya.

### 1.4 Grupos: NO son los scopes de Maven

Esta es la segunda ruptura conceptual. En Maven, `<scope>test</scope>` es una instrucción
para el **compilador y el empaquetador**: el jar no va al classpath de producción. En Ruby no
hay compilación ni empaquetado, así que el grupo es una instrucción para **el arranque de la
app**, en runtime:

```ruby
# config/application.rb:19
Bundler.require(*Rails.groups)
```

`Rails.groups` devuelve `[:default, <RAILS_ENV>]`. Medido en este repo:

```ruby
Rails.env       # => "development"
Rails.groups    # => [:default, "development"]
```

O sea: Bundler hace `require` automático de **todas** las gemas de esos grupos. Comprobado
con `bin/rails runner`, sin haber escrito un solo `require` en el código de la app:

```text
pagy cargado?     SI      <- grupo default
oj cargado?       SI      <- grupo default
redis cargado?    SI      <- grupo default
sidekiq cargado?  NO      <- grupo default, pero con require: false
rubocop cargado?  NO      <- require: false
brakeman cargado? NO      <- require: false
kamal cargado?    NO      <- require: false
bootsnap cargado? SI      <- lo carga config/boot.rb a mano, antes de todo
bullet cargado?   SI      <- grupo :development, :test
```

Dos cosas para notar. Primero, **`sidekiq` estuvo cargándose en todos los procesos sin que
nadie lo usara**, y esa línea decía `sidekiq cargado? SI`. Está en el grupo `default` a
propósito (para poder comparar los dos adapters con el mismo código de jobs), pero el
`QUEUE_ADAPTER` por defecto es `solid_queue`: era RAM y tiempo de boot regalados en el
proceso web, en el worker, en la consola y en cada tarea rake. Hoy la declaración es
`gem "sidekiq", "~> 8.0", require: false` y la carga la hace el `require` condicional del
initializer sólo cuando corresponde (el detalle completo en §1.5). Fijate que `redis` **sí**
sigue cargándose: es la que usa `Rack::Attack` para el store de contadores, así que ahí no
hay nada que ahorrar.

Segundo: las gemas de `:development` **están instaladas en producción salvo que lo impidas**.
Quien lo impide es el `BUNDLE_WITHOUT` del `Dockerfile`:

```dockerfile
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_WITHOUT="development"
```

`BUNDLE_DEPLOYMENT=1` es el otro que importa: hace que `bundle install` **falle** si el
`Gemfile.lock` no está sincronizado con el `Gemfile`, en vez de re-resolver en silencio. Es
el equivalente moral de `mvn --offline` con el lock como contrato. En CI y en Docker esto
siempre va prendido.

### 1.5 `require: false` y qué cuesta de verdad

La declaración:

```ruby
gem "brakeman", require: false
gem "rubocop-rails-omakase", require: false
gem "bootsnap", require: false
gem "kamal", require: false
```

Significa: instalala, dejala disponible para `bundle exec`, pero **no la cargues al bootear**.
Lo medí:

```ruby
before = rss; f0 = $LOADED_FEATURES.size
require "rubocop"; require "brakeman"
# => +16 MB de RSS, +404 archivos
```

16 MB **por proceso**. Con 4 workers de Puma más 3 procesos de Solid Queue son ~110 MB de
RAM tirados para cargar dos herramientas de línea de comandos que jamás corren dentro de la
app. Y en tiempo de boot, 404 archivos más para resolver, leer y evaluar en cada arranque —
que en desarrollo pagás en cada reinicio.

En Java el problema no existe porque un jar en el classpath que nadie referencia no se carga:
el classloader es perezoso. En Ruby, `require` **ejecuta el archivo** —define clases, abre
clases existentes, registra railties, engancha hooks—. Por eso hay que decir explícitamente
qué no cargar.

Casos donde `require: false` es obligatorio y no opcional:
- herramientas CLI (rubocop, brakeman, bundler-audit, kamal, thruster);
- gemas que tienen que cargarse **antes** que Rails (`bootsnap`, al que carga a mano
  `config/boot.rb:4`, antes que `config/application.rb`);
- gemas que se cargan a mano y condicionalmente.

El tercer caso **estuvo a medio hacer en este repo**, y es el mejor ejemplo del documento.
`config/initializers/sidekiq.rb:36` hace `require "sidekiq"` sólo si
`QUEUE_ADAPTER == "sidekiq"`... pero el `Gemfile` la declaraba **sin** `require: false`, así
que Bundler ya la había cargado en **todos** los procesos antes de llegar ahí. La medición de
§1.4 lo mostraba en una línea: `sidekiq cargado? SI`. El `require` condicional del initializer
no ahorraba nada, porque **una optimización partida entre dos archivos no funciona si sólo
escribís una mitad**. Las dos mitades van juntas.

Arreglado: hoy el `Gemfile` dice

```ruby
gem "sidekiq", "~> 8.0", require: false
```

y la misma comprobación devuelve `sidekiq cargado? NO` con `QUEUE_ADAPTER=solid_queue`, que es
el default. La regla para llevarse: **el `require: false` y el `require` a mano son un solo
cambio en dos lugares**; verificá el resultado con `Object.const_defined?`, no leyendo el
`Gemfile`.

Y el caso donde `require: false` te muerde: la gema tiene un railtie que hace algo
importante y al no cargarla no pasa nada... en silencio. Si una gema "no anda" y estás
seguro de que está en el Gemfile, mirá si tiene `require: false`.

### 1.6 Los dos comandos de mantenimiento

**`bundle outdated`** (salida real más arriba). Te dice qué se puede subir, separando lo
que pediste explícitamente de lo transitivo. No modifica nada. Equivale a
`mvn versions:display-dependency-updates`.

Variantes que sirven:
```bash
bundle outdated --strict   # sólo lo que entra dentro de tus restricciones actuales
bundle update --conservative pagy   # sube pagy sin arrastrar sus dependencias
bundle update              # ⚠️ re-resuelve TODO el grafo; casi nunca es lo que querés
```

**`bundle audit`** (acá `bin/bundler-audit`, que además pasa `--config config/bundler-audit.yml`).
Salida real:

```bash
$ bin/bundler-audit check
Download ruby-advisory-db ...
ruby-advisory-db:
  advisories:   1237 advisories
  last updated: 2026-08-29 09:32:01 -0400
  commit:       c7562c2617416f453c366ffc976c804315365e33
No vulnerabilities found
```

Es OWASP dependency-check, pero mucho más simple: clona la
[ruby-advisory-db](https://github.com/rubysec/ruby-advisory-db) y cruza CVEs contra tu
`Gemfile.lock`. No analiza tu código —de eso se encarga Brakeman—; sólo compara versiones.

`config/bundler-audit.yml` tiene la lista de CVEs a ignorar. Úsala con disciplina: cada
entrada necesita un comentario que diga *por qué* no aplica, o en seis meses nadie sabe si es
un riesgo aceptado o un olvido.

Los dos corren en CI. Están en `config/ci.rb` (el runner de `bin/ci`, que es
`ActiveSupport::ContinuousIntegration` de Rails 8) y en `.github/workflows/ci.yml`:

```ruby
# config/ci.rb
step "Security: Gem audit", "bin/bundler-audit"
step "Security: Importmap vulnerability audit", "bin/importmap audit"
step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
```

Ese `bin/importmap audit` es el que audita el JavaScript. Comprobado: `No vulnerable
packages found`. Volvemos sobre él en la sección de importmap.

### 1.7 Gemas nativas: qué son y por qué fallan

Una gema "nativa" trae una extensión en C que se compila contra los headers de tu Ruby.
Es una JNI que se construye en tu máquina en `gem install`.

En este repo, las gemas con extensión C instaladas son:

```text
bcrypt  bcrypt_pbkdf  bigdecimal  bindex  bootsnap  date  debug  ed25519
erb  io-console  json  msgpack  nio4r  nokogiri  oj  pg  prism  puma
racc  rbs  stackprof  websocket-driver
```

Pero hay dos formas de instalarlas, y la diferencia es la que decide si tu Docker build tarda
20 segundos o 6 minutos. Mirá las rutas reales:

```bash
$ bundle list --paths | grep -E "pg-|nokogiri-|puma-|oj-|bcrypt-|thruster|tailwindcss-ruby"
.../gems/bcrypt-3.1.22                        <- compilada desde fuente
.../gems/oj-3.17.6                            <- compilada desde fuente
.../gems/puma-8.0.2                           <- compilada desde fuente
.../gems/nokogiri-1.19.4-x86_64-linux-gnu     <- BINARIO precompilado
.../gems/pg-1.6.3-x86_64-linux                <- BINARIO precompilado
.../gems/tailwindcss-ruby-4.3.3-x86_64-linux-gnu  <- BINARIO precompilado
.../gems/thruster-0.1.26-x86_64-linux         <- BINARIO precompilado
```

El sufijo de plataforma en el nombre significa que el autor publicó un `.so` ya compilado.
Bundler lo baja y no compila nada. Sin sufijo, corre `extconf.rb`, genera un `Makefile` y
llama a `make`.

**Por qué falla la instalación**, en orden de frecuencia:

1. **Falta la librería de desarrollo del sistema.** `pg` necesita `libpq-dev`; `nokogiri`
   necesitaba `libxml2-dev`. Síntoma: `Can't find the 'libpq-fe.h' header`. Por eso el
   `Dockerfile` instala esas cosas **sólo en la etapa de build**:
   ```dockerfile
   RUN apt-get install --no-install-recommends -y \
       build-essential git libpq-dev libvips libyaml-dev pkg-config
   ```
   y la imagen final sólo lleva `postgresql-client` y `libvips`. Compilás en una etapa que
   se tira; es exactamente el patrón multi-stage que usarías con un jar.
2. **Falta el compilador entero.** `You have to install development tools first` o
   `make: command not found`. En Alpine faltan `build-base` y los headers musl.
3. **Los headers de Ruby no están.** Con Ruby del sistema hace falta `ruby-dev`. Con rbenv
   (como acá) vienen incluidos y el problema no aparece.
4. **musl vs glibc.** Cambiás la base de Debian a Alpine y el binario `x86_64-linux-gnu` ya
   no sirve. El lock tiene que incluir `x86_64-linux-musl`.
5. **`BUNDLE_FORCE_RUBY_PLATFORM=1`.** Alguien lo puso para saltar un bug de un binario y
   ahora todo se compila desde fuente. Suele ser la explicación de "el CI tarda 8 minutos en
   `bundle install`".

Detalle no obvio del `Dockerfile`, y muy citable:

```dockerfile
# -j 1 disable parallel compilation to avoid a QEMU bug
bundle exec bootsnap precompile -j 1 --gemfile
```

Compilar imágenes ARM sobre x86 con QEMU rompe la compilación paralela. Cuando alguien te
diga "el build sólo falla en el runner de ARM", esto es lo primero que mirás.

### 1.8 Cómo decidir si agregás una dependencia

El criterio que usamos, en orden. Si falla el primero, no seguís:

1. **¿Lo escribís en 50 líneas y las entendés todas?** Entonces escribilo. La regla vale
   sobre todo para "helpers" de una función. Una gema es un nodo más en un grafo que acá ya
   tiene 155, un changelog más que seguir y un CVE potencial más.
2. **¿Está mantenida?** Último release en los últimos 12 meses, issues respondidos, y
   —crítico en Ruby— **compatible con la última minor de Rails**. Una gema que monkeypatchea
   ActiveRecord y no se actualizó desde Rails 7.0 te bloquea el upgrade del framework entero.
3. **¿Cuánta superficie de API te obliga a adoptar?** `pagy` te da un objeto y un método:
   si mañana lo sacás, tocás los controllers. `kaminari` te agrega `.page` a **todos** los
   `ActiveRecord::Relation` de la app: sacarlo es un refactor. Preferí lo que se enchufa
   sobre lo que se inyecta.
4. **¿Cuánto pesa al bootear?** `require "la_gema"` en `irb`, mirás RSS antes y después.
   Si son 30 MB para usar dos métodos, escribilos vos.
5. **¿Reemplaza algo que Rails ya trae?** Rails 8 se comió gemas enteras: rate limiting
   (`ActionController#rate_limit` reemplaza buena parte de rack-attack), autenticación
   (el generador de sesiones reemplaza a Devise para casos simples), colas (Solid Queue),
   cache (Solid Cache). Antes de agregar, buscá en las release notes.
6. **¿Podés aislarla detrás de una interfaz tuya?** Si la respuesta es sí, el riesgo baja
   mucho. Es el mismo razonamiento que envolver un cliente HTTP de terceros detrás de una
   interfaz en Spring.

Aplicado a este repo: por ese criterio **`oj` estuvo a punto de salir** —entró por
performance, y durante un buen rato ni siquiera estaba enganchado (§17)—; hoy se queda, pero
con la ganancia medida y acotada, no por fe. `faker` está al límite. Todo lo demás pasa.

---

# Parte II — El núcleo

## 2. `rails` (8.1.3.1)

```ruby
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
```

Es un meta-gem: no tiene código propio, sólo declara sus doce componentes en versión exacta
(`= 8.1.3.1`), más una dependencia sobre el propio `bundler`. En el lock:

```text
rails (8.1.3.1)
  actioncable, actionmailbox, actionmailer, actionpack, actiontext, actionview,
  activejob, activemodel, activerecord, activestorage, activesupport, railties
```

Es un BOM de Maven, pero con las versiones clavadas en `=` en vez de gestionadas. Por eso no
podés subir sólo ActiveRecord: los doce se mueven juntos.

Y podés no cargarlos todos. `config/application.rb:5-15` elige los frameworks a mano:

```ruby
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"
```

Tres cosas están comentadas a propósito. Action Mailbox y Action Text no se usan (menos
código cargado, menos tablas, menos superficie). Y `rails/test_unit/railtie` está apagado
porque usamos RSpec: sin eso, `bin/rails test` no existe y los generadores no crean
archivos de Minitest. Es la decisión de §20 hecha explícita en el boot.

## 3. `puma` — y en qué NO es Tomcat

```ruby
gem "puma", ">= 6.0"    # instalado: 8.0.2
```

La analogía "Puma es Tomcat" alcanza para una charla de pasillo y se rompe en el punto que
más importa: **el modelo de concurrencia**.

### 3.1 Threads: la JVM corre en paralelo, CRuby no

En la JVM, 200 threads de Tomcat ejecutan bytecode en paralelo real sobre todos los cores.
En CRuby existe el **GVL** (Global VM Lock): un solo thread ejecuta bytecode Ruby por vez.

Ahora, la parte que casi nadie explica bien: **el GVL se libera durante I/O y durante código
C que lo suelte explícitamente**. Lo medí en esta máquina (4 cores):

```ruby
n = 8
seq = Benchmark.realtime { n.times { BCrypt::Password.create("x", cost: 12) } }
par = Benchmark.realtime { n.times.map { Thread.new { BCrypt::Password.create("x", cost: 12) } }.each(&:join) }
```

```text
nucleos: 4
secuencial 8 hashes: 1.87 s
en 8 threads:        0.49 s   -> speedup 3.82x   (bcrypt LIBERA el GVL)

ruby puro CPU-bound (8 tandas de 3M sumas, las mismas 8 unidades de trabajo):
secuencial 1.14 s / en 8 threads 1.18 s -> speedup 0.97x   (NO hay paralelismo)
```

Ahí tenés todo el modelo en dos mediciones. `bcrypt`, que es una extensión C que suelta el
GVL, **escala con los cores**. Ruby puro no escala nada: 8 threads tardan lo mismo que
secuencial. `pg` también libera el GVL mientras Postgres procesa la query, y por eso los
threads sirven para una app web típica, que pasa la mayor parte del tiempo esperando SQL.

La regla que sale de ahí, y que es la respuesta correcta en una entrevista:

> Threads para I/O, procesos para CPU. En la JVM los threads te dan las dos cosas; en CRuby
> sólo la primera.

### 3.2 La configuración real

`config/puma.rb` de este repo, entero, es corto:

```ruby
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count       # línea 29

port ENV.fetch("PORT", 3000)
plugin :tmp_restart
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]   # línea 38
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
```

Notá lo que **no** está: no hay `workers` ni `preload_app!`. Rails 8 los sacó del generador
por defecto, y es una decisión deliberada: la mayoría de los despliegues modernos corren un
proceso por contenedor y escalan agregando contenedores, que es más simple de operar y de
observar. `WEB_CONCURRENCY` sigue funcionando igual sin escribir nada: Puma lo lee solo
(`puma-8.0.2/lib/puma/configuration.rb:248`), y acepta `auto` para levantar un worker por
core.

`threads 3, 3` con mínimo igual al máximo es intencional: un pool elástico agrega latencia
al crear threads bajo carga y complica dimensionar el pool de la base.

Y ese `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` es un detalle de arquitectura
lindo: te deja correr el supervisor de jobs **dentro** del proceso web para un despliegue de
un solo servidor. En Java sería meter un scheduler de Quartz adentro del Tomcat; funciona,
tiene el mismo trade-off (un job pesado te come CPU del web) y la misma ventaja (una cosa
menos que operar).

Ojo con esa condición, porque **este repo tuvo el bug**: `config/deploy.yml` la traía en
`env.clear` con el valor `false`, pensando que la apagaba. Kamal serializa eso como
`--env SOLID_QUEUE_IN_PUMA=false`, o sea que el contenedor recibe **el string `"false"`**, y
en Ruby cualquier string es *truthy*: la condición daba `true` y el supervisor de Solid Queue
arrancaba dentro de **cada contenedor web**, además del rol `job`. Workers de más peleándose
los mismos jobs y comiéndose conexiones a la base. La variable se sacó de `deploy.yml`
directamente. La regla, que vale para toda variable de entorno booleana:
**`ENV["X"]` devuelve un string o `nil`, nunca un booleano** — o preguntás por presencia y no
la seteás nunca, o la comparás explícitamente (`ENV["X"] == "true"`).

### 3.3 Cluster mode: workers, `preload_app!`, copy-on-write

Cuando sí ponés workers:

```ruby
workers ENV.fetch("WEB_CONCURRENCY", 2)
preload_app!

on_worker_boot do
  ActiveRecord::Base.establish_connection   # ← IMPRESCINDIBLE con preload_app!
end
```

El master hace `fork()` por cada worker. `preload_app!` carga la app **antes** del fork, así
que las páginas de memoria del código se comparten por copy-on-write entre todos los workers.
Sin preload, cada worker carga la app entero por su cuenta: arranca más lento y usa mucha
más RAM.

El costo del preload, y es la trampa clásica: **los file descriptors se heredan por el fork**.
Las conexiones a Postgres abiertas antes del fork quedan compartidas entre procesos, y dos
procesos escribiendo en el mismo socket producen errores incomprensibles
(`PG::UnableToSend`, respuestas cruzadas). Por eso el `on_worker_boot` reconecta. En Java
esto no te pasa nunca porque no hay `fork()`: los threads comparten el pool y punto.

Copy-on-write en Ruby además se degrada: el GC escribe en las cabeceras de los objetos al
marcarlos, y esas páginas se copian igual. Ruby 2.7+ lo mitiga bastante, y el `Dockerfile`
ataca el otro flanco, la fragmentación del allocator:

```dockerfile
RUN apt-get install -y libjemalloc2 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so
ENV LD_PRELOAD="/usr/local/lib/libjemalloc.so"
```

jemalloc en vez del malloc de glibc suele bajar el RSS de una app Rails entre 10% y 30%. Es
el equivalente de elegir un GC distinto en la JVM, salvo que acá el ajuste está en el
allocator del sistema, no en flags de la VM.

### 3.4 Phased restart vs hot restart

| | Qué hace | Downtime | Requisito |
|---|---|---|---|
| **hot restart** (`SIGUSR2`) | reinicia el master y todos los workers | breve (~1 boot) | ninguno |
| **phased restart** (`SIGUSR1`) | reinicia workers **de a uno** | cero | cluster mode **y `preload_app!` apagado** |

La restricción del phased restart es la que se olvida: **es incompatible con `preload_app!`**.
Tiene sentido si pensás qué hace: reiniciar workers de a uno sirve porque cada worker carga
el código nuevo al arrancar; con preload, el código vive en el master, que no se reinició, y
los workers nuevos levantarían el código viejo. Puma directamente lo rechaza.

O sea que elegís: **preload_app! (menos RAM, boot más rápido) o phased restart (deploy sin
downtime)**. No las dos. La salida moderna, y la que usa este repo, es no elegir: deploy azul-verde
a nivel de contenedor con Kamal (§30), donde el proxy corta el tráfico al contenedor viejo
recién cuando el nuevo pasa el health check. El problema se resuelve una capa más arriba.

Comparación honesta con Java: Tomcat no tiene phased restart porque no lo necesita —
recargás un WAR o reiniciás la JVM, y el modelo de un proceso con muchos threads hace que
todo esto sea una no-cuestión. El precio que paga la JVM es el startup, que históricamente
fue mucho peor.

## 4. `pg` (1.6.3)

El driver nativo de PostgreSQL. Wrapper sobre `libpq`, la librería oficial en C. Medido acá:

```ruby
ActiveRecord::Base.connection.adapter_name  # => "PostgreSQL"
select_value("show server_version")         # => "16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)"
PG.library_version                          # => 180001   (libpq 18.1)
```

Fijate que **libpq 18 habla con un servidor 16**: el protocolo de Postgres es compatible
hacia atrás y adelante. Es lo mismo que un driver JDBC nuevo contra un servidor viejo.

Diferencias con JDBC que importan:

- **No hay una capa de abstracción tipo `java.sql.Driver`.** `pg` es específico de Postgres,
  y ActiveRecord tiene un adapter por base. No existe el "cambiamos de motor tocando la URL"
  —que en Java tampoco funciona de verdad, pero acá ni siquiera se pretende.
- **El pool de conexiones lo pone ActiveRecord, no el driver.** No hay HikariCP. La config
  está en `config/database.yml` (`max_connections`, `checkout_timeout`, `idle_timeout`), y
  el pool es **por proceso**: 3 workers × 5 threads = 15 conexiones desde una máquina. Con
  cuatro bases configuradas (primary, cache, queue, cable), cada una abre su propio pool.
  Ese cálculo está explicado en detalle en los comentarios de `config/database.yml`; es el
  error de escalado número uno.
- **Tipos nativos.** `pg` devuelve arrays, `jsonb`, rangos e intervalos como objetos Ruby,
  sin mapeo declarado. En JPA necesitás un `AttributeConverter` o `hibernate-types`.
- Un detalle de este repo: `config/initializers/postgresql_types.rb` fuerza `timestamptz`
  como tipo por defecto para las columnas de fecha. El razonamiento completo está en ese
  archivo; la versión corta es `Instant` en vez de `LocalDateTime`.

---

# Parte III — Assets y front-end

## 5. `propshaft` vs `sprockets`

Propshaft hace **tres** cosas: le pone un digest al nombre de cada archivo, lo sirve, y
reescribe las URLs dentro del CSS para que apunten a los nombres con digest. Nada más. No
transpila, no concatena, no interpreta directivas `//= require`, no tiene un DSL.

Sprockets hacía todo eso y por eso era lento, difícil de debuggear y una fuente eterna de
"anda en dev y en producción no".

| | Sprockets | Propshaft |
|---|---|---|
| Fingerprinting | sí | sí |
| Concatenación | sí (`//= require`) | no |
| Transpilación | sí (vía gemas: sass, coffee, uglifier) | no |
| Modelo mental | pipeline de transformaciones | mapa de archivo → archivo con digest |
| Java análogo | maven-frontend-plugin + minify plugins | `<link>` con un hash en el nombre |

Comprobado en este repo (`bin/rails middleware`): `Propshaft::Server` está en el stack, y
`Propshaft::QuietAssets` justo después de `Rack::Attack`. Y la resolución real de
`app/views/layouts/application.html.erb:10`:

```erb
<%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
```

emite dos etiquetas:

```html
<link rel="stylesheet" href="/assets/application-8b441ae0.css" />
<link rel="stylesheet" href="/assets/tailwind-7f74a9b4.css" />
```

Una viene de `app/assets/stylesheets/application.css`, la otra de
`app/assets/builds/tailwind.css` (el output del binario de Tailwind). Propshaft no las
concatenó: son dos requests. Con HTTP/2 eso está bien, y a cambio el cache invalida por
archivo en vez de invalidar el bundle entero.

Las `assets.paths` reales incluyen directorios de gemas —así es como `turbo.min.js` y
`stimulus.min.js` aparecen sin que vos los hayas descargado:

```text
app/assets/builds, app/assets/images, app/assets/stylesheets,
app/javascript, vendor/javascript,
.../turbo-rails-2.0.23/app/assets/javascripts,
.../stimulus-rails-1.3.4/app/assets/javascripts,
.../mission_control-jobs-1.2.0/app/assets/stylesheets, ...
```

Una gema que aporta assets es lo más parecido a un jar con recursos en `META-INF/resources`
en Spring Boot.

## 6. `importmap-rails` vs webpack / esbuild / bun

`config/importmap.rb` completo:

```ruby
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
```

Se traduce a un `<script type="importmap">` en el `<head>`, que le dice al browser cómo
resolver cada especificador de módulo. Renderizado real:

```json
{
  "imports": {
    "application": "/assets/application-bfcdf840.js",
    "@hotwired/turbo-rails": "/assets/turbo.min-9fd88cd5.js",
    "@hotwired/stimulus": "/assets/stimulus.min-4b1e420e.js",
    "@hotwired/stimulus-loading": "/assets/stimulus-loading-1fc53fe7.js",
    "controllers/application": "/assets/controllers/application-3affb389.js",
    "controllers": "/assets/controllers/index-ee64e1f1.js",
    "controllers/transfer_lines_controller": "/assets/controllers/transfer_lines_controller-eea398e7.js"
  }
}
```

El browser hace `import "@hotwired/turbo-rails"` y resuelve por ese mapa. **No hay build.**
No hay `node_modules`, no hay `package.json`, no hay Node en la imagen de producción.

**Qué ganás:**
- Cero build step. Editás un `.js` y recargás. En un backend-heavy como éste, donde el JS
  son 4 archivos, es todo ventaja.
- Cero superficie de supply chain de npm. `vendor/javascript/` está vacío acá.
- El cache del browser invalida por archivo: tocás un controller de Stimulus y los otros seis
  archivos siguen cacheados. Con un bundle, cambiar una línea invalida todo.
- Sigue habiendo auditoría: `bin/importmap audit` consulta la base de vulnerabilidades de
  npm contra tus pins. Comprobado: `No vulnerable packages found`.

**Qué perdés, y hay que decirlo sin vueltas:**
- **No hay tree shaking.** Importás una librería, va entera.
- **No hay transpilación.** Nada de TypeScript, JSX, ni sintaxis que el browser no entienda.
  Sin build step no hay dónde meter un compilador.
- **Muchos paquetes de npm no sirven.** Si el paquete asume CommonJS (`require`), resolución
  estilo Node, o hace `import` de CSS, no funciona. Se nota apenas salís de las librerías que
  publican ESM limpio.
- **Muchas requests en HTTP/1.1.** Con HTTP/2 (que Thruster te da, §30) el multiplexing lo
  hace irrelevante. Sobre HTTP/1.1 y latencia alta, un bundle gana.

**Cuándo cambiar a `jsbundling-rails` con esbuild o bun:** cuando tengas TypeScript, un
framework de componentes (React/Vue), o más de ~30 módulos propios. La migración es
mecánica y no toca el back-end. Al revés también: se puede volver.

Traducción al mundo Java: importmap es servir los `.js` directo desde `src/main/resources/static`
sin frontend-maven-plugin. Y webpack/esbuild es el frontend-maven-plugin con todo su `node_modules`
adentro del build de Maven — con la diferencia de que acá la opción sin build es de primera
clase y está soportada por el framework, no una degradación.

## 7. `turbo-rails` (2.0.23)

Tres piezas, con propósitos distintos:

- **Turbo Drive.** Intercepta clicks y submits, hace la request por `fetch`, y reemplaza el
  `<body>`. Navegación tipo SPA sin escribir JS. Se rompe con scripts que asumen
  `DOMContentLoaded` una sola vez.
- **Turbo Frames.** `<turbo-frame id="x">`: una request desde adentro del frame sólo
  reemplaza ese frame. Es un `<iframe>` que comparte estilos y no es un iframe.
- **Turbo Streams.** El servidor manda fragmentos de HTML con una acción
  (`append`, `replace`, `remove`), como respuesta a un form o empujados por WebSocket a
  través de Action Cable.

La filosofía es **HTML sobre el cable**, no JSON + render en el cliente. Para un CRUD de
stock es ideal: el servidor ya sabe renderizar, no duplicás la lógica de presentación en dos
lenguajes, y no mantenés un cliente separado.

En Java no hay equivalente por defecto. Lo más cercano es Thymeleaf + htmx (mismo espíritu:
el servidor manda HTML, el cliente lo inserta). Vaadin y JSF resuelven el mismo problema
desde el otro extremo, con estado del componente en el servidor, que es mucho más pesado.

## 8. `stimulus-rails` (1.3.4)

El complemento de Turbo: un framework de JS **modesto**, no un framework de UI. No maneja
estado, no renderiza, no hace virtual DOM. Conecta un objeto JS a un pedazo de DOM ya
renderizado por el servidor:

```html
<div data-controller="transfer-lines">
```

y Stimulus instancia `app/javascript/controllers/transfer_lines_controller.js`. Ése es el
único controller propio de esta app además del `application.js`, y es exactamente el punto:
si tenés que escribir mucho Stimulus, probablemente el problema pedía otra herramienta.

Se autoregistran por `pin_all_from "app/javascript/controllers"` más
`app/javascript/controllers/index.js`. El ciclo de vida (`connect()` / `disconnect()`) es
importante con Turbo, porque el DOM se reemplaza seguido y ahí es donde limpiás timers y
listeners.

## 9. `tailwindcss-rails` (4.6.0)

Arrastra `tailwindcss-ruby`, que no es Ruby: es un **binario standalone de 107 MB** empaquetado
como gema por plataforma.

```bash
$ du -sh .../gems/tailwindcss-ruby-4.3.3-x86_64-linux-gnu
107M
$ ls .../exe/x86_64-linux-gnu/
tailwindcss
```

Ese es todo el truco: te da Tailwind sin Node, sin npm, sin `postcss.config.js`. El flujo:

```bash
bin/rails tailwindcss:watch    # en Procfile.dev, proceso "css"
```

lee `app/assets/tailwind/application.css`, escanea tus templates para ver qué clases usás y
escribe `app/assets/builds/tailwind.css`, que Propshaft sirve con digest. En producción
corre una vez dentro de `assets:precompile` (línea del `Dockerfile`).

Las 107 MB de la gema son el costo. Está bien pagarlo en el build; molesta si tenés un caché
de gemas chico. La alternativa —Node en la imagen— pesa parecido y agrega un runtime más
que parchear.

---

# Parte IV — Boot

## 10. `bootsnap` (1.25.0)

```ruby
gem "bootsnap", require: false
```
```ruby
# config/boot.rb:4
require "bootsnap/setup"
```

Cachea dos cosas caras:

1. **Resolución de `require`.** Ruby, ante un `require "foo"`, recorre todo el `$LOAD_PATH`
   probando rutas. Con 155 gemas eso son miles de `stat()` fallidos. Bootsnap guarda el mapa
   ruta→archivo.
2. **Bytecode de YARV.** Ruby compila cada `.rb` a instrucciones de la VM en cada arranque.
   Bootsnap serializa el resultado (`ISeq`) a disco.

Medido, en este repo:

| Escenario | Tiempo |
|---|---|
| Sin bootsnap (`DISABLE_BOOTSNAP=1`), 3 corridas | 2.62 / 2.39 / 2.39 s |
| Bootsnap, cache frío (primera corrida) | **3.23 s** |
| Bootsnap, cache caliente, 3 corridas | 1.26 / 1.23 / 1.24 s |
| Tamaño de `tmp/cache/bootsnap` | 16 MB |

**~2x más rápido**, y la primera corrida es ~35% **más lenta** que sin bootsnap, porque hay
que escribir el cache. Eso importa: si tu contenedor arranca una sola vez y muere, bootsnap
te perjudica. Por eso el `Dockerfile` lo precalienta en tiempo de build:

```dockerfile
RUN bundle exec bootsnap precompile -j 1 --gemfile
RUN bundle exec bootsnap precompile -j 1 app/ lib/
```

Así el contenedor arranca con el cache ya escrito y en la imagen. Es exactamente la idea de
**AppCDS / Class Data Sharing** de la JVM: pre-parsear en build time lo que si no pagás en
cada arranque. Y el análogo del "boot cache" corrupto también existe: si ves errores
imposibles después de cambiar de rama, `rm -rf tmp/cache/bootsnap`.

---

# Parte V — Colas, cache y mensajería

## 11. `solid_queue` (1.7.0), `solid_cache` (1.0.10), `solid_cable` (4.0.2)

El stack "sin Redis" de Rails 8: los tres usan PostgreSQL, cada uno en **su propia base**
(`config/database.yml` define `primary`, `cache`, `queue`, `cable` con `migrations_paths`
separados). La razón de separarlas es sana: la carga de infraestructura tiene otro perfil de
escritura y otro vacuum que tus datos de negocio, y podés tirar la base de cache sin miedo.
El costo, dicho también: **cada base abre su propio pool por proceso**.

- **solid_queue** — backend de Active Job. Los jobs son filas; los workers hacen polling con
  `SELECT ... FOR UPDATE SKIP LOCKED`. `config/queue.yml` define tres grupos de workers
  (critical con `polling_interval: 0.1`, outbox con 0.5, y un catch-all con `"*"`). Ojo con
  ese `"*"`: el orden del array parece definir prioridad, y **con el comodín adentro no la
  define**, porque el selector colapsa a un `SELECT` sin filtro de cola ordenado sólo por
  `(priority, job_id)`. El comentario de `config/queue.yml` decía lo contrario y está
  corregido.
  `config/recurring.yml` le agrega cron: el job corre una vez aunque tengas diez servidores.
  **Y no es por elección de líder** —eso es lo que todo el mundo asume, y este documento lo
  afirmaba—. El mecanismo es más simple: cada scheduler intenta `INSERT`ar una fila en
  `solid_queue_recurring_executions`, que tiene un **índice único sobre `(task_key, run_at)`**;
  el primero gana y los demás se comen una violación de unicidad que Solid Queue traduce a
  `RecurringExecution::AlreadyRecorded`. Es el mismo truco que la idempotencia de la API: un
  índice único haciendo de lock distribuido, sin consenso ni coordinación. Vale saber la
  diferencia porque cambia el modo de falla: no hay líder que se caiga ni failover que
  esperar. Contra `crontab` en N máquinas, que ejecuta N veces, la ventaja es la misma; en
  Java es Quartz con JDBCJobStore en modo cluster, misma idea y bastante más configuración.
  (`config/initializers/solid_queue.rb` fija además `shutdown_timeout` en 25 s: el default de
  5 s corta a la mitad cualquier job que dure más en cada deploy.)
- **solid_cache** — `Rails.cache` sobre disco. `config/cache.yml` fija `max_size: 256 MB`.
  Contraintuitivo si venís de Redis: es un cache **en disco**, así que es más lento por
  lectura pero muchísimo más grande y barato, y sobrevive reinicios. Para fragmentos de HTML
  y resultados de queries, el trade-off suele ganar. Notá que `config/environments/development.rb`
  también lo usa en desarrollo, a propósito: un bug de serialización de cache que aparece
  recién en producción es lo peor.
- **solid_cable** — pub/sub de Action Cable sobre la base. Sólo en producción
  (`config/cable.yml`); en desarrollo el adapter es `async` y en test `test`.

## 12. `mission_control-jobs` (1.2.0)

El dashboard web para inspeccionar, reintentar y descartar jobs. Es el equivalente de
Sidekiq Web, o de la consola de Quartz.

Lo interesante acá es cómo se protege. `config/initializers/mission_control.rb` desactiva
el HTTP Basic que trae la gema, porque la protección real es el `constraints` de
`config/routes.rb`, que exige sesión con rol admin. El razonamiento (Basic auth no se audita
ni se revoca por persona) está en ese archivo, y ese initializer además documenta una lección
de orden de boot de Rails que vale por sí sola: `config.mission_control.jobs.*` **no funciona
desde `config/initializers/`** porque el engine copia esa config en un `before_initialize`,
que corre antes. Cuando una opción de configuración "no toma", eso es lo primero que mirás
(`bin/rails initializers` te da el orden real).

## 13. `sidekiq` (8.1.7) + `redis` (5.4.1)

Están en el `Gemfile` como **alternativa deliberada**, para poder correr los mismos jobs
sobre otro backend cambiando una variable:

```bash
QUEUE_ADAPTER=sidekiq bin/rails s
```

Ése es el punto de Active Job: es una SPI, igual que JMS abstrae ActiveMQ de RabbitMQ. Tu
código depende de `ActiveJob::Base`, no del backend. Fijate la asimetría en el `Gemfile`:
`sidekiq` va con **`require: false`** (§1.5) y `redis` no, porque a `redis` la usa además
`Rack::Attack` para el store de contadores.

La tabla comparativa completa (latencia, throughput, durabilidad, transaccionalidad) está en
`config/initializers/sidekiq.rb`; no la repito, pero **leele la fila "Transaccional" con el
matiz de abajo puesto**. Lo que sí conviene agregar, porque es lo que se pregunta:

**El punto transaccional es el que decide.** Con Sidekiq, `perform_later` escribe en Redis
*ya*; si tu transacción hace rollback después, el job quedó encolado para una fila que no
existe.

Acá venía la afirmación que **todo el mundo repite y que en este repo era falsa**: "con Solid
Queue el `INSERT` del job va en tu misma transacción y el problema desaparece por
construcción". Es cierto **sólo si la cola comparte base con tus datos**. Y no la comparte:

```ruby
# config/initializers/active_job.rb:38
config.solid_queue.connects_to = { database: { writing: :queue } }
```

`stock_development_queue` es **otra base, otra conexión, otra transacción**: un rollback de tu
transacción de negocio deja el job encolado igual. La demostración corrida (encolar dentro de
una transacción que después revienta, y contar `SolidQueue::Job`) está en docs/07. La
conclusión: el argumento transaccional de Solid Queue es real, pero es una propiedad de la
**topología de bases**, no de la gema.

Lo que sí arregla el rollback en los dos backends es `enqueue_after_transaction_commit`
(Rails 7.2+), y ahí hubo un segundo bug, de los buenos. Estaba escrito así:

```ruby
# config/initializers/sidekiq.rb — ASÍ ESTABA, y era un NO-OP
Rails.application.config.active_job.enqueue_after_transaction_commit = :always
```

Parecía configurado y no lo estaba. En Rails 8.1 el railtie de Active Job **excluye esa clave**
de la config global ("this config can't be applied globally") y además el valor `:always`
se removió: la línea se descartaba en silencio, que es el peor resultado posible. Se
comprueba en una línea, y por eso conviene leer el valor efectivo y no el initializer:

```ruby
ActiveJob::Base.enqueue_after_transaction_commit   # => lo que realmente rige
```

Hoy está donde corresponde, **por clase de job**, en `app/jobs/application_job.rb`:

```ruby
class ApplicationJob < ActiveJob::Base
  self.enqueue_after_transaction_commit = true
```

Y el matiz que separa una respuesta buena de una excelente: eso **no reemplaza al outbox**.
Si el proceso muere entre el COMMIT y el enqueue —microsegundos, pero existen— el job se
pierde y nadie se entera. Para eventos que no se pueden perder, outbox (por eso este repo
tiene `outbox_events` y `Outbox::PublishPendingJob`). Para "mandale un mail", `enqueue_after_transaction_commit`
alcanza. Saber dónde está esa línea es la respuesta madura a "¿cuándo usarías un outbox?".

Costo de tenerlo en el `Gemfile` sin usarlo: durante un buen rato Sidekiq se cargó en
**todos** los procesos aunque el adapter fuera `solid_queue` (§1.4 lo medía:
`sidekiq cargado? SI`). Ya no: la declaración es `gem "sidekiq", "~> 8.0", require: false` y
la misma comprobación devuelve `NO`. El `require "sidekiq"` real lo hace
`config/initializers/sidekiq.rb:36`, sólo cuando `QUEUE_ADAPTER == "sidekiq"`.

---

# Parte VI — Seguridad y acceso

## 14. `bcrypt` (3.1.22)

Lo usa `has_secure_password` en `app/models/user.rb:10`. Medido acá:

```text
cost por defecto (BCrypt::Engine.cost): 12
cost del digest realmente guardado:     12
tiempo de un hash:                      233 ms
```

233 ms **es la feature, no el bug**. bcrypt es deliberadamente lento para que un atacante con
tu tabla de usuarios no pueda probar millones de passwords por segundo. Cada `+1` de cost
duplica el tiempo.

Dos consecuencias operativas que casi nadie piensa:

1. **Un login cuesta 233 ms de CPU.** Un flood de logins es un vector de DoS aunque todos
   fallen. Por eso `Rack::Attack` limita `/session` aparte, y por eso el rate limiting va
   antes del controller.
2. **Pero no bloquea el proceso**, porque —medido en §3.1— bcrypt **libera el GVL**: 8 hashes
   en 8 threads tardaron 0.49 s contra 1.87 s secuencial en 4 cores. Otros threads de Puma
   siguen sirviendo requests mientras uno hashea. Este es exactamente el tipo de detalle que
   distingue "leí sobre el GVL" de "lo entiendo".

En test no hay que configurar nada: el railtie de ActiveModel
(`active_model/railtie.rb:18`) hace `ActiveModel::SecurePassword.min_cost = Rails.env.test?`,
así que el digest se genera con `BCrypt::Engine::MIN_COST` (4) en vez de 12. Sin eso, cada
`create(:user)` de la suite costaría 233 ms.

Java: `BCryptPasswordEncoder` de Spring Security, misma primitiva y mismo parámetro
(`strength`). La diferencia real es que en Rails viene enchufado en el modelo con una línea y
no tenés que declarar un bean.

## 15. `pundit` (2.5.2) vs `cancancan`

```ruby
# app/controllers/api/v1/base_controller.rb:17
include Pundit::Authorization
```

Pundit: **una clase por recurso, un método por acción**. `app/policies/` tiene diez archivos:
`ApplicationPolicy` más nueve policies de recurso.
`ApplicationPolicy` define los defaults y la clase anidada `Scope` filtra colecciones.

| | Pundit | CanCanCan |
|---|---|---|
| Estructura | una policy por recurso | **una** clase `Ability` para toda la app |
| Filtrar colecciones | `Scope#resolve`, escribís el scope | `accessible_by`, lo deriva del DSL |
| Escala | crece en archivos | crece en una clase gigante |
| Testeo | POROs, test unitario puro | hay que armar la Ability entera |
| Magia | ninguna, es una clase | el DSL genera SQL desde las condiciones |

CanCanCan es más rápido para arrancar y su `accessible_by` es genuinamente cómodo. El
problema aparece a los dos años: la `Ability` es un god object de 400 líneas con condicionales
por rol, imposible de leer y con las reglas de siete recursos entrelazadas. Pundit te obliga
a la explicitud desde el día uno, y en un dominio con roles jerárquicos (`admin > manager >
operator > viewer`, como acá) eso paga.

Dos detalles de Pundit que son los que evitan agujeros de verdad:

- **`verify_authorized` / `verify_policy_scoped`** en un `after_action`: si te olvidaste de
  autorizar una acción, te avisa. En este repo hay un rescue explícito que en dev/test
  **levanta la excepción** y en producción loguea `security.authorization_missing`
  (`app/controllers/api/v1/base_controller.rb`, cerca de la línea 125).
- **`Scope#resolve` devuelve `scope.none` por defecto** (`app/policies/application_policy.rb`).
  Fallar cerrado. Autorizar el `show` no sirve de nada si el `index` lista todo, y ese es un
  bug de autorización clásico y muy común.

Java: `@PreAuthorize("hasRole('X')")` de Spring Security es la anotación; Pundit se parece
más a un `PermissionEvaluator` por tipo de dominio. La ruptura de la analogía: la anotación
de Spring se evalúa por AOP automáticamente, y `authorize` en Rails es **una llamada
explícita que te podés olvidar**. De ahí que `verify_authorized` no sea opcional.

## 16. `rack-attack` (6.8.0)

Middleware Rack — o sea, un `javax.servlet.Filter`. Cuatro primitivas: `safelist`,
`blocklist`, `throttle`, `track`. El razonamiento completo (por qué en el borde y no en el
controller, por qué el store importa, por qué `track` antes de `throttle`) está en
`config/initializers/rack_attack.rb`.

Lo que agrego acá es una observación de la ejecución real, que además destapó un bug.
**Así se veía `bin/rails middleware` antes:**

```text
use ActionDispatch::RemoteIp
use Rack::Attack          <- el nuestro (insert_after)
use Propshaft::QuietAssets
...
use Rack::TempfileReaper
use Rack::Attack          <- ¿¿otro??
use Bullet::Rack
```

**Rack::Attack aparecía dos veces.** El motivo es que la gema trae un railtie que se agrega
sola al final del stack:

```ruby
# rack-attack-6.8.0/lib/rack/attack/railtie.rb:12
initializer "rack-attack.middleware" do |app|
  app.middleware.use(Rack::Attack)
end
```

y `config.middleware.insert_after ActionDispatch::RemoteIp, Rack::Attack` insertaba una
**segunda** copia más arriba, para que corriera después de que `RemoteIp` resuelva el
`X-Forwarded-For`.

El instinto correcto es "esto cuenta cada request dos veces y mi límite real es la mitad".
Fui a leer la gema, y no:

```ruby
# rack-attack-6.8.0/lib/rack/attack.rb:104
def call(env)
  return @app.call(env) if !self.class.enabled || env["rack.attack.called"]
  env["rack.attack.called"] = true
  ...
```

La propia gema se defiende con un flag en el `env`, así que la segunda instancia era un no-op
funcional: no había doble conteo. Pero sí era un frame de Rack inútil en cada request y, peor,
una trampa para cualquiera que leyera el stack.

**Cómo quedó.** El arreglo es una palabra, `move_after` en vez de `insert_after`
(`config/application.rb`):

```ruby
config.middleware.move_after ActionDispatch::RemoteIp, Rack::Attack
```

`move_after` **mueve el que el railtie ya montó** en vez de agregar otro. Y el intento obvio
—`delete` seguido de `insert_after`— **no sirve**: las operaciones sobre el stack se acumulan
y se aplican en orden al construirlo, así que el `delete` puede llevarse justo el middleware
que vos insertaste y dejarte sin ninguno. Un rate limiter que desaparece del stack es un
fallo de seguridad silencioso, que es exactamente el tema de este documento.

Comprobado hoy con `bin/rails middleware`, y ahora aparece una sola vez y en el lugar correcto:

```text
use ActionDispatch::RequestId
use ActionDispatch::RemoteIp
use Rack::Attack          <- una sola, y después de RemoteIp
use Propshaft::QuietAssets
```

La moraleja se sostiene igual: **verificá el orden del stack con `bin/rails middleware`, no lo
supongas**. Un rate limiter arriba de `RemoteIp` cuenta todas las requests contra la IP del
balanceador, y el primero que haga 300 pedidos deja afuera a todo el mundo.

Segunda capa: `rate_limit` nativo de Rails 8, en el controller, con contexto de negocio
(por usuario, por plan). Está en `app/controllers/api/v1/base_controller.rb`, y ahí también
está documentada la trampa más peligrosa de todo el tema: **un rate limiter sobre un
`NullStore` no limita nada y no avisa**, porque `increment` devuelve `nil` y la comparación
nunca se cumple. Es un fallo silencioso de seguridad. Por eso `RATE_LIMIT_STORE`
(línea 46) elige el store explícitamente y loguea un warning si le tocó uno inservible.

---

# Parte VII — Datos y performance

## 17. `oj` (3.17.6) — la gema de performance que no serializaba un solo byte

La justificación estándar de `oj` es "parser JSON en C, reemplaza el de la stdlib, free win
en APIs con payloads grandes". La fui a verificar y me encontré con **el mejor bug del repo**:
la gema estaba instalada, cargada en todos los procesos, sumando RAM... y **desenchufada**.

**Así se veía.** Comprobado en la consola de aquel momento:

```ruby
defined?(Oj)                                    # => "constant"   (cargada)
ActiveSupport::JSON::Encoding.json_encoder      # => ActiveSupport::JSON::Encoding::JSONGemEncoder
```

`render json:` usa `ActiveSupport::JSON.encode`, que usa el encoder que diga
`ActiveSupport::JSON::Encoding.json_encoder`. Oj **no se engancha solo**: hace falta
`Oj.optimize_rails` (o `Oj::Rails.set_encoder`) en un initializer, y ese archivo no existía.
`grep -rn "Oj" app/ config/ lib/` no devolvía **nada**. O sea: pagabas la memoria y no te
llevabas la velocidad. Síntoma: ninguno. Ése es exactamente el problema —una optimización
apagada no rompe nada, sólo no sirve—.

**Cómo quedó.** Se agregó `config/initializers/oj.rb`:

```ruby
require "oj"

Oj.default_options = { mode: :rails }
Oj.optimize_rails
```

y ahora la misma comprobación devuelve otra cosa:

```ruby
ActiveSupport::JSON::Encoding.json_encoder      # => Oj::Rails::Encoder
```

`mode: :rails` **no es opcional**: los otros modos (`:compat`, `:object`, `:strict`)
serializan distinto las fechas y los `BigDecimal`, o sea que te cambian el contrato de la API
en silencio. Cambiar de serializador JSON no es una optimización interna, es un cambio de
formato de salida.

**Y ahora la parte que importa: ¿cuánto ganás?** Medido en este repo, comparando el encoder de
hoy contra el que estaba antes (con calentamiento previo, forzando `json_encoder` a mano para
comparar los dos en el mismo proceso):

```text
json gem: 2.21.2 / oj: 3.17.6 / ruby 3.3.6

  una PÁGINA de la API (25 objetos, el caso real acá)
    Oj::Rails::Encoder (hoy)          0.082 ms/iter
    JSONGemEncoder (el de antes)      0.212 ms/iter

  un export grande (5000 objetos)
    Oj::Rails::Encoder (hoy)         15.95  ms/iter
    JSONGemEncoder (el de antes)     41.49  ms/iter
```

~2.6x, consistente en los dos tamaños. Pero mirá los valores absolutos y sacá la conclusión
honesta: en una página de 25 objetos ganás **0.13 ms** sobre una request que cuesta varios
milisegundos entre SQL, autorización y middleware. Es ruido. En un export de 5000 objetos
ganás 25 ms, y ahí sí empieza a valer. Por eso el comentario del `Gemfile` ahora aclara que
**la ganancia depende del tamaño del payload**, en vez de venderla como un free win.

Dos cosas más para no sacar la conclusión equivocada:

- El `json` de la stdlib **no es el que era**. Entre 2023 y 2025 se reescribió y se optimizó
  fuerte: acá corre 2.21.2 (Bundler sombrea la 2.7.2 que trae Ruby 3.3, ver §31), y por eso
  `JSON.generate` a secas es competitivo. Buena parte de la ventaja histórica de Oj se evaporó;
  lo que queda es que `JSONGemEncoder` de ActiveSupport hace bastante trabajo Ruby encima del
  `json` puro, y **eso** es lo que Oj se saltea.
- Medir `Oj.dump(...)` suelto no te dice nada sobre tu app. Lo que corre en producción es
  `ActiveSupport::JSON.encode` a través del `json_encoder` configurado, y `Oj.optimize_rails`
  además parchea `to_json`/`as_json`. Benchmarkeá **el camino real**, no la función de la gema.

**La lección, que vale más que la gema:** una dependencia que entró por una razón de
performance necesita dos verificaciones, no una. Primero **que esté enganchada** —lo obvio, y
lo que faltaba acá—, y después **que la razón siga siendo cierta**, porque el consejo de 2016
sigue circulando en blogs y en Stack Overflow mucho después de haber dejado de aplicar. El
comando que las cubre a las dos es una línea, y conviene tenerlo a mano antes de una
entrevista sobre tu propio repo:

```ruby
ActiveSupport::JSON::Encoding.json_encoder   # => Oj::Rails::Encoder
```

## 18. `pagy` (9.4.0) vs `kaminari` vs `will_paginate`

| | pagy | kaminari | will_paginate |
|---|---|---|---|
| Cómo se usa | `pagy(scope)` → `[pagy, records]` | `scope.page(n).per(m)` | `scope.paginate(page:, per_page:)` |
| Toca ActiveRecord | **no** | sí, agrega scopes a `Relation` | sí |
| Objeto que crea | un PORO chico | objetos + vistas de Rails | idem |
| Sacarlo del proyecto | tocás los controllers | refactor grande | refactor grande |
| Vistas | helpers, opt-in | genera partials que overrideás | helpers |

La razón principal por la que pagy gana no es la velocidad —aunque sea más liviana—, es
**que no se inyecta en ActiveRecord**. Kaminari y will_paginate agregan métodos a
`ActiveRecord::Relation`; una vez que `.page` está disponible en toda la app, aparece en 200
lugares y sacarlo es un proyecto. Pagy es un objeto que construís y le pasás un scope: la
dependencia queda contenida en la capa de controllers. Es el criterio §1.8.4 en acción.

Cómo se usa acá: `include Pagy::Backend` en `app/controllers/api/v1/base_controller.rb:18`,
`include Pagy::Frontend` en `app/helpers/application_helper.rb:4`.

`config/initializers/pagy.rb` fija lo importante:

```ruby
Pagy::DEFAULT[:limit] = 25
Pagy::DEFAULT[:max_limit] = 100        # <- sin esto, ?limit=100000 te tumba el proceso
Pagy::DEFAULT[:overflow] = :last_page  # ?page=9999 devuelve la última, no un 500
Pagy::DEFAULT[:headers] = { page: "Current-Page", limit: "Page-Items",
                            count: "Total-Count", pages: "Total-Pages" }
```

Ese `max_limit` es una regla de seguridad, no de UX: **cualquier parámetro de paginación que
venga del usuario tiene que estar acotado**, o te lo usan como vector de DoS. Y no queda
delegado sólo a pagy: `Api::V1::BaseController#paginate` acota el `limit` que llega por
`params` antes de pasárselo, con `MAX_PAGE_SIZE = 100` y un `page_limit` que hace
`Integer(params[:limit]).clamp(1, MAX_PAGE_SIZE)`. Dos cotas para lo mismo no es redundancia
inútil: la del controller es la que sobrevive si mañana alguien pagina a mano.

**Corrección al comentario del `Gemfile`, que estuvo mal escrito.** Ahí se leía que pagy
"no hace `COUNT(*)` si no se lo pedís". Instrumenté las queries y es al revés:

```ruby
pagy, recs = pagy(Product.all)
```
```sql
SELECT COUNT(*) FROM "products"
SELECT "products".* FROM "products" LIMIT 25 OFFSET 0
```

El `pagy` por defecto **sí cuenta**, porque necesita `pages` y `count` para armar la
paginación (y para las cabeceras `Total-Count` / `Total-Pages` que expone este repo). Lo que
evita el COUNT es el extra `countless`, que hay que requerir explícitamente
(`require "pagy/extras/countless"`, y usar `pagy_countless`); comprobado que en este repo
**no** está cargado —el initializer sólo requiere `overflow` y `headers`—. El comentario del
`Gemfile` ya dice esto último, que es lo correcto. La moraleja es aburrida y útil: **un
comentario sobre qué SQL emite una gema se verifica suscribiéndose a `sql.active_record`, no
recordando la documentación.**

Y cuando el COUNT y el OFFSET duelen de verdad —tablas grandes—, la salida no es una gema
sino cambiar de técnica: **keyset pagination** (cursor). Es lo que hace el ledger acá, porque
`stock_movements` sólo crece:

```ruby
# app/controllers/api/v1/stock_movements_controller.rb:5
# El ledger. Se pagina por KEYSET (cursor), no por offset.
```
```ruby
next_cursor: movements.size < requested_limit ? nil : StockMovements::Ledger.encode_cursor(movements.last)
```

El motivo es de base de datos, no de Ruby: `OFFSET 100000` obliga a Postgres a leer y
descartar 100.000 filas, así que la página N cuesta O(N). Con un cursor sobre un índice, cada
página cuesta lo mismo. Y hay un bonus de corrección: con offset, si insertan filas mientras
paginás, ves registros repetidos o te salteás alguno. Con keyset no.

Java: `Pageable`/`Page` de Spring Data es offset y hace el `count` igual; `Slice` es el que
lo evita. Misma disyuntiva, otros nombres.

## 19. `strong_migrations` (2.8.0)

Falla **en desarrollo** si escribís una migración que en producción tomaría un lock largo.
Lo verifiqué de verdad, corriendo una migración de prueba adentro de una transacción con
rollback:

```ruby
add_index :products, :name
```
```text
CLASE: StrongMigrations::UnsafeMigration

=== Dangerous operation detected #strong_migrations ===

Adding an index non-concurrently blocks writes. Instead, use:

class ... < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :products, :name, algorithm: :concurrently
  end
end
```

Funciona y te da el arreglo escrito. Ésta es la gema que más impresiona en una entrevista
senior, porque demuestra que pensás en el deploy y no sólo en el schema.

El problema que resuelve es específico de Postgres y no lo tenés en la cabeza si venís de
Hibernate con `ddl-auto`: **un `ALTER TABLE` toma un `ACCESS EXCLUSIVE` lock**, y ese lock
no sólo bloquea escrituras, bloquea **lecturas** y encima **se encola**: si hay una query
larga corriendo, tu ALTER espera, y todas las queries que llegan después esperan detrás de
él. Una migración "instantánea" tira el sitio abajo por dos minutos. Lo detecta para
`add_index` sin `CONCURRENTLY`, `remove_column`, cambios de tipo, `NOT NULL` sin constraint
previa, backfills en la misma migración, `add_reference` con índice, y más.

Config real de este repo, leída del proceso (la fija `config/initializers/strong_migrations.rb`):

```ruby
StrongMigrations.start_after        # => 20260830161300
StrongMigrations.target_version     # => 16
StrongMigrations.lock_timeout       # => 10 seconds
StrongMigrations.statement_timeout  # => 1 hour
StrongMigrations.safe_by_default    # => false
```

Las cuatro que están puestas son exactamente las que hay que poner, y cada una arregla un
problema distinto:

- **`start_after`** es lo primero que necesitás al instalar la gema en un proyecto que ya
  tiene migraciones: sin eso analiza también las viejas —que ya corrieron— y no te deja
  bootear. Se pone el timestamp de la última migración existente.
- **`target_version`** es la versión de Postgres de **producción**, no la de tu máquina. Lo
  que es peligroso depende de la versión: agregar una columna con default reescribía la tabla
  antes de PG 11 y es instantáneo desde PG 11. Sin ese dato la gema es conservadora de más.
  Acá vale 16 (`ENV.fetch("PG_TARGET_VERSION", 16)`).
- **`lock_timeout = 10.seconds`** es lo que evita la caída en cascada: si la migración no
  consigue el lock en 10 segundos, aborta en vez de quedarse encolada bloqueando a todo lo
  que viene atrás.
- **`statement_timeout = 1.hour`** acota la migración en sí, que es un límite distinto del
  anterior: uno es "cuánto espero el lock", el otro "cuánto puedo tardar teniéndolo".

La que queda en su default es **`safe_by_default = false`**: la gema te frena y te escribe
el reemplazo seguro, pero no lo aplica sola. Ponerla en `true` haría que, por ejemplo,
`add_index` se convierta solo en `algorithm: :concurrently`. Es cómodo y es discutible:
esconde la decisión en vez de obligarte a tomarla. Con un equipo que recién arranca con
Postgres, prendela; con gente que ya sabe, dejala apagada.

Ojo con `safety_assured { ... }`: existe para saltarse un chequeo cuando sabés lo que hacés.
Cada uso necesita un comentario que explique por qué es seguro **en esta tabla y con este
volumen**, o se convierte en ruido que todos copian y pegan.

---

# Parte VIII — Testing

## 20. `rspec-rails` (8.0.4) vs Minitest

Minitest **viene con Rails** y es lo que usa el core del framework. RSpec es lo que usa la
mayoría del ecosistema. Elegimos RSpec, y `config/application.rb:15` deja la decisión
explícita comentando `require "rails/test_unit/railtie"`.

| | Minitest | RSpec |
|---|---|---|
| Instalación | ya está | 5 gemas (`rspec-core/expectations/mocks/support/rails`) |
| Sintaxis | `assert_equal a, b`, clases y métodos | `expect(a).to eq(b)`, `describe`/`context`/`it` |
| Velocidad de arranque | más rápida | más lenta (más código que cargar) |
| Ecosistema | menor | enorme (shoulda-matchers, factory_bot, vcr, todos apuntan a RSpec) |
| Java análogo | JUnit "pelado" | JUnit + AssertJ + Mockito + BDD |

**Cuándo cada uno**, sin ideología: si es una gema, o un equipo que valora dependencias
mínimas y velocidad, Minitest. Si es una app de negocio con muchos casos y contextos, RSpec:
`context "cuando el stock reservado supera el disponible"` documenta el caso en la salida del
test, y con `--format documentation` (que está en `.rspec`) la suite se lee como una
especificación.

Cuatro decisiones de `spec/spec_helper.rb` que valen más que la elección de framework:

```ruby
mocks.verify_partial_doubles = true   # mockear un método inexistente FALLA el test
config.disable_monkey_patching!       # nada de `describe` global; RSpec.describe explícito
config.order = :random                # orden aleatorio
Kernel.srand config.seed              # ...pero reproducible con --seed
```

`verify_partial_doubles` es lo más cerca que tenés de un compilador avisándote: sin eso,
renombrás un método, el doble sigue respondiendo el nombre viejo, el test pasa en verde y
producción explota. Es el equivalente de los *strict stubs* de Mockito.

El orden aleatorio es innegociable: si tus tests dependen del orden, tenés estado compartido
y no lo sabés.

Y la separación `spec_helper.rb` (sin Rails) / `rails_helper.rb` (con Rails) es real y
paga: los specs de `Result` y de los Value Objects arrancan sin cargar el framework.

## 21. `factory_bot_rails` (6.5.1) vs fixtures

| | Fixtures (Rails) | factory_bot |
|---|---|---|
| Qué son | YAML → `INSERT` directo | objetos construidos por ActiveRecord |
| Validaciones/callbacks | **se saltean** | corren |
| Velocidad | muy rápida | más lenta |
| Alcance | globales, cargadas para toda la suite | por ejemplo, explícitas |
| Legibilidad | tenés que ir al YAML a ver qué es `products(:one)` | `create(:product, sku: "X")` dice todo |
| Java análogo | dataset de DBUnit | Object Mother / Test Data Builder |

El argumento decisivo no es la velocidad: es que **con fixtures el test no dice de qué
depende**. `products(:one)` te obliga a abrir otro archivo, y cuando alguien le cambia un
campo para arreglar su test, rompe otros cinco. Con una factory, cada ejemplo declara los
atributos que le importan y hereda el resto:

```ruby
create(:stock_item, quantity_on_hand: 10)   # sólo me importa el 10
```

`config.include FactoryBot::Syntax::Methods` en `spec/rails_helper.rb` permite `create(...)`
sin el prefijo `FactoryBot.`.

Tres cosas que separan una suite sana de una lenta:

- **`build_stubbed` > `build` > `create`.** `create` va a la base; `build` instancia en
  memoria; `build_stubbed` instancia con un id falso y sin tocar la base. Si tu test no
  necesita persistencia, `create` es plata tirada.
- **`FactoryBot.lint`**, configurado en `spec/support/factory_bot.rb`: verifica que **todas**
  las factories generen objetos válidos. Corre con `LINT_FACTORIES=1 bundle exec rspec`.
  Sin esto, una factory rota se descubre seis meses después cuando agregás un test nuevo y no
  entendés por qué falla. Acá encontró una de verdad, y la causa es una que sorprende: los
  **traits automáticos de enum**. Desde factory_bot 6.x,
  `automatically_define_enum_traits` viene en `true` y la gema inventa un trait por cada valor
  de cada `enum` de ActiveRecord. Esos traits **ignoran las invariantes del modelo**: generaba
  un `stock_reservation` con status `expired` pero sin `released_at`, que viola el CHECK
  constraint `stock_reservations_released_at_present`, y el lint reventaba con
  `PG::CheckViolation` por traits que nadie había escrito. Peor todavía, colisionaban en
  silencio con los traits propios (la factory `:stock_movement` tenía `issue` dos veces y cuál
  ganaba dependía del orden de carga). Hoy `spec/support/factory_bot.rb` los apaga con
  `FactoryBot.automatically_define_enum_traits = false` y los estados que hacen falta están
  escritos a mano en `spec/factories/stock.rb`, con todos los campos que la máquina de estados
  exige. Que es justamente lo que querés en un dominio con invariantes.
- **Cuidado con las asociaciones.** Una factory que crea asociaciones que crean asociaciones
  termina insertando 30 filas para probar una suma. Se controla con traits y con
  `association ..., strategy: :build`.

Y notá que `config.fixture_paths` sigue configurado en `spec/rails_helper.rb`: las dos cosas
conviven, no son excluyentes.

## 22. `faker` (3.8.0)

Datos falsos: nombres, SKUs, direcciones, emails. Tres advertencias que valen más que la
descripción:

1. **No lo uses para valores sobre los que hacés aserciones.** `expect(product.name).to eq(...)`
   con un nombre de Faker es un test que se documenta a sí mismo mal. Faker es para *relleno*
   —campos que tienen que existir y no importan—; los valores que importan van escritos a mano.
2. **`Faker::X.unique` acumula estado entre ejemplos** y eventualmente tira
   `RetryLimitExceeded`. Se limpia con `Faker::UniqueGenerator.clear`. Para unicidad de
   verdad, `sequence` de factory_bot es más confiable.
3. Con `Kernel.srand config.seed` (§20), Faker queda sembrado y **reproducible**: si un test
   falla sólo con ciertos datos, `--seed N` te lo reproduce. Eso convierte un flake en un bug
   arreglable.

Java: es un DataFaker / javafaker. Misma gema, mismos problemas.

## 23. `shoulda-matchers` (6.5.0)

Matchers declarativos para validaciones y asociaciones de ActiveRecord:

```ruby
it { is_expected.to validate_presence_of(:sku) }
it { is_expected.to have_many(:stock_items).dependent(:restrict_with_error) }
```

Una línea que hace lo que a mano son seis (instanciar, dejar el campo nulo, validar, chequear
el error). Config en `spec/support/shoulda.rb`.

La objeción legítima: esto testea **la declaración**, no el comportamiento. `validate_presence_of`
verifica que escribiste `validates :sku, presence: true`, que es casi tautológico. Sirve como
red de seguridad barata contra borrados accidentales de validaciones. Las **reglas de negocio**
—que un movimiento no deje el stock negativo, que una reserva expire— se testean con
ejemplos reales, y ahí sí no hay matcher que valga.

## 24. `simplecov` (1.1.1)

Cobertura de línea **y de rama**. JaCoCo, básicamente. En `spec/spec_helper.rb`:

```ruby
require "simplecov"           # <- ANTES de cargar cualquier código de la app
SimpleCov.start "rails" do
  enable_coverage :branch
  add_filter "/spec/" ; add_filter "/config/" ; add_filter "/db/"
  add_group "Services", "app/services"
  # ...
  minimum_coverage line: 70, branch: 45
end if ENV["COVERAGE"]
```

Dos cosas que importan:

- **El orden de carga no es negociable.** SimpleCov instala el hook de cobertura de Ruby;
  todo lo que se cargó antes no queda registrado y la cobertura sale artificialmente baja.
  Por eso es el primer `require` del archivo.
- **`enable_coverage :branch`**. "La línea se ejecutó" no dice nada de un `if`: con cobertura
  de línea un ternario cuenta como cubierto habiendo probado una sola rama. Es la diferencia
  entre `LINE` y `BRANCH` en JaCoCo, y es la métrica que sirve.
- Los umbrales (70/45) son bajos a propósito. 100% obliga a escribir tests basura para tapar
  líneas triviales; 0 hace que la métrica no exista. Y está detrás de `ENV["COVERAGE"]` para
  no pagar el costo del instrumentado en cada corrida local.

## 25. `webmock` (3.26.4) y `vcr` (6.4.0)

**WebMock** es WireMock: intercepta todo el HTTP saliente. Lo importante es lo que hace
cuando *no* configuraste un stub: revienta el test con un mensaje que te dice exactamente qué
request se intentó. Sin esto, tu suite sale a internet y es lenta, no determinística y falla
cuando el proveedor tiene un mal día.

**VCR** es la capa de arriba: la primera vez deja pasar la request real y **graba** la
interacción en un "cassette" YAML; después la reproduce. Sirve para APIs de terceros con
respuestas grandes que no querés escribir a mano.

Tres trampas de VCR, en orden de gravedad:

1. **Los cassettes se commitean, y guardan headers.** `Authorization: Bearer ...` queda en
   git. Se arregla con `config.filter_sensitive_data("<TOKEN>") { ENV["API_TOKEN"] }`, y hay
   que ponerlo **antes** de grabar el primer cassette.
2. **Los cassettes envejecen.** El proveedor cambia su API, tu test sigue verde contra una
   respuesta de hace dos años. Conviene re-grabarlos periódicamente (`:record => :new_episodes`
   en una corrida programada) y no confiar en ellos como contrato.
3. **Los cassettes son enormes** y ensucian los diffs. Grabá el mínimo, no la sesión entera.

Regla práctica: WebMock para lo que escribís vos (stubs cortos y explícitos), VCR sólo para
integraciones de terceros con payloads grandes.

## 26. `capybara` (3.40) + `selenium-webdriver` (4.48) + `cuprite` (0.17)

Capybara es el **DSL** (`visit`, `fill_in`, `click_button`); el **driver** es quien habla con
el browser. Los tres que importan:

| Driver | Cómo habla | Necesita | Ejecuta JS |
|---|---|---|---|
| `:rack_test` | ninguno, parsea el HTML en proceso | nada | **no** |
| `:cuprite` | Chrome DevTools Protocol, directo | Chromium | sí |
| `:selenium` | WebDriver (W3C) | Chromium **+ chromedriver** | sí |

La diferencia práctica es el `chromedriver`: su versión **mayor** tiene que coincidir con la
del Chrome instalado, y Chrome se autoactualiza solo. Es la causa número uno de "el CI se
rompió y nadie tocó nada". Cuprite habla CDP directo y elimina la pieza intermedia.

En este entorno el problema es literal y está documentado en `spec/support/capybara.rb`:
**Chromium 141 contra ChromeDriver 147**. Por eso ese archivo registra sólo dos:
`driven_by :rack_test` para los system specs sin JS y `driven_by :cuprite` para los marcados
`js: true`. `selenium-webdriver` sigue en el `Gemfile` —es lo que vas a encontrar en la
mayoría de los proyectos, y es el único que maneja Firefox y Safari— pero **no está
enganchado en la suite**: si lo querés usar, hay que agregar el `driven_by :selenium`.

El otro problema, más profundo, también está explicado ahí: **el servidor de test corre en
otro thread con otra conexión**, y con transactional fixtures los datos del ejemplo están en
una transacción sin commitear que ese thread no ve. Rails lo resuelve compartiendo la
conexión entre threads, funciona, y es el origen de la mayoría de los system tests flakey.
La alternativa robusta es desactivar transacciones y truncar, que es lo que hacen los specs
de concurrencia (`spec/support/concurrency.rb`, `spec/integration/concurrency_spec.rb`).

Y la regla de dosificación: **un puñado de system tests bien elegidos > cincuenta**. Un
request spec es 20 veces más rápido y mucho más fácil de debuggear. El system test se
justifica cuando lo que probás *es* la integración browser + JS + servidor.

Java: Capybara ≈ Selenium WebDriver + el DSL que le armás encima; cuprite ≈ Playwright, que
también habla CDP y por eso arranca más rápido y es más estable.

---

# Parte IX — Calidad y diagnóstico

## 27. Análisis estático y auditoría

Las tres que corren en CI (`config/ci.rb`) van con `require: false` y nunca se cargan dentro
de la app: `rubocop`, `brakeman` y `bundler-audit`. `bullet` es la excepción, y conviene
mirarla de cerca: el bug que tuvo es el más instructivo del repo.

**`bullet` (8.2.0) — la red de seguridad que no atrapaba nada.** Detector de N+1 y de eager
loading innecesario. Se declara **sin** `require: false` porque
tiene que parchear ActiveRecord; en desarrollo aparece como `Bullet::Rack` en el stack de
`bin/rails middleware`.

**Así estaba.** La gema se declaraba **sólo en `group :development`**, y la intención de
`spec/support/bullet.rb` era que un N+1 rompiera la suite:

```ruby
Bullet.raise = true                        # el N+1 ROMPE el test
Bullet.unused_eager_loading_enable = true  # detecta el problema INVERSO
```

**Ese archivo no hacía nada.** Tanto él como el hook de `spec/rails_helper.rb` estaban
guardados con `if defined?(Bullet)`, y en el entorno de test la constante no existía:

```text
$ RAILS_ENV=test bin/rails runner 'p Rails.groups; p Object.const_defined?(:Bullet)'
[:default, "test"]
false
```

`Bundler.require(*Rails.groups)` carga `:default` + el grupo del entorno; con `bullet` sólo en
`:development`, en test nunca se hacía el `require`, el `defined?` daba falso y toda la
configuración se salteaba en silencio. Los ejemplos marcados `:n_plus_one` pasaban en verde
**hubiera o no un N+1**. Es la peor clase de bug de testing: un chequeo verde que no verifica
nada es peor que no tener chequeo, porque te saca las ganas de mirar. Y es el mismo patrón que
el `require` condicional de sidekiq de §1.5: **una configuración partida entre el `Gemfile` y
otro archivo no hace nada si sólo escribís una mitad.**

**Cómo quedó.** Cuatro cambios, y el obvio es sólo el primero:

1. **`Gemfile`:** `group :development, :test do` para bullet. Hoy
   `RAILS_ENV=test ... Object.const_defined?(:Bullet)` devuelve `true`.
2. **La configuración se mudó a `config/environments/test.rb`**, dentro de un
   `after_initialize`. No es cosmético: `Bullet.enable = true` **aplica los parches sobre
   ActiveRecord en el momento de la asignación**, así que hacerlo desde un `before(:suite)` de
   RSpec llega tarde para algunos ganchos y la detección queda muda. La configuración de
   entorno corre en el momento correcto del boot.
3. **`spec/support/bullet.rb` quedó sólo con el ciclo de vida** (`start_request` /
   `end_request`) y con el helper `detectando_n_plus_one`, que existe por una trampa fina:
   Bullet marca como "imposibles" los objetos cargados de a uno o recién creados, así que si
   hacés el `create_list` **dentro** del request de Bullet la detección se vuelve muda aunque
   el N+1 exista. El helper cierra y reabre el request para que sólo se audite la consulta que
   te importa. (Y resetea el colector al salir, porque
   `perform_out_of_channel_notifications` notifica pero **no** limpia, y si no lo hacés el
   `after` hook vuelve a levantar la misma excepción y RSpec marca el ejemplo como fallado
   aunque tu `expect { }.to raise_error` la haya capturado.)
4. **Se agregó `spec/n_plus_one_guard_spec.rb`**, que testea **la herramienta, no el código**,
   con un control positivo: verifica que `Bullet` esté cargado, que
   `UniformNotifier::Raise` esté entre los notificadores activos (`Bullet.raise` no tiene
   getter, choca con `Kernel#raise`), y que un N+1 escrito a propósito **efectivamente**
   levante `Bullet::Notification::UnoptimizedQueryError`.

Ese punto 4 es la regla general que vale llevarse: **cuando una herramienta de test puede
desactivarse en silencio** —un linter, un detector, un mock que no se aplica— **escribí un
test que verifique que está activa**. Cuesta cinco líneas y es lo único que distingue una red
de seguridad de un adorno.

**Qué apareció apenas se prendió.** N+1 reales, que es exactamente para lo que estaba: los
serializers de órdenes de compra y de transferencias recorrían las líneas tocando
`line.product` sin precarga. El arreglo tiene su propio matiz: **no** es un `includes` al
buscar, sino `ActiveRecord::Associations::Preloader` en el momento de serializar (el método
privado `serialize` de `Api::V1::PurchaseOrdersController`), porque los caminos de error
cortan antes de serializar y el `includes` habría precargado para nada. Por lo mismo,
`StockMovements::Ledger` ahora acepta un parámetro `preload:` y el dashboard le pasa
`%i[product warehouse]` —no el usuario, que no muestra—. Quien decide qué precargar es el que
sabe qué va a leer.

**Y el detector inverso quedó OPT-IN, a propósito.** `unused_eager_loading` avisa cuando hacés
`includes(:x)` y después no usás `:x`; la idea es buena y acá encontró desperdicio real. Pero
como **gate de CI es contraproducente**: cualquier código que precargue para el camino feliz y
corte antes por una validación lo dispara. Caso real de este repo:
`Purchasing::ReceiveOrder` carga `includes(lines: :product)` porque los necesita para recorrer
las líneas, pero si la cantidad recibida es inválida corta en la primera línea y la precarga
"no se usó". No hay nada que arreglar ahí: **no podés saber de antemano si vas a fallar**. Un
chequeo que grita en casos correctos entrena a la gente a ignorarlo, y ahí perdés también las
alertas buenas. Por eso `config/environments/test.rb` lo deja detrás de una variable:

```ruby
Bullet.unused_eager_loading_enable = ENV["BULLET_UNUSED"].present?   # BULLET_UNUSED=1 bundle exec rspec
```

El de N+1, en cambio, queda **siempre activo**: sus hallazgos son bugs reales, no ruido. Esa
distinción —qué chequeo merece ser gate y cuál merece ser reporte— es una lección de tooling
mucho más general que Bullet.

El hook sigue activándose **sólo en los ejemplos marcados** con `:n_plus_one`
(`config.before(:each, :n_plus_one)`, hoy en `spec/support/bullet.rb`; `spec/rails_helper.rb`
ya no menciona a Bullet), por la misma razón: activarlo globalmente genera falsos positivos en
specs unitarios donde la query repetida es intencional, la gente empieza a silenciarlos, y ahí
perdés la herramienta.

Java: es el `LazyInitializationException` / `hibernate.generate_statistics` del mundo JPA,
pero al revés — acá el lazy loading **funciona** silenciosamente y por eso el N+1 pasa
desapercibido hasta producción. Hibernate al menos te tira una excepción cuando la sesión
está cerrada.

**`brakeman` (8.0.6)** — analizador estático de seguridad específico de Rails. Corrida real:

```text
Controllers: 20 | Models: 22 | Templates: 34 | Errors: 0
Security Warnings: 0
Duration: 1.49 s | Checks Run: 79
```

Busca SQLi por interpolación, XSS por `html_safe`/`raw`, mass assignment, redirects abiertos,
deserialización insegura, `send` con input del usuario, secretos en el repo. Es SpotBugs +
Find-Sec-Bugs, pero con **conocimiento de Rails**: sabe qué es un controller, qué llega por
`params` y cómo fluye a una vista. Un linter genérico no puede hacer eso.

`bin/brakeman` agrega `--ensure-latest` (falla si tu Brakeman está viejo) y en CI corre con
`--exit-on-warn --exit-on-error`.

**`bundler-audit` (0.9.3)** — cubierto en §1.6.

**`rubocop-rails-omakase` (1.1.0)** + `rubocop-rspec` + `rubocop-performance`. "Omakase" es
el preset oficial de Rails 8 (el estilo de DHH): deliberadamente **permisivo**, mucho más que
el default de RuboCop. La filosofía es que un linter debe atrapar errores, no imponer gusto
personal; discutir comillas simples contra dobles en un code review es tiempo perdido.
`.rubocop.yml` entero tiene **una sola línea útil** (el resto son comentarios del generador):

```yaml
inherit_gem: { rubocop-rails-omakase: rubocop.yml }
```

Corrida real: **194 archivos inspeccionados, 0 ofensas**. El workflow de CI cachea
`RUBOCOP_CACHE_ROOT` (`tmp/rubocop`) con una clave derivada de `.ruby-version` +
`.rubocop.yml` + `.rubocop_todo.yml` + `Gemfile.lock`, que es la forma correcta: la clave del
cache tiene que incluir todo lo que invalida el resultado.

Java: Checkstyle/Spotless. La diferencia es que `rubocop -a` autocorrige de verdad la mayoría
de las ofensas de estilo.

## 28. Profiling: `rack-mini-profiler`, `stackprof`, `memory_profiler`

Las tres en `:development`, con `require: false`. Sirven en momentos distintos:

| Gema | Qué te da | Cuándo | Java análogo |
|---|---|---|---|
| `rack-mini-profiler` (5.0.0) | badge flotante en la página con el desglose de tiempo, **y cada query SQL con su backtrace** | "esta pantalla va lenta" | p6spy + un profiler de request |
| `stackprof` (0.2.28) | profiler por **muestreo** (wall / cpu / object) | "algo consume CPU y no sé qué" | async-profiler / JFR |
| `memory_profiler` (1.1.0) | reporte de **allocations y retenciones** por gema, archivo y línea | "la RAM del worker sube y no baja" | Eclipse MAT / heap dump |

El flujo real cuando algo va lento: mini-profiler primero, porque en 10 segundos te dice si
el problema es SQL (casi siempre lo es) o Ruby. Si es SQL, ya está —mirás el backtrace de la
query y probablemente sea un N+1 que Bullet no cazó porque no estaba tageado. Si es Ruby,
stackprof con `mode: :wall`.

Para memoria, el matiz que confunde a todo el mundo: `memory_profiler` distingue
**allocated** de **retained**. Allocated alto no es un problema —Ruby aloca mucho y el GC
limpia—; **retained** alto sí, porque es lo que se queda. Un "memory leak" en Ruby casi
nunca es un leak de verdad: es un array de clase que crece, un cache sin límite, o
fragmentación del allocator (para eso jemalloc, §3.3).

`rack-mini-profiler` con `require: false` necesita cargarse a mano cuando lo querés usar;
está bien así, porque agrega middleware y overhead a cada request.

---

# Parte X — Entorno y deploy

## 29. `dotenv-rails` (3.2.0)

```ruby
group :development, :test do
  gem "dotenv-rails", "~> 3.1"
end
```

Fijate el grupo: **development y test, nunca production**. Y es a propósito, es el punto 3 de
los 12 factores. En producción las variables de entorno las pone el orquestador (Kamal, systemd,
Kubernetes) y no hay ningún `.env` para leer. Un `.env` en un servidor de producción es un
archivo con secretos en texto plano que se filtra en un backup, en un `docker cp` o en un
volumen montado.

Para secretos **de la app** (no del entorno), Rails trae credenciales cifradas:
`config/credentials.yml.enc` + `config/master.key` (los dos existen acá; el `.key` está en
`.gitignore` y va como `RAILS_MASTER_KEY`). Eso sí se commitea, porque está cifrado. En
Spring lo más parecido es Jasypt o Spring Cloud Config con Vault — con la diferencia de que
acá viene de fábrica y se edita con `bin/rails credentials:edit`.

## 30. `kamal` (2.12.0) y `thruster` (0.1.26)

**Kamal**: deploy de contenedores Docker sobre VPS pelados, por SSH. Sin Kubernetes, sin
Helm, sin service mesh. Construye la imagen, la sube al registry, la baja en los servidores,
levanta el contenedor nuevo, espera el health check y recién ahí el proxy corta el tráfico al
viejo. Deploy sin downtime, con rollback, en una herramienta que entendés entera en una tarde.

Sus dependencias cuentan la historia (`Gemfile.lock`): `net-ssh`, `sshkit`, `ed25519`,
`bcrypt_pbkdf`, `thor`. Es Capistrano moderno con contenedores en lugar de directorios de
releases — o Ansible, si venís de ahí. La comparación honesta contra Kubernetes: Kamal no te
da autoescalado, ni scheduling, ni service discovery. Si no necesitás nada de eso —y la
mayoría de las apps no lo necesita— es una décima parte de la complejidad operativa.

**Thruster**: un proxy escrito en Go que va **adentro del mismo contenedor**, delante de
Puma. También es un binario precompilado por plataforma (`thruster-0.1.26-x86_64-linux`), no
código Ruby. El `Dockerfile` termina así:

```dockerfile
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
```

Da HTTP/2, compresión, cache de assets y `X-Sendfile` (servir archivos estáticos desde Go sin
ocupar un thread de Puma). Reemplaza al sidecar de nginx en setups simples.

Por qué importa el HTTP/2 acá y no es un detalle suelto: es lo que hace que importmap (§6)
sea viable sin bundling. Sin multiplexing, siete `<script>` separados sobre HTTP/1.1 son
siete round trips.

Java: es tener nginx delante de Tomcat, pero empaquetado en el mismo contenedor y sin
configurar nada.

## 31. `debug` (1.11.1)

El debugger oficial de Ruby 3.x, que reemplazó a `byebug` y `pry-byebug`.

```ruby
gem "debug", platforms: %i[mri windows], require: "debug/prelude"
```

Dos detalles en esa línea. `platforms:` lo limita a MRI y Windows (en JRuby no aplica). Y
`require: "debug/prelude"` en vez de `require: false` carga sólo un stub minúsculo que define
`binding.break` sin traer el debugger entero; el resto se carga la primera vez que frenás.
Es el patrón de carga perezosa aplicado a mano.

Un detalle que confunde: `gem list debug` devuelve **dos** versiones, `1.11.1` y `1.9.2`.
La 1.9.2 es la *default gem* que viene con Ruby 3.3; el `Gemfile` pide una más nueva y
Bundler la sombrea. Pasa lo mismo con `json (2.21.2, default: 2.7.2)`, y esa versión sombreada
es justamente la que gana el benchmark de §17. En Java sería un jar del `--upgrade-module-path`
pisando un módulo de la plataforma.

Uso remoto, ya configurado en `bin/dev`:

```bash
export RUBY_DEBUG_OPEN="true"    # abre un socket de debug
export RUBY_DEBUG_LAZY="true"    # pero no carga nada hasta que frenes
```

Con eso te conectás desde otra terminal con `rdbg --attach` a un proceso que ya está
corriendo — el equivalente del *remote debugging* de la JVM con `-agentlib:jdwp`.

---

## 32. Tabla resumen: gema → equivalente Java

| Gema | Qué hace | Equivalente Java |
|---|---|---|
| `rails` | framework | Spring Boot (+ BOM) |
| `puma` | servidor de app | Tomcat / Undertow |
| `pg` | driver de Postgres | driver JDBC |
| `propshaft` | fingerprint de assets | recursos estáticos con hash |
| `importmap-rails` | ESM sin bundler | servir `.js` desde `static/` |
| `turbo-rails` | HTML sobre el cable | Thymeleaf + htmx |
| `stimulus-rails` | JS mínimo sobre HTML del servidor | (sin equivalente directo) |
| `tailwindcss-rails` | CSS utilitario, binario sin Node | frontend-maven-plugin, sin Node |
| `bootsnap` | cache de boot | AppCDS / Class Data Sharing |
| `solid_queue` | jobs en Postgres | Quartz con JDBCJobStore |
| `solid_cache` | cache durable | Ehcache / Caffeine con disco |
| `solid_cable` | pub/sub | STOMP sobre broker |
| `mission_control-jobs` | dashboard de jobs | consola de Quartz |
| `sidekiq` + `redis` | jobs sobre Redis | JMS sobre ActiveMQ |
| `bcrypt` | hash de passwords | `BCryptPasswordEncoder` |
| `pundit` | autorización | `PermissionEvaluator` / `@PreAuthorize` |
| `rack-attack` | rate limiting de borde | Bucket4j + `Filter` |
| `pagy` | paginación | `Pageable` / `Slice` de Spring Data |
| `oj` | JSON en C | Jackson afterburner |
| `strong_migrations` | migraciones seguras | (sin equivalente; Flyway no chequea locks) |
| `rspec-rails` | testing | JUnit + AssertJ + Mockito |
| `factory_bot` | datos de test | Object Mother / Test Data Builder |
| `faker` | datos falsos | DataFaker |
| `shoulda-matchers` | matchers de AR | (sin equivalente) |
| `simplecov` | cobertura | JaCoCo |
| `webmock` | stub de HTTP | WireMock |
| `vcr` | grabar/reproducir HTTP | WireMock record & playback |
| `capybara` | DSL de browser | Selenium + DSL propio |
| `cuprite` | driver CDP | Playwright |
| `bullet` | detector de N+1 | `hibernate.generate_statistics` |
| `brakeman` | seguridad estática | SpotBugs + Find-Sec-Bugs |
| `bundler-audit` | CVEs en dependencias | OWASP dependency-check |
| `rubocop` | estilo | Checkstyle / Spotless |
| `rack-mini-profiler` | desglose de tiempo por request | p6spy + profiler de request |
| `stackprof` | profiler de CPU | async-profiler / JFR |
| `memory_profiler` | profiler de memoria | Eclipse MAT |
| `dotenv-rails` | `.env` en dev | `application-dev.properties` |
| `kamal` | deploy de contenedores | Ansible / Capistrano |
| `thruster` | proxy HTTP/2 | nginx delante de Tomcat |
| `debug` | debugger | JDWP / debugger del IDE |

---

## Errores que ves en producción

**1. `PG::ConnectionBad: FATAL: sorry, too many clients already`.**
*Síntoma:* la app anda hasta que escalás y entonces falla al azar.
*Causa:* el pool es **por proceso y por base**. Con 4 bases (primary, cache, queue, cable),
5 threads y 3 workers en 4 máquinas son `4 × 5 × 3 × 4 = 240` conexiones contra un
`max_connections` de 100.
*Arreglo:* hacé la cuenta antes de escalar, subí `max_connections` de Postgres, o metés
PgBouncer en modo transaction pooling (y ahí perdés prepared statements, hay que
configurar `prepared_statements: false`).

**2. `ActiveRecord::ConnectionTimeoutError: could not obtain a connection within 5 seconds`.**
*Síntoma:* aparece bajo carga, junto con latencias altas.
*Causa:* el pool tiene menos conexiones que threads de Puma. Los threads se pelean.
*Arreglo:* `max_connections >= RAILS_MAX_THREADS`. En `config/database.yml` está atado a la
misma variable justamente por esto. En la base de test está en 15 porque los specs de
concurrencia levantan threads reales.

**3. El rate limiting no limita nada y no avisa.**
*Síntoma:* nadie recibe 429 jamás; te enterás cuando te scrapean.
*Causa:* `rate_limit` sobre un `NullStore`: `increment` devuelve `nil`, la comparación nunca
se cumple. Fallo silencioso.
*Arreglo:* elegir el store explícitamente (`RATE_LIMIT_STORE` en
`app/controllers/api/v1/base_controller.rb:46`) y tener un test que **verifique un 429 real**.
Variante en test: `config/environments/test.rb` usa `:memory_store` en vez del `:null_store`
por defecto exactamente por esto.

**4. Todos los usuarios comparten un contador de rate limit.**
*Síntoma:* un usuario hace 300 requests y todo el mundo recibe 429.
*Causa:* `Rack::Attack` corriendo **antes** de `ActionDispatch::RemoteIp`, así que
`request.ip` es la IP del balanceador.
*Arreglo:* montarlo después de `RemoteIp` y configurar `trusted_proxies`. En este repo es
`config.middleware.move_after ActionDispatch::RemoteIp, Rack::Attack` en
`config/application.rb`. **CORREGIDO acá:** estaba con `insert_after`, que no mueve nada sino
que agrega una segunda copia encima de la que monta el railtie de la gema — el stack tenía
`Rack::Attack` dos veces (§16). Verificá con `bin/rails middleware`, no supongas.

**5. `bundle install` falla en Docker pero anda en tu máquina.**
*Síntoma:* `Could not find gem 'pg-1.6.3-x86_64-linux' in locally installed gems`.
*Causa:* falta la plataforma en `PLATFORMS` del lock (típico: equipo en Mac ARM, CI en
x86_64 Linux; o Alpine, que es `musl` y no `gnu`).
*Arreglo:* `bundle lock --add-platform x86_64-linux` y commitear el lock.

**6. `Can't find the 'libpq-fe.h' header` al instalar `pg`.**
*Síntoma:* falla la compilación de una gema nativa.
*Causa:* falta la librería de desarrollo del sistema.
*Arreglo:* `libpq-dev` (Debian) en la **etapa de build**, como hace el `Dockerfile`. La
imagen final sólo necesita `postgresql-client`.

**7. Producción usa 16 MB más por proceso de lo esperado.**
*Causa:* una gema de herramientas sin `require: false`, o `BUNDLE_WITHOUT` mal configurado.
*Arreglo:* `bin/rails runner 'puts defined?(RuboCop)'` en producción. Si dice algo distinto
de `nil`, ahí está. **PASÓ ACÁ, con `sidekiq`:** el initializer tenía el `require` condicional
pero el `Gemfile` la declaraba sin `require: false`, así que se cargaba en todos los procesos
aunque el adapter fuera Solid Queue. Corregido (§1.5); hoy `sidekiq cargado?` da `NO`.

**8. `PG::UnableToSend` / respuestas cruzadas después de activar `preload_app!`.**
*Causa:* las conexiones abiertas antes del `fork()` quedan compartidas entre workers.
*Arreglo:* `on_worker_boot { ActiveRecord::Base.establish_connection }`. Es específico del
modelo de procesos y no tiene equivalente en la JVM.

**9. `pumactl phased-restart` no hace nada o falla.**
*Causa:* phased restart es **incompatible con `preload_app!`**, y requiere cluster mode.
*Arreglo:* elegís uno de los dos, o hacés el deploy sin downtime una capa más arriba (Kamal).

**10. Una migración "instantánea" tira el sitio dos minutos.**
*Síntoma:* timeouts masivos durante el deploy, la app se recupera sola después.
*Causa:* `ALTER TABLE` toma `ACCESS EXCLUSIVE`, espera detrás de una query larga, y **encola
todo lo que llega después**.
*Arreglo:* `strong_migrations` te lo caza en desarrollo, y en este repo ya está configurado
con `lock_timeout = 10.seconds` (abortar en vez de encolar) y `target_version = 16`. Para
índices, `algorithm: :concurrently` con `disable_ddl_transaction!`.

**11. El CI se rompió solo y nadie tocó nada.**
*Causa:* Chrome se autoactualizó y su versión mayor ya no coincide con la de chromedriver.
*Arreglo:* cuprite (habla CDP directo, no hay driver intermedio), o pinear las dos versiones
en la imagen del CI. Acá pasó con Chromium 141 vs ChromeDriver 147.

**12. Jobs perdidos al reiniciar en desarrollo.**
*Causa:* `QUEUE_ADAPTER=async` (el default de dev en Rails) guarda los jobs en un thread pool
**en memoria**.
*Arreglo:* Solid Queue también en desarrollo. Está documentado en
`config/initializers/active_job.rb`; en producción es pérdida de datos garantizada.

**13. El job recurrente corre N veces, una por servidor.**
*Causa:* `crontab` replicado en cada máquina.
*Arreglo:* `config/recurring.yml` de Solid Queue, que ejecuta una sola vez. **CORREGIDO acá:**
este documento decía que lo lograba "eligiendo líder", y no es así — no hay elección de líder.
Cada scheduler intenta `INSERT`ar en `solid_queue_recurring_executions`, que tiene un índice
único sobre `(task_key, run_at)`: el primero gana y los demás se comen la violación de
unicidad (§11). Además queda versionado con el código y visible en Mission Control.

**14. Un cliente pide `?limit=100000` y el proceso muere.**
*Causa:* parámetro de paginación sin cota.
*Arreglo:* `Pagy::DEFAULT[:max_limit] = 100` (`config/initializers/pagy.rb`). Y para
colecciones que sólo crecen, keyset en vez de offset.

**15. Una gema de performance que no hace nada.**
*Síntoma:* ninguno, ése es el problema.
*Causa:* la gema necesitaba un initializer que nadie escribió. **PASÓ ACÁ:** `oj` estaba
cargado en todos los procesos y `ActiveSupport::JSON::Encoding.json_encoder` seguía siendo
`JSONGemEncoder`, el de la stdlib.
*Arreglo (aplicado):* `config/initializers/oj.rb` con `Oj.default_options = { mode: :rails }`
y `Oj.optimize_rails`; hoy `json_encoder` devuelve `Oj::Rails::Encoder` (§17). Y la segunda
mitad de la lección: **medí después de enchufarla**. Acá la ganancia real es ~2.6x sobre el
encoder anterior, que son 0.13 ms en una página de 25 objetos (ruido) y 25 ms en un export de
5000 (ahí sí). El comentario del `Gemfile` lo dice así ahora, en vez de venderla como free win.

---

## Cómo responder esto en una entrevista

**«¿Qué diferencia hay entre `Gemfile` y `Gemfile.lock`, y cuál commiteás?»**

Los dos. El `Gemfile` son tus restricciones (`~> 8.1.3`); el lock es el grafo resuelto
completo con versiones exactas, plataformas y checksums sha256, y es el que garantiza que
todos instalen lo mismo. En una app siempre se commitea; en una **gema** no, porque quien la
use tiene que poder resolver sus propias versiones.
*Trade-off:* el lock te da reproducibilidad y te congela; sin `bundle outdated` periódico
acumulás deuda hasta que actualizar Rails es un proyecto de un mes.
*Contraste con Maven:* Bundler **falla** ante un conflicto de versiones; Maven aplica "nearest
wins" en silencio y te enterás en runtime. Y en Ruby no hay classloaders: una sola versión de
cada gema por proceso, no hay shading que te salve.

**«¿Qué hace `require: false` y por qué te importa?»**

Instala la gema pero no le hace `require` al bootear. Importa porque en Ruby `require`
**ejecuta** el archivo, así que cada gema cargada suma RAM y tiempo de boot a **todos** los
procesos. Lo medí en este repo: cargar rubocop y brakeman son **+16 MB y +404 archivos** por
proceso. Con 4 workers son ~64 MB para dos herramientas que nunca corren dentro de la app.
*Trade-off:* tenés que acordarte de `bundle exec` o de cargarla a mano, y si una gema tiene un
railtie que hace algo importante, con `require: false` deja de funcionar en silencio.
*El caso concreto de este repo:* `sidekiq` tenía el `require` condicional en el initializer
pero no el `require: false` en el `Gemfile`, así que se cargaba igual en todos los procesos —
la mitad de la optimización escrita, cero beneficio. Se detecta con
`Object.const_defined?(:Sidekiq)`, no leyendo el `Gemfile`.
*Contraste con Java:* el problema no existe porque el classloader es perezoso; un jar en el
classpath que nadie referencia no cuesta nada.

**«Puma vs Tomcat: ¿cómo dimensionás threads y workers?»**

Threads para I/O, procesos para CPU. En CRuby el GVL deja correr un thread de bytecode Ruby
por vez, pero **lo libera durante I/O y en extensiones C que lo sueltan**. Lo medí acá con
4 cores: 8 hashes de bcrypt secuenciales tardan 1.87 s y en 8 threads 0.49 s — **speedup
3.8x**, porque bcrypt libera el GVL. El mismo test con Ruby puro CPU-bound da speedup 0.98x:
cero paralelismo. Por eso threads sirven en una app web (que espera SQL) y para escalar CPU
necesitás workers.
*Trade-off:* `preload_app!` te ahorra RAM por copy-on-write y acelera el boot, pero es
**incompatible con phased restart** y te obliga a reconectar ActiveRecord en `on_worker_boot`
porque los file descriptors se heredan por el `fork()`. En la JVM nada de esto existe: no hay
fork, los threads son paralelos de verdad, y el precio histórico lo pagás en startup.

**«¿Por qué Pundit y no CanCanCan? ¿Por qué autorización en objetos y no en el controller?»**

Pundit es una clase por recurso y un método por acción: Strategy, testeable como PORO, y
crece en archivos en vez de en una `Ability` de 400 líneas. Lo decisivo son dos cosas que
evitan agujeros reales: `verify_authorized` te avisa si te olvidaste de autorizar una acción,
y `Scope#resolve` devuelve `scope.none` por defecto — autorizar el `show` no sirve de nada si
el `index` lista todo.
*Trade-off:* CanCanCan arranca más rápido y su `accessible_by` deriva el scope del DSL
gratis; con Pundit escribís el scope a mano.
*Contraste con Spring Security:* `@PreAuthorize` se evalúa por AOP automáticamente; `authorize`
en Rails es una llamada **explícita que te podés olvidar**. Por eso `verify_authorized` no es
opcional.

**«¿Qué es una gema nativa y por qué falla la instalación?»**

Una gema con extensión en C que se compila contra los headers de tu Ruby — una JNI construida
en `gem install`. Hoy muchas publican binarios precompilados por plataforma: en este repo
`pg-1.6.3-x86_64-linux` y `nokogiri-1.19.4-x86_64-linux-gnu` no compilan nada, mientras que
`bcrypt`, `oj` y `puma` sí se compilaron desde fuente.
Falla por: falta la librería de desarrollo del sistema (`libpq-dev` para pg), falta el
compilador, faltan los headers de Ruby, o la plataforma del lock no coincide (musl vs gnu, o
darwin-arm64 vs x86_64-linux). Se arregla con `bundle lock --add-platform` y compilando en una
etapa de build separada del runtime, como hace nuestro `Dockerfile`.

**«¿Cómo decidís si agregar una dependencia?»**

Cinco preguntas, en orden: ¿lo escribo en 50 líneas que entiendo? ¿está mantenida y sigue el
ritmo de Rails? ¿cuánta superficie de API me obliga a adoptar? ¿cuánto pesa al bootear?
¿Rails 8 ya lo trae?
La tercera es la que más se subestima: `pagy` te da un objeto y un método, así que sacarlo
toca los controllers; `kaminari` agrega `.page` a **todos** los `ActiveRecord::Relation` y
sacarlo es un refactor. Preferí lo que se enchufa sobre lo que se inyecta.
*Y el caso concreto:* apliqué el criterio a `oj` y encontré que **ni siquiera estaba
conectado** — `ActiveSupport::JSON::Encoding.json_encoder` devolvía `JSONGemEncoder`, el de la
stdlib, porque faltaba el `Oj.optimize_rails` de un initializer. Pagábamos la RAM en todos los
procesos y no serializábamos un solo byte con ella. Se enchufó
(`config/initializers/oj.rb`, con `mode: :rails`, que es obligatorio porque los otros modos te
cambian el formato de fechas y `BigDecimal` en silencio) y recién ahí medí: ~2.6x contra el
encoder anterior, o sea 0.13 ms de ganancia en una página de 25 objetos y 25 ms en un export
de 5000. Se queda, con la ganancia acotada y escrita en el `Gemfile`. Es la lección general en
dos partes: una dependencia que entró por performance necesita que **verifiques que está
enganchada** y que **revalides la medición**, porque el consejo de hace ocho años sigue
circulando mucho después de dejar de ser cierto — el gem `json` se reescribió entre 2023 y
2025 y buena parte de la ventaja histórica de Oj se evaporó.

> La pregunta «¿Solid Queue o Sidekiq?» cae seguro y la respuesta completa está en §13 y en
> docs/07. La versión de 30 segundos: Solid Queue mete el `INSERT` del job **en tu misma
> transacción**, Sidekiq no; por debajo de ~10k jobs/min eso vale más que la latencia de
> ~1 ms de Redis. Y acá van los dos remates que separan una buena respuesta de una excelente.
> Primero: eso del `INSERT` transaccional **es cierto sólo si la cola comparte base con tus
> datos**, y en este repo no la comparte (`config.solid_queue.connects_to = { database:
> { writing: :queue } }`), así que el rollback deja el job encolado igual — es una propiedad
> de la topología, no de la gema. Segundo: `enqueue_after_transaction_commit` arregla el
> rollback en los dos backends pero **no reemplaza al outbox**, porque si el proceso muere
> entre el COMMIT y el enqueue el job se pierde igual. Y ojo dónde lo escribís: en Rails 8.1
> ponerlo en un initializer como `config.active_job.enqueue_after_transaction_commit` es un
> **no-op silencioso**; va por clase de job (`self.enqueue_after_transaction_commit = true` en
> `ApplicationJob`).
