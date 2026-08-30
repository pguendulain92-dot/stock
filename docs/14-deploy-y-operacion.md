# Deploy, entornos y operación

Qué vas a encontrar acá: cómo pasa esta app de tu máquina a un servidor y qué hay
que saber para que no se caiga. Los 12 factores traducidos a Rails, qué cambia
entre `development`, `test` y `production`, credenciales encriptadas vs variables
de entorno, el `Dockerfile` que genera Rails 8 leído bloque por bloque, Kamal
comparado contra Kubernetes/ECS/Heroku, migraciones sin downtime (expand-contract),
assets con Propshaft, zero-downtime de verdad (señales, drenaje, jobs en vuelo),
backups de Postgres, el CI real de este repo y un runbook con cuatro incidentes
concretos.

Todos los comandos, salidas y defaults de gemas de este documento salieron de
correrlos contra este repo (Rails 8.1.3.1, Ruby 3.3.6, PostgreSQL 16.13, Kamal
2.12.0, Puma 8.0.2, Solid Queue 1.7.0, Thruster 0.1.26). Donde algo **no existe**
en el repo, lo digo explícitamente en vez de inventarlo.

Documentos hermanos que este da por leídos:
`docs/03-base-de-datos-y-activerecord.md` (pool, multi-DB, migraciones seguras),
`docs/07-colas-jobs-y-mensajeria.md` (Solid Queue, outbox),
`docs/12-seguridad.md` (secretos, cabeceras) y
`docs/13-observabilidad-y-performance.md` (logs y métricas).

---

## 0. El modelo mental: de un WAR en Tomcat a un contenedor de Rails

En Java venís de un artefacto **compilado y autocontenido**: `mvn package` te da
un JAR/WAR, lo tirás en un Tomcat o lo corrés con `java -jar`, y la JVM hace el
resto. El classpath está congelado en el artefacto. Si compila, arranca.

En Rails el artefacto es **el código fuente más las gemas instaladas**. No hay
compilación que te avise nada: los errores de "no encuentro esta constante" o
"esta gema no está en el grupo `production`" aparecen **al bootear en el
servidor**, no en tu máquina. Por eso Rails inventó cosas que en Java no
necesitás: `config.eager_load = true` (cargar todo al arrancar para que los
errores exploten en el boot y no en el request 500 de un martes), `bin/rails
zeitwerk:check`, y `bundle install --deployment`.

| Concepto | Java / Spring Boot | Rails 8 |
|---|---|---|
| Artefacto | JAR fat / WAR | imagen Docker (código + gemas + assets) |
| Dependencias | `pom.xml` + repo Maven | `Gemfile.lock` + gemas nativas compiladas |
| Server HTTP | Tomcat/Netty embebido, 1 proceso, N threads | Puma: **N procesos** x M threads |
| Config | `application-prod.yml`, Spring Cloud Config | `config/environments/production.rb` + ENV |
| Secretos | Vault / `jasypt` / env | `config/credentials.yml.enc` + `master.key`, o ENV |
| Migraciones | Flyway / Liquibase, paso aparte | `bin/rails db:migrate`, mismo repo |
| Healthcheck | `/actuator/health` (chequea DB, disco, etc.) | `/up` (**sólo** dice si booteó) |
| Escalar | más threads / más pods | más **procesos** (el GVL limita los threads) |

**La analogía que se rompe primero:** en Spring un pod que escala es "subir
`server.tomcat.threads.max`". En Ruby los threads no ejecutan Ruby en paralelo
(GVL), así que escalar es **agregar procesos**, y cada proceso abre **su propio
pool de conexiones a Postgres**. Ese detalle es el que hace explotar los deploys
de la gente que viene de la JVM. Ver `config/database.yml:10-26`, donde está la
cuenta escrita.

---

## 1. Los 12 factores, traducidos a este repo

No los recito: te digo cómo se resuelve cada uno acá y dónde se rompe.

| # | Factor | En este repo | Dónde falla la gente |
|---|---|---|---|
| I | Una base de código, muchos deploys | un repo git, misma imagen a staging y prod | armar una imagen por entorno |
| II | Dependencias declaradas | `Gemfile` + `Gemfile.lock`, `BUNDLE_DEPLOYMENT=1` en `Dockerfile:25` | depender de un binario del sistema no declarado (`libvips`, `postgresql-client` **sí** están en `Dockerfile:19`) |
| III | Config en el entorno | `.env.example`, `ENV.fetch(...)` en `config/*.yml` | meter la config en `credentials.yml.enc` "porque es más cómodo" (ver §3) |
| IV | Backing services como recursos adjuntos | `DATABASE_URL`, `REDIS_URL`, `OUTBOX_ADAPTER` intercambiables (`app/services/outbox/publisher.rb:26`) | hardcodear `localhost` |
| V | Build / release / run separados | build de la imagen ≠ `kamal deploy` ≠ contenedor corriendo | precompilar assets **en runtime** dentro del contenedor |
| VI | Procesos sin estado | sesiones en Postgres (`sessions`), cache en Solid Cache, jobs en Postgres | ⚠️ `config.active_storage.service = :local` (`config/environments/production.rb:25`) guarda **archivos en el disco del contenedor** |
| VII | Port binding | Thruster escucha 80/443 y le habla a Puma en 3000 | — |
| VIII | Concurrencia por procesos | `WEB_CONCURRENCY` (Puma) + `config/queue.yml` (workers) | subir threads en vez de procesos |
| IX | Desechabilidad | SIGTERM graceful en Puma y en Solid Queue (§10) | jobs largos sin checkpoint |
| X | Dev/prod lo más parecidos posible | Solid Cache **también** en dev (`config/environments/development.rb:29-33`), Postgres 16 en CI (`.github/workflows/ci.yml`) | `:memory_store` en dev y Redis en prod |
| XI | Logs como stream de eventos | `config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)` (`production.rb:38`) | escribir a `log/production.log` dentro del contenedor |
| XII | Admin como procesos one-off | `bin/rails runner`, `bin/rails console`, `kamal app exec` | correr tareas de mantenimiento desde el proceso web |

Dos comentarios sobre el factor X, que es el que más rinde en una entrevista.
Este repo hace algo deliberado: usa **el mismo backend de cache en desarrollo que
en producción**. El comentario en `config/environments/development.rb:29-31` lo
explica: con `:memory_store` en dev, un bug de serialización del cache aparece
recién en prod. Lo mismo con Postgres: el CI levanta `postgres:16`, no SQLite.

Y el factor VI merece un ⚠️ grande en este repo: `config.active_storage.service =
:local` con `config/storage.yml` apuntando a `Rails.root.join("storage")`. Eso
está bien para desarrollo, pero en un contenedor significa que **los archivos
subidos desaparecen en el próximo deploy**. El arreglo es un volumen persistente
(en Kamal, `volumes: ["app_storage:/rails/storage"]`) o, mejor, S3.

---

## 2. Entornos: `development`, `test`, `production`

Rails tiene exactamente tres archivos acá:

```bash
$ ls config/environments/
development.rb  production.rb  test.rb
```

Se cargan **después** de `config/application.rb` y pisan lo que este haya puesto.
El entorno se elige con `RAILS_ENV` (o `RACK_ENV`); el `Dockerfile:24` lo fija en
`production` como variable de imagen, así que dentro del contenedor no hay forma
de arrancar en otro entorno sin querer.

> **Diferencia con Spring:** un perfil de Spring (`@Profile("prod")`) puede
> activar y desactivar **beans**. Un entorno de Rails no cambia qué clases
> existen: cambia flags de configuración. Si querés que una clase exista sólo en
> un entorno, lo hacés vos con un `if Rails.env.production?`, y eso casi siempre
> es olor a mal diseño. La excepción legítima es el grupo del `Gemfile`:
> `BUNDLE_WITHOUT="development"` en `Dockerfile:27` hace que las gemas de
> desarrollo **literalmente no estén instaladas** en la imagen.

### 2.1 Qué cambia realmente en cada uno

Valores tomados de los tres archivos del repo:

| Opción | development | test | production |
|---|---|---|---|
| `enable_reloading` | `true` | `false` | `false` |
| `eager_load` | `false` | `ENV["CI"].present?` | `true` |
| `consider_all_requests_local` | `true` | `true` | `false` |
| `cache_store` | `:solid_cache_store` | `:memory_store` | `:solid_cache_store` |
| `active_job.queue_adapter` | `solid_queue` (o `QUEUE_ADAPTER`) | `:test` | `:solid_queue` |
| `logger` | default (a `log/development.log`) | default | `TaggedLogging` a **STDOUT** |
| `log_level` | `debug` | `debug` | `ENV["RAILS_LOG_LEVEL"]` o `info` |
| `public_file_server.headers` | `max-age=2.days` sólo con cache on | `max-age=3600` | `max-age=1.year` |
| `active_record.migration_error` | `:page_load` | — | — |
| `active_record.attributes_for_inspect` | todos | todos | `[:id]` |
| `report_deprecations` | log | stderr | `false` |
| `silence_healthcheck_path` | — | — | `/up` |
| `force_ssl` | — | — | **comentado** (`production.rb:31`) |
| `hosts` | localhost | — | **comentado** (`production.rb:83`) |

Cuatro cosas de esa tabla que hay que poder explicar:

**`eager_load`.** En dev, Rails carga las clases *lazy* vía Zeitwerk: la primera
vez que nombrás `Stock::ApplyMovement`, el autoloader busca
`app/services/stock/apply_movement.rb` y lo carga. En producción carga **todo** al
bootear. Dos motivos: (a) con `fork` de Puma, el código cargado antes del fork se
comparte por copy-on-write entre workers (menos memoria); (b) un archivo mal
nombrado explota en el boot, no en el request. En `test` está atado a `ENV["CI"]`
justamente para tener las dos cosas: velocidad local, seguridad en CI.

**`attributes_for_inspect = [:id]`.** Detalle nuevo y muy sensato de Rails 7.2+:
en producción, `product.inspect` muestra sólo el id. Sin esto, cualquier
`Rails.logger.info(product.inspect)` te vuelca el registro entero al log, con
datos personales incluidos. Es el equivalente a no poner `toString()` con todos
los campos en una entidad JPA.

**`silence_healthcheck_path = "/up"`.** El balanceador pega a `/up` cada uno o dos
segundos. Sin esto, el 90% de tus logs son healthchecks.

**`force_ssl` comentado.** Está así porque el generador de Rails lo deja
comentado, y este repo no lo tocó. En un deploy real hay que decidir: si
terminás TLS en un proxy (kamal-proxy, ALB), ponés `config.assume_ssl = true` y
`config.force_ssl = true`. Y **si prendés `force_ssl`, acordate de la línea 34**:

```ruby
# config/environments/production.rb:34
# config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
```

Sin esa exclusión, el healthcheck por HTTP recibe un `301` en vez de `200`, el
balanceador marca el contenedor como no sano y **el deploy nunca termina**. Es un
clásico y está literalmente escrito en el archivo generado; la gente lo borra sin
leerlo.

### 2.2 "Anda en dev, rompe en prod": las 5 causas típicas

**1. Autoloading / eager loading (Zeitwerk).** En dev sólo se carga lo que usás.
Un archivo con el nombre mal (un `app/services/stock/api_client.rb` hipotético definiendo
`APIClient` en vez de `ApiClient`) funciona hasta que alguien lo referencia. En
prod, el eager load lo toca todo en el boot y falla el arranque entero.

El comando que atrapa esto **antes** de deployar existe y corre en segundos:

```bash
$ bin/rails zeitwerk:check
Hold on, I am eager loading the application.
All is good!
```

Metelo en el CI. Este repo no lo tiene todavía en `.github/workflows/ci.yml`, y es
lo primero que le agregaría (§12).

**2. Una gema en el grupo equivocado.** Si usás algo de un grupo `:development` en
código que corre en producción, en tu máquina anda (todos los grupos están
cargados) y en el contenedor tira `NameError`. El `Dockerfile:27` pone
`BUNDLE_WITHOUT="development"`, así que la gema **no está instalada**. Este repo
tiene `bullet` en el stack de middleware de desarrollo (lo ves en `bin/rails
middleware`), y por eso mismo no puede referenciarse desde código de dominio.

**3. Cache y perform_caching.** En dev, `config.action_controller.perform_caching`
es `false` salvo que exista `tmp/caching-dev.txt`. Todo lo que se apoya en cache
funciona distinto. Este repo mitiga usando Solid Cache en los dos lados, pero el
fragment caching sigue apagado en dev.

**4. Assets.** En dev, Propshaft sirve los archivos desde `app/assets` sobre la
marcha. En producción sirve **sólo lo que está en `public/assets`** con su digest.
Un archivo que agregaste y no precompilaste da 404 (§9).

**5. Concurrencia.** En dev corrés un proceso, un usuario, y probablemente
`WEB_CONCURRENCY` sin definir (Puma arranca en *single mode*, lo confirmás en el
log: `Puma starting in single mode...`). En prod hay N procesos x M threads
pegándole a la misma fila de `stock_items`. Todo lo de
`docs/06-concurrencia-transacciones-y-locking.md` recién aparece ahí. El corolario
operativo: los specs de concurrencia de este repo levantan threads reales y por
eso `config/database.yml:101` sube el pool de test a 15.

---

## 3. Credenciales encriptadas vs variables de entorno

Rails tiene **dos** mecanismos y hay que saber cuándo usa cada uno.

### 3.1 Cómo funcionan las credenciales

```bash
$ ls -la config/credentials.yml.enc config/master.key
-rw-r--r-- 1 root root 548 config/credentials.yml.enc
-rw------- 1 root root  32 config/master.key
```

`credentials.yml.enc` es un YAML cifrado con **AES-256-GCM**, y la clave de 32
bytes hexadecimales vive en `config/master.key`. El `.enc` **se commitea**; la
`.key` **nunca** (`/config/*.key` está en `.gitignore`, y también en
`.dockerignore:14-15`, así que ni siquiera entra a la imagen).

Contenido real de este repo:

```bash
$ bin/rails runner 'pp Rails.application.credentials.config.keys'
[:secret_key_base]
```

Sólo `secret_key_base`. Todo lo demás en este proyecto va por ENV, y eso es una
decisión, no un descuido (`.env.example:9-11` la explica).

Se editan con `bin/rails credentials:edit` (necesita `EDITOR` seteado: descifra a
un tmpfile, abre el editor, vuelve a cifrar al cerrar).

En el boot, Rails busca la clave **en este orden**: `ENV["RAILS_MASTER_KEY"]`
primero, `config/master.key` después. Por eso el `Dockerfile:6` documenta
`docker run -e RAILS_MASTER_KEY=<...>`.

Los dos errores reales, reproducidos:

```text
# Falta la clave por completo:
ActiveSupport::EncryptedFile::MissingKeyError: Missing encryption key to decrypt
file with. Ask your team for your master key and write it to config/master.key
or put it in the ENV['RAILS_MASTER_KEY'].

# La clave está pero es la equivocada (rotaste y no actualizaste el secreto):
ActiveSupport::MessageEncryptor::InvalidMessage
```

El segundo mensaje **no dice nada**: es literalmente la clase de excepción con
mensaje vacío. Si ves `InvalidMessage` en un deploy, es master key equivocada, no
"el archivo está corrupto".

### 3.2 Credenciales por entorno

Rails soporta un par de archivos por entorno:

```text
config/credentials/production.yml.enc
config/credentials/production.key      # gitignored, ver .dockerignore:15
```

Si `config/credentials/<RAILS_ENV>.yml.enc` existe, Rails lo usa **en lugar** del
archivo compartido, y `config.credentials.key_path` pasa a apuntar a
`config/credentials/<RAILS_ENV>.key` en vez de `config/master.key`. ⚠️ Ojo con
esto porque es contraintuitivo: **la variable de entorno sigue llamándose
`RAILS_MASTER_KEY`**, no `PRODUCTION_KEY` ni nada por el estilo. Lo dice el
docstring de `Rails::Application#credentials`
(`railties-8.1.3.1/lib/rails/application.rb:492-496`): *"The encryption key is
taken from either `ENV["RAILS_MASTER_KEY"]`, or from the file specified by
`config.credentials.key_path`"*. Lo que cambia por entorno es **el archivo de
llave**, no el nombre de la variable. Se crea con:

```bash
bin/rails credentials:edit --environment production
```

Este repo **no** usa credenciales por entorno: sólo tiene el par compartido. Con
una sola llave para todos los entornos, cualquiera que pueda deployar a staging
puede descifrar los secretos de producción. Si el proyecto crece, esto es lo
primero que separaría.

### 3.3 Rotación

Rotar la master key no es "cambiar el archivo": el `.enc` está cifrado con la
vieja.

```bash
# 1. Descifrá y guardá el contenido (con la llave vieja todavía puesta)
bin/rails credentials:show > /tmp/creds.yml

# 2. Sacá de en medio los archivos viejos
mv config/credentials.yml.enc config/credentials.yml.enc.bak
mv config/master.key config/master.key.bak

# 3. credentials:edit sin archivo => genera par nuevo
EDITOR="cat" bin/rails credentials:edit     # crea .enc + master.key nuevos
# 4. Pegá el contenido de /tmp/creds.yml adentro y guardá
# 5. Distribuí la master.key nueva (gestor de secretos, no Slack)
# 6. Deploy. Recién ahí borrá los .bak y el /tmp/creds.yml
```

⚠️ **Rotar `secret_key_base` es otra cosa y es destructiva.** De ese valor se
derivan las firmas de las cookies de sesión y de todos los
`MessageVerifier`/`signed_id`. Si lo cambiás, **todas las sesiones activas se
invalidan** (en este repo las sesiones son filas en `sessions` más una cookie
firmada con `session_id`: la cookie deja de verificar y el usuario queda
deslogueado) y cualquier `signed_id` en un mail viejo deja de validar. Rails
soporta rotadores (`ActiveSupport::MessageVerifier` con `rotate`) para aceptar la
clave anterior durante una ventana; si vas a rotar en serio, ese es el camino.

### 3.4 ¿Credentials o ENV? El criterio

| Va en `credentials.yml.enc` | Va en ENV |
|---|---|
| Secretos que **no cambian entre servidores** y son del código: `secret_key_base`, claves de API de terceros que son las mismas siempre | Todo lo que **cambia entre entornos o instancias**: `DATABASE_URL`, `REDIS_URL`, `WEB_CONCURRENCY`, `RAILS_LOG_LEVEL` |
| Ventaja: versionado, revisable en un PR (que cambió, no qué valor), no hay que configurar nada en el server salvo una llave | Ventaja: lo rota tu gestor de secretos sin rebuild de imagen; funciona con Vault/AWS Secrets Manager/Doppler |
| Desventaja: para cambiar un valor hay que hacer **un commit y un deploy** | Desventaja: se filtra fácil en logs, `docker inspect` y crash dumps |

**El error del javero:** venir de Spring Cloud Config y meter *toda* la
configuración en `credentials.yml.enc` porque "está encriptado y es cómodo".
Entonces cambiar el nivel de log requiere un deploy. La regla de
`.env.example:10-11` es la buena: si cambia entre entornos, es configuración y va
al entorno; si no cambia nunca, es código.

Y un detalle de operación: `dotenv-rails` carga `.env` **sólo en development y
test**. En producción no hay `.env`; las variables vienen del orquestador.

### 3.5 `SECRET_KEY_BASE_DUMMY`

Mirá esta línea del `Dockerfile:55`:

```dockerfile
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile
```

Para precompilar assets hay que **bootear la app**, y bootear en producción exige
`secret_key_base`, que exige la master key. Meter la master key en el build
significaría que queda en una capa de la imagen para siempre. `SECRET_KEY_BASE_DUMMY=1`
le dice a Rails: generá un `secret_key_base` random y descartable, sólo para este
proceso. Es exactamente por eso que la master key **no** necesita estar en el
build, sólo en el runtime.

---

## 4. El `Dockerfile` de Rails 8, bloque por bloque

El archivo tiene 78 líneas y hace más de lo que parece. Lo recorro entero.

### Bloque 1 — la etapa `base` (líneas 11-28)

```dockerfile
ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"
```

- `ruby:3.3.6-slim` es **Debian con glibc**, no Alpine. Importa para las gemas con
  binarios precompilados (ver el gotcha de plataformas más abajo).
- Sólo cuatro paquetes de runtime: `curl` (healthchecks), `libjemalloc2`,
  `libvips` (Active Storage), `postgresql-client` (te da `psql` y `pg_dump`
  **dentro** del contenedor, que es lo que salva un incidente a las 3 AM).
- **`LD_PRELOAD` con jemalloc** es el truco más rentable de la imagen. El
  allocator por defecto de glibc fragmenta feo con el patrón de asignación de
  Ruby; jemalloc típicamente baja el RSS de forma notoria sin tocar una línea de
  código. Es el equivalente moral de elegir el GC de la JVM, sólo que acá se hace
  con una variable de entorno.
- `BUNDLE_DEPLOYMENT=1` es el `--deployment` de siempre: **falla** si el
  `Gemfile.lock` no está sincronizado con el `Gemfile`, y no deja que bundler
  actualice el lock. Es lo que querés en un build reproducible.
- `BUNDLE_WITHOUT="development"` — las gemas de dev ni se instalan.

### Bloque 2 — la etapa `build`, descartable (líneas 31-55)

```dockerfile
FROM base AS build
RUN apt-get install ... build-essential git libpq-dev libvips libyaml-dev pkg-config ...
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile
COPY . .
RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile
```

Cuatro cosas que hay que notar:

**a) El orden de los `COPY` es cache de Docker, no capricho.** `Gemfile` y
`Gemfile.lock` se copian **antes** que el código. Así, mientras no toques
dependencias, la capa cara (`bundle install`, que compila extensiones C: `pg`,
`nokogiri`, `bcrypt`) se reusa. Si copiaras `COPY . .` primero, cada cambio en un
controller recompilaría todas las gemas nativas. Es el mismo patrón que ponés
`COPY pom.xml` antes del `src/` en un build de Maven.

**b) `bootsnap precompile`.** Bootsnap cachea dos cosas: el resultado del parser
de Ruby (ISeq compilado) y las resoluciones de `require`. Precompilarlo en build
time significa que el contenedor arranca sin pagar ese costo. La primera vez se
nota mucho: es la diferencia entre bootear en ~6s y en ~2s. Los comentarios de
las líneas 44 y 51 explican el `-j 1`: hay un bug con QEMU cuando compilás para
otra arquitectura (típico: build en Mac ARM, deploy en x86).

**c) Los assets se precompilan **en el build**, no en el arranque.** Es el factor
V (build/release/run separados). Si lo hicieras en el entrypoint, cada contenedor
gastaría CPU haciendo el mismo trabajo y —peor— dos contenedores podrían generar
digests distintos.

**d) La etapa entera se tira.** `build-essential`, `git`, `libpq-dev` y los
headers no llegan a la imagen final. Menos superficie de ataque y menos MB.

> ⚠️ **Gotcha real de este repo:** `BUNDLE_DEPLOYMENT=1` hace que `bundle install`
> falle si el `Gemfile.lock` no lista la plataforma del contenedor. Este lock la
> tiene:
> ```
> PLATFORMS
>   aarch64-linux-gnu   arm64-darwin        x86_64-darwin
>   x86_64-linux-gnu    x86_64-linux-musl   ...
> ```
> `x86_64-linux-gnu` es lo que necesita `ruby:3.3.6-slim`. Si trabajás sólo en una
> Mac y el lock quedara con `arm64-darwin` nada más, el build falla con "Your
> bundle only supports platforms [...]". El arreglo es
> `bundle lock --add-platform x86_64-linux`. Importa especialmente porque
> `thruster` y `tailwindcss-ruby` distribuyen **binarios precompilados por
> plataforma** (por eso no hace falta Node en la imagen para compilar Tailwind).

### Bloque 3 — la imagen final (líneas 61-77)

```dockerfile
FROM base
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
```

- **Usuario no-root con UID fijo 1000.** Si el proceso se escapa del contenedor no
  es root en el host. El UID fijo importa para los volúmenes montados: si el
  volumen del host pertenece a otro UID, el contenedor no puede escribir.
- `EXPOSE 80` porque el que escucha es **Thruster**, no Puma. Puma queda en 3000
  adentro.

### Bloque 4 — el entrypoint (`bin/docker-entrypoint`)

```bash
#!/bin/bash -e

# If running the rails server then create or migrate existing database
if [ "${@: -2:1}" == "./bin/rails" ] && [ "${@: -1:1}" == "server" ]; then
  ./bin/rails db:prepare
fi

exec "${@}"
```

Cuatro renglones con mucha carga:

1. El `if` compara **los dos últimos argumentos**. Con el `CMD` por defecto
   (`./bin/thrust ./bin/rails server`) eso da `./bin/rails` y `server`: la
   condición se cumple y corre `db:prepare`. Si arrancás el contenedor con
   `bin/jobs` o `bin/rails console`, **no** migra. Es intencional: sólo el rol web
   toca el esquema.
2. `db:prepare` = "creá la base si no existe, si existe migrá, y si acabás de
   crearla cargá `db/seeds.rb`". Es `db:setup` y `db:migrate` en uno.
3. `exec "${@}"` reemplaza el shell por el proceso real, **conservando el PID 1**.
   Sin `exec`, las señales del orquestador le llegan a bash y no a Puma, y el
   contenedor se muere por timeout en vez de drenar. Esto en un mundo Java lo
   resuelve el `ENTRYPOINT ["java", ...]` directo y nadie lo piensa; acá es un
   error clásico.
4. ⚠️ **Migrar desde el entrypoint no escala.** Si levantás 5 contenedores a la
   vez, los 5 corren `db:prepare`. Rails toma un **advisory lock** de Postgres
   antes de migrar, así que no corrompe nada, pero los perdedores mueren con:

   ```
   ActiveRecord::ConcurrentMigrationError:
   Cannot run migrations because another migration process is currently running.
   ```

   En un deploy serio las migraciones se corren **una vez**, en un paso aparte
   (§8), y el entrypoint no migra.

### `.dockerignore`

Vale leerlo: `/.env*`, `/config/master.key`, `/config/credentials/*.key`, `/.git/`,
`/public/assets`, `/.kamal`. O sea: **la master key nunca entra a la imagen**, y
`public/assets` se ignora del contexto porque se genera en el build.

---

## 5. Thruster: el proxy que viene en el `CMD`

`CMD ["./bin/thrust", "./bin/rails", "server"]`. `thrust` es un binario Go que
**envuelve** a Puma: lo arranca como hijo, escucha en 80/443 y le reenvía. Le
agrega a Puma cuatro cosas que le faltan:

- HTTP/2
- TLS automático con Let's Encrypt (si seteás `TLS_DOMAIN`)
- cache HTTP de assets públicos
- X-Sendfile y compresión gzip para archivos estáticos

Es "zero-config": no tiene archivo de configuración, se ajusta por ENV. Las que
más se usan (del README de la gema 0.1.26):

| Variable | Qué hace | Default |
|---|---|---|
| `TLS_DOMAIN` | dominios para TLS; sin esto corre en HTTP puro | ninguno |
| `TARGET_PORT` | puerto donde arranca Puma (le setea `PORT`) | `3000` |
| `HTTP_PORT` / `HTTPS_PORT` | puertos de escucha | `80` / `443` |
| `CACHE_SIZE` | tamaño del cache HTTP | 64 MB |
| `MAX_REQUEST_BODY` | rechaza bodies más grandes; `0` = sin límite | `0` |
| `HTTP_IDLE_TIMEOUT` | idle del cliente | 60 s |
| `HTTP_READ_TIMEOUT` / `HTTP_WRITE_TIMEOUT` | tiempo para mandar request / leer respuesta | 30 s |
| `FORWARD_HEADERS` | reenviar `X-Forwarded-*` y `X-Request-ID` | off con TLS, on sin TLS |
| `BAD_GATEWAY_PAGE` | HTML para el 502 mientras la app bootea | `./public/502.html` |

Cualquiera acepta el prefijo `THRUSTER_` para evitar choques con tus propias
variables.

**Por qué existe:** Puma no debería servir archivos estáticos ni terminar TLS
contra internet. La respuesta tradicional es nginx delante. Thruster es "nginx
suficiente" en un binario que no tenés que configurar y que vive **dentro del
mismo contenedor**, lo cual mantiene el modelo de un contenedor = un servicio.

**Consecuencia para el rate limiting:** con Thruster (o kamal-proxy, o un ALB)
delante, `request.ip` sin más es la IP del proxy. Por eso `config/application.rb:52`
inserta `Rack::Attack` **después** de `ActionDispatch::RemoteIp` y no en la
posición 0. El middleware stack real lo confirmás con `bin/rails middleware`:

```text
use ActionDispatch::RequestId
use ActionDispatch::RemoteIp
use Rack::Attack          # <- acá
```

⚠️ `MAX_REQUEST_BODY=0` (el default) significa **sin límite de tamaño de body**.
En una API pública eso es un vector de DoS trivial. Ponele un número.

---

## 6. Kamal

### 6.1 Estado real en este repo

Seamos precisos: **este repo tiene la gema Kamal en el `Gemfile` (línea 231,
`kamal 2.12.0`, `require: false`) pero NO tiene `config/deploy.yml`.** O sea,
nunca se corrió `kamal init`. El `.dockerignore:42-44` ya ignora
`/config/deploy*.yml` y `/.kamal` a la espera de que existan.

Lo que sigue es cómo se configuraría, con el template que la gema 2.12.0 genera de
verdad (`kamal-2.12.0/lib/kamal/cli/templates/deploy.yml`), no una invención.

### 6.2 Qué es

Kamal deploya contenedores Docker a **servidores que vos tenés por SSH**. No hay
plano de control, no hay agente, no hay cluster. Kamal corre en tu máquina (o en
el CI), se conecta por SSH, hace `docker pull` y `docker run`, y actualiza un
proxy reverso (`kamal-proxy`, otro contenedor) para que el tráfico apunte al
contenedor nuevo.

```yaml
# config/deploy.yml — la forma que tendría acá (basado en el template de kamal 2.12.0)
service: stock
image: tu-usuario/stock

servers:
  web:
    - 192.168.0.1
  job:
    hosts:
      - 192.168.0.2
    cmd: bin/jobs           # <- el worker de Solid Queue de este repo

proxy:
  ssl: true
  host: stock.example.com
  # app_port: 80            # el contenedor expone 80 (Thruster)
  # healthcheck:
  #   path: /up
  #   interval: 1
  #   timeout: 5

registry:
  server: ghcr.io
  username: tu-usuario
  password:
    - KAMAL_REGISTRY_PASSWORD    # se resuelve desde .kamal/secrets

builder:
  arch: amd64

env:
  clear:
    RAILS_MAX_THREADS: 5
    WEB_CONCURRENCY: 2
    SOLID_QUEUE_IN_PUMA: ""      # explícitamente vacío: workers aparte
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL
    - OUTBOX_WEBHOOK_SECRET

volumes:
  - "stock_storage:/rails/storage"   # Active Storage :local necesita esto

asset_path: /rails/public/assets     # ver §9

accessories:
  db:
    image: postgres:16
    host: 192.168.0.2
    port: 5432
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
  redis:
    image: valkey/valkey:8
    host: 192.168.0.2
    directories:
      - data:/data
```

### 6.3 Secretos

Los secretos **no van en `deploy.yml`**: van en `.kamal/secrets`, que es un
archivo de shell que Kamal evalúa. El template real de la gema es explícito:

```bash
# .kamal/secrets — "DO NOT ENTER RAW CREDENTIALS HERE! This file needs to be safe for git."

# Opción 1: desde el entorno
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD

# Opción 2: vía comando
RAILS_MASTER_KEY=$(cat config/master.key)

# Opción 3: vía adapters (1Password, Bitwarden, LastPass, Doppler, AWS Secrets Manager...)
SECRETS=$(kamal secrets fetch --adapter 1password --account mi-cuenta \
          --from MiVault/MiItem KAMAL_REGISTRY_PASSWORD RAILS_MASTER_KEY)
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY $SECRETS)
```

Con destinos (`kamal deploy -d staging`) hay `.kamal/secrets-common` y
`.kamal/secrets.staging`.

### 6.4 El deploy, paso a paso

`kamal deploy` hace, en orden: build de la imagen → push al registry → en cada
servidor, `docker pull` → arranca el contenedor nuevo **en paralelo al viejo** →
espera el healthcheck → le dice a `kamal-proxy` que corte el tráfico al viejo y lo
mande al nuevo → drena el viejo → lo mata.

Los defaults reales de Kamal 2.12.0 (`lib/kamal/configuration.rb:232-241`):

| Opción | Default | Qué controla |
|---|---|---|
| `readiness_delay` | `7` s | espera después de que el contenedor arranca antes de considerarlo listo |
| `deploy_timeout` | `30` s | cuánto espera el proxy a que el contenedor nuevo pase el healthcheck |
| `drain_timeout` | `30` s | cuánto espera a que terminen las requests en vuelo del contenedor viejo |
| `hooks_path` | `.kamal/hooks` | scripts `pre-deploy`, `post-deploy`, `pre-build`, etc. |
| `secrets_path` | `.kamal/secrets` | de dónde salen los secretos |

**`deploy_timeout: 30` es corto para una app Rails con eager load y `db:prepare` en
el entrypoint.** Si el boot tarda 40 segundos, el deploy falla siempre. Es el
primer valor que hay que subir en una app real.

Comandos que se usan en el día a día:

```bash
kamal setup                    # primera vez: instala docker, arranca accessories
kamal deploy                   # build + push + rollout
kamal deploy -d staging        # a otro destino
kamal redeploy                 # sin rebuild, sólo redeploy de la imagen actual
kamal rollback <version>       # vuelve a un SHA anterior (§6.6)
kamal app logs -f              # tail
kamal app logs -r job -f       # sólo el rol job
kamal app exec 'bin/rails db:migrate'          # one-off en un contenedor nuevo
kamal app exec -i --reuse 'bin/rails console'  # console interactiva en el vivo
kamal accessory reboot db
kamal proxy logs
kamal details                  # qué está corriendo dónde
```

### 6.5 Healthchecks

`proxy.healthcheck.path` es lo que pega `kamal-proxy`, y por defecto apunta a
`/up`, que en este repo está en `config/routes.rb:105`:

```ruby
get "up" => "rails/health#show", as: :rails_health_check
```

**Acá hay una trampa importante y es material de entrevista.** Ese endpoint viene
de `Rails::HealthController` y su implementación completa es:

```ruby
class HealthController < ActionController::Base
  rescue_from(Exception) { render_down }
  def show
    render_up      # renderiza un HTML verde, 200
  end
end
```

Y el propio comentario del código fuente de Rails 8.1 lo dice: *"This endpoint
does not reflect the status of all of your application's dependencies, such as the
database or Redis cluster."* Verificado a mano contra este repo:

```bash
$ curl -s -i http://127.0.0.1:3001/up | head -3
HTTP/1.1 200 OK
...
$ curl -s http://127.0.0.1:3001/up
<!DOCTYPE html><html><body style="background-color: green"></body></html>
```

O sea: **`/up` devuelve 200 aunque Postgres esté caído.** Si venís de Spring
Boot, esto es lo contrario de `/actuator/health`, que por defecto incluye
`DataSourceHealthIndicator` y se pone `DOWN` si la base no responde.

¿Cuál está bien? Depende de para qué es el check:

| Tipo de check | Qué debe verificar | Por qué |
|---|---|---|
| **Liveness** (¿reinicio el contenedor?) | sólo que el proceso responda — `/up` sirve tal cual | si chequea la base, un incidente de Postgres te reinicia en loop **toda** la flota y le agregás una tormenta de reconexiones al incidente |
| **Readiness** (¿le mando tráfico?) | app + dependencias críticas (DB) | si la base no está, mandar tráfico sólo genera 500 |

Un readiness honesto para esta app sería un controller propio que haga
`ActiveRecord::Base.connection.select_value("SELECT 1")` con timeout corto y un
chequeo de migraciones pendientes. Este repo **no lo tiene** todavía; usa el `/up`
de Rails para las dos cosas.

### 6.6 Rollback

```bash
kamal rollback 1a2b3c4     # el SHA de git de la versión anterior
```

Kamal etiqueta cada imagen con el SHA del commit y **deja los contenedores viejos
parados en el servidor** (no borrados). El rollback los vuelve a arrancar: es
cuestión de segundos porque no hay pull ni build.

⚠️ **El rollback vuelve el código, no la base.** Si el deploy que estás
revirtiendo corrió una migración destructiva (un `remove_column`, un
`rename_column`), el código viejo va a fallar contra el esquema nuevo. Es
exactamente por esto que existe expand-contract (§8): **si todas tus migraciones
son compatibles hacia atrás, el rollback siempre funciona.** Esa es la frase corta
para la entrevista.

### 6.7 Kamal vs Kubernetes vs ECS vs Heroku

| | Kamal | Kubernetes | ECS / Fargate | Heroku |
|---|---|---|---|---|
| Modelo | SSH + `docker run` | plano de control declarativo | ídem, gestionado por AWS | PaaS |
| Qué administrás | los servidores (SO, parches, Docker) | el cluster (o pagás EKS/GKE) | poco: tasks y servicios | nada |
| Estado del deploy | efímero, vive en tu CLI | reconciliación continua (un pod que muere revive) | reconciliación de AWS | reconciliación del PaaS |
| Autoescalado | ❌ no existe | ✅ HPA / cluster autoscaler | ✅ | ✅ |
| Autoreparación | ⚠️ `docker run --restart` y nada más | ✅ | ✅ | ✅ |
| Service discovery | ✅ `kamal-proxy` (básico) | ✅ Services, DNS interno | ✅ | ✅ |
| Secretos | `.kamal/secrets` + adapters | Secrets / External Secrets | Secrets Manager | config vars |
| Curva | horas | semanas | días | minutos |
| Costo típico | VPS a precio de VPS | +30-50% de overhead y una persona | premium de Fargate | el más caro por unidad |
| Cuándo | 1-20 servidores, un equipo, presupuesto real | multi-equipo, multi-servicio, tráfico variable | ya vivís en AWS | equipo chico sin ops |

**El pitch honesto de Kamal:** vuelve viable correr en hierro propio o en VPS
baratos sin construir una plataforma. **La contra honesta:** no tiene autoescalado
ni autoreparación de verdad. Si un servidor muere a las 4 AM, Kamal no hace nada;
Kubernetes reprograma el pod. Si tu carga es estacional o tu SLA no tolera
intervención manual, Kamal no es la respuesta.

Y una nota para la entrevista: 37signals migró de la nube a hierro propio con
Kamal y publicó los ahorros. Es un argumento válido, pero el trade-off es que
compraron **operación manual**. Decir eso muestra criterio; decir "Kamal es mejor
que Kubernetes" muestra lo contrario.

### 6.8 Accessories

`accessories` son contenedores de infraestructura que Kamal levanta y mantiene
pero que **no son tu app**: Postgres, Redis/Valkey, un Elasticsearch. Tienen su
propio ciclo de vida (`kamal accessory boot db`, `reboot`, `logs`) y **no se
tocan en un `kamal deploy`**.

⚠️ Usar un accessory para tu base de datos de producción es cómodo y peligroso:
te queda un Postgres en un contenedor, con los datos en un volumen del host, sin
backups automáticos, sin failover y sin réplica. Está bien para staging o para un
proyecto chico con backups probados (§11). Para producción seria, base gestionada.

---

## 7. Procesos: web, workers y cron

### 7.1 Los tres tipos

En desarrollo están todos en `Procfile.dev`:

```text
web: bin/rails server
css: bin/rails tailwindcss:watch
jobs: bin/jobs
```

`bin/dev` los arranca con foreman. En producción son **contenedores separados**
(roles de Kamal), y esa separación es el punto:

| Proceso | Comando | Escala con | Qué lo limita |
|---|---|---|---|
| web | `bin/thrust bin/rails server` | `WEB_CONCURRENCY` (procesos) x `RAILS_MAX_THREADS` | latencia de request, CPU |
| workers | `bin/jobs` | `processes:` por cola en `config/queue.yml` | profundidad de cola |
| cron | va **adentro** de `bin/jobs` | — | — |

### 7.2 El worker: `bin/jobs`

```ruby
#!/usr/bin/env ruby
require_relative "../config/environment"
require "solid_queue/cli"
SolidQueue::Cli.start(ARGV)
```

Y la configuración de producción de `config/queue.yml:60-74` es explícita sobre
cómo se reparte:

```yaml
production:
  workers:
    - queues: [ critical ]
      threads: 5
      polling_interval: 0.1
      processes: 2
    - queues: [ outbox ]
      threads: 3
      polling_interval: 0.5
      processes: 2
    - queues: [ default, mailers, maintenance, "*" ]
      threads: 5
      polling_interval: 1
      processes: 3
```

**Hacé la cuenta de conexiones, porque es donde se cae el deploy.** Ese archivo
son 2+2+3 = **7 procesos** de worker. Cada proceso abre un pool por cada base
configurada. Este repo tiene 4 bases (`primary`, `cache`, `queue`, `cable`,
`config/database.yml:119-137`) y `max_connections` atado a `RAILS_MAX_THREADS`
(default 5). En el peor caso:

```text
workers:  7 procesos x 5 conexiones x 4 bases  = 140
web:      2 procesos x 5 conexiones x 4 bases  =  40
                                        total  = 180
```

Contra el `max_connections` de Postgres, que en esta máquina es el default:

```bash
$ psql -d stock_development -c "show max_connections;"
 max_connections
-----------------
 100
```

**180 > 100.** El síntoma es `PG::ConnectionBad: FATAL: sorry, too many clients
already`, y aparece justo en el pico. Las salidas: (a) subir `max_connections` de
Postgres (cada conexión cuesta memoria: es un proceso del lado del server, no un
thread como en HikariCP); (b) **PgBouncer en modo transaction pooling**, que es la
respuesta correcta a escala; (c) bajar threads por proceso. En la práctica se hace
(b) más un poco de (c). Los pools no se abren todos de golpe (son lazy), lo cual
hace que el problema aparezca en producción y no en tu prueba.

### 7.3 El cron: `config/recurring.yml`

No hay crontab. Solid Queue tiene su propio scheduler y las tareas están
versionadas:

```yaml
expire_reservations:  { class: Stock::ExpireReservationsJob,  schedule: every minute }
publish_outbox:       { class: Outbox::PublishPendingJob,     schedule: every minute }
low_stock_scan:       { class: Stock::LowStockAlertJob,       schedule: every hour }
reconcile_balances:   { class: Stock::ReconcileBalancesJob,   schedule: every day at 3am }
cleanup:              { class: Cleanup::ExpiredRecordsJob,    schedule: every day at 4am }
```

La ventaja grande sobre `cron` del sistema está escrita en el propio archivo
(`config/recurring.yml:6-8`): **corre en una sola instancia aunque tengas 10
servidores**, porque Solid Queue elige un líder con un lock. Con `crontab` en 10
máquinas, `ReconcileBalancesJob` corre 10 veces en paralelo. Es el equivalente
Rails de `ShedLock` en Spring, y viene incluido.

⚠️ **La zona horaria**: el schedule se interpreta en `Time.zone` de la app.
`config/application.rb` **no** setea `config.time_zone`, así que es UTC. "3am" es
medianoche en Buenos Aires. Si el negocio espera el reporte a las 3 AM locales,
hay que setearlo explícitamente.

### 7.4 `SOLID_QUEUE_IN_PUMA`

```ruby
# config/puma.rb:38
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
```

Con esa variable, el supervisor de Solid Queue corre **dentro del proceso de
Puma**. Sirve para un deploy de un solo servidor: un contenedor, todo adentro.

⚠️ Y es exactamente lo que **no** querés cuando la app crece: los jobs compiten
por el mismo GVL y las mismas conexiones que las requests HTTP, un job pesado te
sube la latencia p99 del web, y no podés escalarlos por separado. Si usás roles de
Kamal (`web` y `job`), esta variable tiene que quedar **sin definir** en el rol
web.

---

## 8. Migraciones en el deploy

Este es el tema donde más gente se equivoca, y donde la analogía con Flyway se
rompe.

### 8.1 El problema de fondo

Durante un deploy sin downtime hay una ventana —de segundos o de minutos— en la
que **conviven el código viejo y el código nuevo contra la misma base**. Cualquier
migración que rompa a uno de los dos, rompe producción.

De ahí sale la única regla que importa:

> **Toda migración tiene que ser compatible con el código que está corriendo AHORA
> y con el que va a correr después.**

### 8.2 ¿Migrar antes o después de desplegar el código?

| Tipo de cambio | Orden correcto | Por qué |
|---|---|---|
| Agregar tabla / columna nullable / índice | **migrar primero**, deployar después | el código viejo ignora lo que no conoce |
| Agregar columna con `NOT NULL` | expand-contract (§8.4) | el código viejo hace `INSERT` sin esa columna y falla |
| Borrar columna / tabla | **deployar primero**, migrar después (y varios deploys) | el código viejo la sigue seleccionando |
| Renombrar | expand-contract, nunca directo | rompe a los dos lados |
| Cambiar tipo | expand-contract, columna nueva | reescribe la tabla con lock exclusivo |
| Backfill de datos | migración aparte, en lotes, después del DDL | ver §8.6 |

La regla mnemotécnica: **agregar antes, sacar después**. Y siempre "sacar" implica
al menos dos deploys.

### 8.3 `strong_migrations`: el linter que te frena

Este repo tiene la gema configurada en `config/initializers/strong_migrations.rb`,
y los valores están elegidos, no por default:

```ruby
StrongMigrations.start_after = 20260830161300      # sólo migraciones nuevas
StrongMigrations.target_version = ENV.fetch("PG_TARGET_VERSION", 16)
StrongMigrations.lock_timeout = 10.seconds
StrongMigrations.statement_timeout = 1.hour
StrongMigrations.lock_timeout_limit = 10.seconds
```

**`lock_timeout = 10.seconds` es la línea que evita la caída en cascada**, y el
mecanismo hay que poder explicarlo: en Postgres, un `ALTER TABLE` pide un
`ACCESS EXCLUSIVE` lock. Si hay una transacción larga abierta sobre esa tabla, el
`ALTER` **se encola**. Y acá está lo contraintuitivo: **un lock encolado bloquea a
todos los que llegan después**, incluidos los `SELECT`. Con lo cual tu app se cae
*antes* de que la migración empiece siquiera. Con `lock_timeout`, la migración se
rinde a los 10 segundos y no se lleva puesto al sitio.

Este repo además tiene ese mismo timeout en la sesión normal de la app
(`config/database.yml:52-55`):

```yaml
variables:
  statement_timeout: 15000                    # ms
  lock_timeout: 10000                         # ms
  idle_in_transaction_session_timeout: 30000  # ms
```

`idle_in_transaction_session_timeout` es el que mata transacciones zombie — que
son, justamente, la causa #1 de que una migración se quede esperando un lock.

El catálogo de operaciones peligrosas está escrito en el initializer
(`config/initializers/strong_migrations.rb:17-41`). Las dos que más se preguntan:

```ruby
# ❌ bloquea las escrituras durante toda la construcción del índice
add_index :stock_movements, :occurred_at

# ✅
class AddIndexToStockMovements < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!          # CONCURRENTLY no puede correr en una transacción
  def change
    add_index :stock_movements, :occurred_at, algorithm: :concurrently
  end
end
```

`CONCURRENTLY` tarda aproximadamente el doble y, si falla, deja el índice en
estado **`INVALID`**: hay que borrarlo (`DROP INDEX`) y rehacerlo. Chequealo con:

```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
```

### 8.4 Expand-contract, con el caso concreto de este repo

Supongamos que hay que renombrar `stock_movements.reason` a
`stock_movements.movement_reason`. **Cuatro deploys.**

```ruby
# Deploy 1 — EXPAND: agregar la columna nueva, nullable, sin default.
class AddMovementReasonToStockMovements < ActiveRecord::Migration[8.1]
  def change
    add_column :stock_movements, :movement_reason, :string
  end
end
```

```ruby
# Deploy 2 — escribir en las DOS, leer de la VIEJA.
class StockMovement < ApplicationRecord
  before_save { self.movement_reason = reason }
end
```

```ruby
# Deploy 2b — BACKFILL, en una migración aparte y en lotes.
class BackfillMovementReason < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!          # sin transacción envolvente: lotes independientes

  def up
    StockMovement.unscoped.where(movement_reason: nil).in_batches(of: 5_000) do |batch|
      batch.update_all("movement_reason = reason")
      sleep 0.05                    # dejale aire al autovacuum y a las réplicas
    end
  end

  def down = nil
end
```

```ruby
# Deploy 3 — leer de la NUEVA, seguir escribiendo en las dos.
# Deploy 4 — CONTRACT: dejar de escribir la vieja, y recién ahora:
class RemoveReasonFromStockMovements < ActiveRecord::Migration[8.1]
  def change
    safety_assured { remove_column :stock_movements, :reason, :string }
  end
end
```

⚠️ **Antes del `remove_column` hay un paso que casi todos se olvidan:**

```ruby
class StockMovement < ApplicationRecord
  self.ignored_columns += ["reason"]
end
```

Sin eso, ActiveRecord sigue incluyendo `reason` en el `SELECT` porque el esquema
lo tiene cacheado, y entre el `DROP COLUMN` y el reinicio de los procesos web te
comés `PG::UndefinedColumn`. `ignored_columns` va en **un deploy anterior** al
`remove_column`.

> **Dónde se rompe la analogía con Java:** en Hibernate, el mapeo entidad↔tabla es
> explícito (`@Column`), y si sacás una columna que la entidad declara, el
> `hbm2ddl.auto=validate` te lo dice **al arrancar**. En ActiveRecord no hay
> mapeo: el modelo **descubre** las columnas consultando el catálogo de Postgres
> en el primer uso. Eso significa dos cosas: (1) no tenés validación de esquema al
> boot, y (2) el esquema queda cacheado en el proceso, así que un cambio de
> columna necesita **reiniciar los procesos** para que se vea. `ignored_columns`
> es el parche para la ventana en la que las dos cosas chocan.

### 8.5 Migración larga: qué hacer

Si la migración tarda más que tu `deploy_timeout`, sacala del camino crítico del
deploy:

1. **Separá DDL de DML.** El `ALTER` va en una migración (rápida, con
   `lock_timeout`); el backfill va en otra (lenta, en lotes, sin transacción).
2. **Corré el backfill como un job**, no como migración: `Cleanup::ExpiredRecordsJob`
   (`app/jobs/cleanup/expired_records_job.rb`) es exactamente el patrón —
   `in_batches` + `delete_all`, con la explicación del bloat de Postgres en el
   comentario de las líneas 8-21. Un backfill se escribe igual, con `update_all`.
3. **Hacela idempotente y reanudable**: `where(movement_reason: nil)` te deja
   volver a correr el job si murió a la mitad.
4. **Nunca `Modelo.find_each` con callbacks** para un backfill de millones de
   filas: instancia objetos y corre validaciones que no necesitás. `update_all` va
   directo al SQL.

### 8.6 Rollback de datos

`bin/rails db:rollback` existe y es una trampa cómoda. Tres realidades:

- **`down` casi nunca es el inverso real.** `remove_column` en un `change`
  revierte creando la columna, pero **los datos no vuelven**. Lo mismo un
  `update_all`.
- **En producción no se hace rollback de migración: se hace roll-forward.**
  Escribís una migración nueva que arregla. El historial de `schema_migrations`
  queda coherente y no hay ambigüedad sobre qué corrió.
- **Antes de una migración destructiva, backup verificado** (§11), y si podés,
  copiá los datos a una tabla temporal en la misma migración:
  `CREATE TABLE stock_movements_reason_backup AS SELECT id, reason FROM stock_movements`.

Y `config.active_record.dump_schema_after_migration = false` en
`production.rb:77`: en producción no se regenera `db/schema.rb` (el contenedor no
debería escribir en el repo). En dev sí, y **el `schema.rb` se commitea**: el CI de
este repo corre `bin/rails db:test:prepare`, que carga el schema en vez de correr
las migraciones una por una — lo cual, además de ser más rápido, **detecta si
alguien commiteó una migración sin regenerar el schema** (está explicado en el
comentario de `.github/workflows/ci.yml`).

---

## 9. Assets: Propshaft, digests y CDN

### 9.1 Propshaft, no Sprockets

Rails 8 genera apps con **Propshaft** (acá `propshaft 1.3.2`, `Gemfile:43`). La
diferencia con Sprockets es grande y conviene tenerla clara: Sprockets era un
pipeline de transformación (compilaba CoffeeScript, SASS, concatenaba con
`//= require`, minificaba). Propshaft **no transforma nada**: copia los archivos,
les pone un digest en el nombre y reescribe las referencias. La transformación,
si hace falta, la hace otra herramienta.

En este repo la otra herramienta es `tailwindcss-rails 4.6.0`, que trae un
**binario Go** (`tailwindcss-ruby`) — por eso no hay Node en el `Dockerfile`. Y se
engancha solo al precompile:

```ruby
# tailwindcss-rails-4.6.0/lib/tasks/build.rake:36
Rake::Task["assets:precompile"].enhance(["tailwindcss:build"])
```

El JavaScript va por **importmap** (`importmap-rails`, `Gemfile:47`): no hay
bundler de JS, el navegador resuelve los módulos. Por eso el CI tiene un job
`scan_js` que corre `bin/importmap audit`.

### 9.2 El precompile, corrido de verdad

```bash
$ SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails assets:precompile
...
Writing turbo.min-9fd88cd5.js
Writing action_cable-5212cfee.js
...
```

Y el manifiesto que queda en `public/assets/.manifest.json`:

```json
{"tailwind.css":{"digested_path":"tailwind-7f74a9b4.css","integrity":null},
 "application.css":{"digested_path":"application-8b441ae0.css","integrity":null},
 "application.js":{"digested_path":"application-bfcdf840.js","integrity":null}}
```

Ese mapa es lo que usa `stylesheet_link_tag "application"` para emitir
`/assets/application-8b441ae0.css`. El digest es un hash del **contenido**: si el
archivo cambia, el nombre cambia. Eso es lo que habilita la línea de
`production.rb:19`:

```ruby
config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }
```

Cachear un año es seguro **porque el nombre cambia con el contenido**. Es
cache-busting por convención, no por `?v=123`.

### 9.3 CDN

```ruby
# config/environments/production.rb:22 — comentado en este repo
# config.asset_host = "http://assets.example.com"
```

Con eso, todos los helpers emiten URLs absolutas al CDN. El CDN hace *origin pull*
contra tu app la primera vez y después sirve del edge. Con `max-age=1.year` y
digests, es la configuración de CDN más simple que existe: no hay invalidación que
hacer.

### 9.4 El 404 de assets en el deploy (y `asset_path` de Kamal)

Este es el bug sutil que cuesta encontrar. Secuencia:

1. Un usuario carga la página. El HTML referencia `application-AAAA.css`.
2. Deployás. Los contenedores nuevos tienen `application-BBBB.css`; los viejos se
   apagan.
3. El navegador del usuario, con el HTML viejo en pantalla, pide
   `application-AAAA.css` → **404**. La página queda sin estilos, o un Turbo Frame
   explota.

La solución de Kamal es la clave `asset_path` del `deploy.yml`. El template lo
documenta así: *"Bridge fingerprinted assets, like JS and CSS, between versions to
avoid hitting 404 on in-flight requests. Combines all files from new and old
version inside the asset_path."* Kamal monta un directorio en el host y **fusiona**
los assets de la versión vieja y la nueva, así que `AAAA` sigue existiendo durante
la transición.

```yaml
asset_path: /rails/public/assets
```

El equivalente sin Kamal es servir los assets desde un CDN/S3 al que subís antes de
rotar los contenedores, y no borrar la versión anterior por unas horas.

---

## 10. Zero-downtime de verdad

### 10.1 Las señales de Puma

`config/puma.rb` de este repo es el generado por Rails 8, con dos cosas
importantes: **no declara `workers` ni `preload_app!`**.

```ruby
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count
port ENV.fetch("PORT", 3000)
plugin :tmp_restart
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
```

Que no declare `workers` **no significa que no haya workers**: Puma lee
`WEB_CONCURRENCY` del entorno por su cuenta
(`puma-8.0.2/lib/puma/configuration.rb:248`). Sin la variable, `workers` es 0 y
arranca en *single mode* (lo verifiqué levantando el server: `Puma starting in
single mode...`).

Señales:

| Señal | Qué hace |
|---|---|
| `SIGTERM` | **stop graceful**: deja de aceptar conexiones nuevas, termina las en vuelo, sale |
| `SIGINT` | igual que TERM (es el Ctrl-C) |
| `SIGUSR2` | **hot restart**: reinicia el master entero. Hay una ventana de ~1-3 s sin servicio |
| `SIGUSR1` | **phased restart**: reinicia los workers de a uno. Sin ventana |
| `SIGHUP` | reabre los logs |

**Y acá está la trampa que casi nadie sabe:** el phased restart **no está
disponible si `preload_app` está activo**. Puma lo dice en el log del arranque en
cluster mode (`puma-8.0.2/lib/puma/cluster.rb:378,396`):

```text
*     Restarts: (✔) hot (✖) phased (✖) refork      # con preload
*     Restarts: (✔) hot (✔) phased (✖) refork      # sin preload
```

Y `preload_app` **se activa solo** cuando hay más de un worker
(`configuration.rb:499`): `preload_app = !prune_bundler && workers > 1 &&
Puma.forkable?`. O sea: apenas ponés `WEB_CONCURRENCY=2`, ganás copy-on-write y
**perdés el phased restart**. Es un trade-off real:

| | Con `preload_app` | Sin `preload_app` |
|---|---|---|
| Memoria | menor (COW entre workers) | mayor (cada worker carga todo) |
| Phased restart | ❌ | ✅ |
| Boot | una vez en el master | una vez por worker |
| Conexiones a DB | hay que reconectar en `on_worker_boot` | cada worker abre las suyas |

**En un deploy con contenedores el phased restart es irrelevante**, y por eso el
Rails 8 moderno no se preocupa: no reiniciás el proceso, levantás un contenedor
nuevo al lado y rotás el tráfico. El phased restart importa cuando deployás con
Capistrano sobre procesos de larga vida.

### 10.2 Drenaje de conexiones

La secuencia correcta de un rollout, en orden:

1. El proxy **deja de mandar tráfico nuevo** al contenedor viejo.
2. Recién **después** le manda `SIGTERM`.
3. Puma termina las requests en vuelo y sale.

Si invertís 1 y 2 —mandar TERM primero— las requests que ya estaban en el aire de
la conexión keep-alive se cortan y el usuario ve un 502. En Kamal esto lo maneja
`kamal-proxy` con `drain_timeout` (default **30 s**). El número tiene que ser
**mayor que tu request más lenta**; si tenés un endpoint que genera un reporte en
45 s, subilo o sacá ese endpoint del web y hacelo un job.

⚠️ El `exec` del `bin/docker-entrypoint` es lo que hace que todo esto funcione: sin
él, el `SIGTERM` de Docker le llega a bash (PID 1) y Puma nunca se entera; a los 10
segundos Docker manda `SIGKILL` y cortás requests a lo bruto.

### 10.3 Jobs en vuelo

Solid Queue maneja las señales así
(`solid_queue-1.7.0/lib/solid_queue/supervisor/signals.rb:42-46`):

| Señal | Comportamiento |
|---|---|
| `TERM` / `INT` | `stop` + **terminación graceful**: espera a que los jobs en curso terminen |
| `QUIT` | terminación **inmediata** |

Y el default que hay que conocer (`lib/solid_queue.rb:35`):

```ruby
mattr_accessor :shutdown_timeout, default: 5.seconds
```

**Cinco segundos.** Pasado ese plazo, el supervisor marca
`shutdown_timeout_exceeded` y mata los procesos
(`supervisor.rb:114-122`). Si tus jobs tardan más de 5 segundos —y en esta app,
`Outbox::PublishPendingJob` con un webhook de `timeout: 5` puede tardar
tranquilamente más— **te van a matar jobs a mitad de camino en cada deploy**.

¿Qué pasa con un job matado a la mitad? Solid Queue lo tiene resuelto, pero con
una latencia que hay que saber:

```ruby
# solid_queue-1.7.0/lib/solid_queue.rb
mattr_accessor :process_heartbeat_interval, default: 60.seconds
mattr_accessor :process_alive_threshold,    default: 5.minutes
```

Cada worker late cada 60 s en `solid_queue_processes`. Cuando deja de latir por
más de 5 minutos, el supervisor lo poda, y sus filas de
`solid_queue_claimed_executions` quedan **huérfanas** (el scope literal es
`where.missing(:process)`) y se liberan para que otro worker las tome. O sea:
**un job interrumpido se reintenta, pero puede tardar hasta 5 minutos en volver a
estar disponible.**

La conclusión de diseño es la de siempre y vale repetirla: **los jobs tienen que
ser idempotentes**, porque `at-least-once` es la garantía real. El comentario de
`app/jobs/outbox/publish_pending_job.rb:12-17` lo dice mejor: *"exactly-once
delivery no existe; lo que existe es at-least-once delivery + idempotent
processing"*.

Para el deploy, tres cosas concretas:

```ruby
# config/initializers/solid_queue.rb  (NO existe todavía en este repo)
SolidQueue.shutdown_timeout = 25.seconds   # menor que el SIGKILL del orquestador
```

1. Subí `shutdown_timeout` a algo mayor que tu job p99 y **menor** que el plazo
   que te da el orquestador antes del `SIGKILL`.
2. Partí los jobs largos en pasos chicos con checkpoint.
3. Ordená el rollout: **primero** los workers, **después** el web. Si deployás el
   web primero, hay una ventana en la que workers viejos toman jobs con payloads
   nuevos (un argumento que la versión vieja del job no sabe leer). Como el
   payload de Active Job es JSON serializado con la firma del método, agregar un
   argumento posicional a un job **rompe a los workers viejos**. Por eso los
   argumentos de job se agregan siempre como **keyword con default**.

### 10.4 Checklist de un deploy sin downtime

```text
[ ] La migración es compatible hacia atrás (§8.2)
[ ] Ninguna firma de job cambió de forma incompatible
[ ] deploy_timeout > tiempo de boot (eager_load + db:prepare)
[ ] drain_timeout > request p99
[ ] shutdown_timeout de Solid Queue > job p99
[ ] asset_path configurado (bridge de assets)
[ ] El healthcheck no está detrás de force_ssl sin exclusión
[ ] Sabés cómo hacer rollback y probaste que funciona
```

---

## 11. Backups y restore de PostgreSQL

### 11.1 Las dos estrategias

| | `pg_dump` | PITR (WAL archiving) |
|---|---|---|
| Qué es | export lógico (SQL o formato custom) | copia física + archivado continuo del WAL |
| Granularidad | el instante del dump | **cualquier punto en el tiempo** |
| RPO típico | lo que dure entre dumps (horas) | segundos |
| RTO | proporcional al tamaño; restore lento | montar la base + replay del WAL |
| Cambia de versión mayor de PG | ✅ sí (es SQL) | ❌ no (formato binario) |
| Restaura una sola tabla | ✅ trivial | ❌ hay que restaurar todo |
| Costo operativo | bajo | alto (`pgBackRest`, `WAL-G`, o el servicio gestionado) |
| Impacto en el server | un `pg_dump` grande genera I/O y mantiene un snapshot | continuo, bajo |

**La respuesta correcta en una entrevista: los dos.** PITR para el desastre
(alguien corrió `DELETE FROM stock_movements` sin `WHERE` a las 14:32; querés
volver a las 14:31) y `pg_dump` para lo cotidiano (levantar un staging, recuperar
una tabla, migrar de versión).

Nota específica de este dominio: `stock_movements` es un **ledger append-only**
(ver `docs/03`). Eso te da una propiedad enorme para recuperación: si la
proyección `stock_items` se corrompe, **la podés reconstruir sumando el ledger**,
que es exactamente lo que hace `Stock::ReconcileBalancesJob`
(`app/jobs/stock/reconcile_balances_job.rb`, agendado a las 3 AM en
`config/recurring.yml:32-34`). El backup te protege del "perdí el ledger"; el
ledger te protege del "se desincronizó la proyección". Son dos capas distintas y
poder distinguirlas es una buena señal.

### 11.2 El dump y el restore, corridos de verdad

```bash
$ time pg_dump -Fc -d stock_development -f /tmp/stock.dump
real    0m0.143s

$ ls -lh /tmp/stock.dump
-rw-r--r-- 1 root root 102K /tmp/stock.dump
```

`-Fc` (formato custom) es lo que querés casi siempre: comprimido, y permite
`pg_restore -j N` en paralelo y restore selectivo de tablas.

El restore, contra una base limpia:

```bash
$ createdb stock_restore_test
$ pg_restore -d stock_restore_test --no-owner /tmp/stock.dump

$ psql -d stock_restore_test -c "select count(*) from stock_movements;"
 count
-------
   106

$ psql -d stock_restore_test -c "select column_name, is_generated, generation_expression
    from information_schema.columns
    where table_name='stock_items' and column_name='quantity_available';"
    column_name     | is_generated |         generation_expression
--------------------+--------------+----------------------------------------
 quantity_available | ALWAYS       | (quantity_on_hand - quantity_reserved)
```

Los 106 movimientos volvieron y —el punto importante— **la columna generada volvió
como columna generada**, no como una columna común con valores copiados. Si eso no
funcionara, la invariante `quantity_available = on_hand - reserved` dejaría de
mantenerse sola y nadie se enteraría hasta que los números no cerraran.

### 11.3 Por qué HAY que probar el restore

Un backup que nunca restauraste no es un backup: es un archivo. Las formas
concretas en que fallan, y que sólo descubrís probando:

- **Extensiones.** `db/migrate/20260830154900_enable_postgres_extensions.rb` habilita
  `citext`, `pg_trgm` y `btree_gin`. El comentario del archivo ya avisa que
  `CREATE EXTENSION` **requiere superusuario** y que los servicios gestionados
  tienen allow-list. Un `pg_restore` con un usuario sin ese permiso falla en la
  primera línea. En este repo importa doble: `sku` es `citext`, así que sin la
  extensión ni siquiera se crea la tabla.
- **Roles y ownership.** El dump referencia roles que en el destino no existen.
  Por eso usé `--no-owner`.
- **Secuencias.** Un restore parcial hecho a mano puede dejar la secuencia atrás y
  el primer `INSERT` choca con la PK.
- **El backup estaba vacío.** El cron corría, el archivo se creaba, pesaba 200
  bytes porque `pg_dump` fallaba y nadie miraba el exit code. Es el modo de falla
  más común y el más estúpido.
- **El tiempo.** Sabés que el restore "funciona" pero no que tarda 6 horas, y tu
  SLA dice 1.

Lo que hay que automatizar: un job semanal que restaure el último backup en una
base descartable, corra `SELECT count(*)` sobre las tablas clave y **compare
contra los números esperados**, y avise si no cierra. Si además corrés una
verificación de consistencia (que la suma del ledger dé la proyección), mucho
mejor.

---

## 12. CI: el workflow real y qué le falta

`.github/workflows/ci.yml` tiene **cuatro jobs** que corren en paralelo:

| Job | Qué corre | Para qué |
|---|---|---|
| `scan_ruby` | `bin/brakeman --no-pager` y `bin/bundler-audit` | análisis estático de seguridad + CVEs en gemas |
| `scan_js` | `bin/importmap audit` | CVEs en las dependencias JS del importmap |
| `lint` | `bin/rubocop -f github` (con cache) | estilo |
| `test` | `bin/rails db:test:prepare` + `bundle exec rspec` | la suite |

Tres detalles del job `test` que están bien pensados y explicados en el propio
archivo:

```yaml
services:
  postgres:
    image: postgres:16
    options: >-
      --health-cmd="pg_isready -U postgres"
      --health-interval=10s --health-timeout=5s --health-retries=5
```

**El `--health-cmd` es crítico.** Sin él, el job arranca antes de que Postgres
acepte conexiones y falla de forma intermitente: el clásico test *flaky* que "sólo
falla en CI".

```yaml
env:
  RAILS_MAX_THREADS: 15
```

Pool más grande que los threads, porque los specs de concurrencia levantan threads
reales (misma lógica que `config/database.yml:96-101`).

```yaml
- name: Upload failure screenshots
  if: failure()
  uses: actions/upload-artifact@v4
  with: { name: capybara-screenshots, path: tmp/capybara/ }
```

Sin los screenshots, debuggear un system test que sólo falla en CI es adivinar.

Además hay un `bin/ci` (Rails 8 trae `ActiveSupport::ContinuousIntegration`) que
corre la misma secuencia localmente, definida en `config/ci.rb`:

```ruby
CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
end
```

### Qué le agregaría, en orden de valor

1. **`bin/rails zeitwerk:check`.** Segundos de costo, y atrapa la causa #1 de "anda
   en dev, rompe en prod" (§2.2). Es lo primero.
2. **Un job de build de la imagen Docker en los PRs.** Hoy el `Dockerfile` no se
   valida nunca en CI. Un cambio en el `Gemfile` que rompa `bundle install` bajo
   `BUNDLE_DEPLOYMENT=1`, o una plataforma faltante en el lock, se descubre recién
   al deployar.
3. **Chequeo de migraciones peligrosas.** `strong_migrations` frena en desarrollo,
   pero si alguien lo saltea con `safety_assured` el CI no dice nada. Un job que
   corra las migraciones nuevas contra una copia del schema de producción con
   `lock_timeout` bajo sería mejor.
4. **`bin/rails db:migrate` sobre el schema actual y diff del `schema.rb`.**
   Detecta el "commiteé la migración pero no el schema" de forma explícita.
5. **Fallar por cobertura.** El job ya genera `coverage/` con SimpleCov y lo sube
   como artifact, pero **no falla** si baja. Un umbral mínimo lo hace útil.
6. **`concurrency: cancel-in-progress`.** Hoy cada push a un PR arranca los cuatro
   jobs completos sin cancelar los anteriores.
7. **Deploy automático desde `main`** con `kamal deploy`, una vez que exista
   `config/deploy.yml`.

---

## 13. Runbook

Cuatro incidentes concretos, con los comandos.

### (a) La base está saturada

**Síntomas:** latencia p99 por las nubes, `ActiveRecord::ConnectionTimeoutError`
en los logs del web, `PG::ConnectionBad: FATAL: sorry, too many clients already`.

```sql
-- 1. ¿Cuántas conexiones y de quién?
SELECT state, count(*), max(now() - state_change) AS mas_vieja
FROM pg_stat_activity WHERE datname = current_database()
GROUP BY state ORDER BY 2 DESC;

SELECT setting FROM pg_settings WHERE name = 'max_connections';

-- 2. ¿Hay transacciones zombie? (idle in transaction es EL veneno)
SELECT pid, now() - xact_start AS duracion, state, left(query, 120)
FROM pg_stat_activity
WHERE state = 'idle in transaction' AND xact_start < now() - interval '1 minute'
ORDER BY xact_start;

-- 3. ¿Quién bloquea a quién?
SELECT blocked.pid AS bloqueado, blocking.pid AS bloqueante,
       left(blocked.query, 80) AS q_bloqueada, left(blocking.query, 80) AS q_bloqueante
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
JOIN pg_stat_activity blocking ON blocking.pid = b.pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;

-- 4. Matar la ofensora (cancel es amable, terminate no)
SELECT pg_cancel_backend(12345);
SELECT pg_terminate_backend(12345);
```

**Mitigación inmediata:** bajar `WEB_CONCURRENCY` o la cantidad de procesos de
worker (`config/queue.yml`) para reducir conexiones. Si el problema es una query
concreta, el `statement_timeout: 15000` de `config/database.yml:53` ya la debería
estar matando — si no lo está haciendo, es una query que corre desde un proceso
que no usa ese YAML (una consola, un `psql` manual, un backup).

**Arreglo de fondo:** PgBouncer en transaction pooling. Multiplica por 10 la
cantidad de clientes que soporta el mismo Postgres. Contras a mencionar: en modo
transaction **no podés usar prepared statements** sin cuidado (hay que setear
`prepared_statements: false` en `database.yml`), ni advisory locks de sesión, ni
`LISTEN/NOTIFY`.

### (b) La cola creció

**Síntomas:** `Outbox::PublishPendingJob` acumula, los usuarios no ven efectos de
sus acciones, `solid_queue_ready_executions` crece monótonamente.

```sql
-- Profundidad por cola (base "queue", no la primary)
SELECT queue_name, count(*) FROM solid_queue_ready_executions GROUP BY 1 ORDER BY 2 DESC;

-- ¿Cuánto hace que espera el más viejo?
SELECT queue_name, min(created_at), now() - min(created_at) AS espera
FROM solid_queue_ready_executions GROUP BY 1;

-- ¿Los workers están vivos? (heartbeat cada 60 s)
SELECT name, kind, last_heartbeat_at, now() - last_heartbeat_at AS desde
FROM solid_queue_processes ORDER BY last_heartbeat_at;

-- Fallidos
SELECT count(*) FROM solid_queue_failed_executions;
```

**Árbol de decisión:**

1. **¿Hay workers?** Si `solid_queue_processes` está vacío o los heartbeats son
   viejos, el contenedor `job` está caído. Arrancalo. Esta es la causa más común y
   la más tonta.
2. **¿Están vivos pero no avanzan?** Mirá si hay un job "poison" que reintenta en
   loop. `Outbox::PublishPendingJob` ya está blindado contra esto: el `rescue`
   por evento (`app/jobs/outbox/publish_pending_job.rb:48-56`) marca el evento
   fallido y sigue con los demás, en vez de dejar que uno solo tape la cola.
3. **¿Están vivos y avanzan, pero llega más de lo que sale?** Es capacidad. Subí
   `processes:` de esa cola en `config/queue.yml` y redeployá el rol `job`. Ojo con
   la cuenta de conexiones (§7.2).
4. **¿Los jobs son lentos por la base?** Volvé a (a). Una cola que crece suele ser
   el *síntoma*, no la causa.

Todo esto se ve también en Mission Control, montado en `/jobs`
(`config/routes.rb:114`) detrás de un `constraints` que exige sesión de admin.

### (c) Deadlock recurrente

**Síntomas:** `PG::TRDeadlockDetected: ERROR: deadlock detected` intermitente, casi
siempre bajo carga.

```sql
-- Postgres loguea el deadlock con las dos queries involucradas.
-- Si no lo estás viendo en el log, prendé esto (recarga sin reinicio):
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET deadlock_timeout = '1s';
SELECT pg_reload_conf();
```

**La causa es siempre la misma:** dos transacciones toman los mismos locks **en
orden distinto**. En esta app el caso natural es una transferencia entre depósitos:
T1 bloquea `stock_items` del depósito A y después B; T2 bloquea B y después A.

**El arreglo es siempre el mismo también: ordená los locks.** Un criterio total y
determinístico —`ORDER BY id` sobre las filas a bloquear— elimina la clase entera
de deadlocks. Es el mismo principio de "lock ordering" que aplicás con
`synchronized` en Java, sólo que acá el lock es una fila de Postgres.

```ruby
# El patrón: bloquear SIEMPRE en el mismo orden
items = StockItem.where(id: [origen_id, destino_id]).order(:id).lock.to_a
```

Complementos: mantené las transacciones **cortas** (nada de HTTP adentro de una
transacción), y `lock_timeout: 10000` (`config/database.yml:54`) para fallar
rápido en vez de esperar. Y del lado de la app, reintentar con backoff: un
deadlock es un error **transitorio**, Postgres mata a una de las dos transacciones
y la otra sigue. Detalle completo en `docs/06-concurrencia-transacciones-y-locking.md`.

### (d) El outbox no publica

**Síntomas:** `outbox_events` con `published_at IS NULL` creciendo; los sistemas
que consumen no ven nada.

```sql
-- 1. ¿Cuántos pendientes y desde cuándo?
SELECT count(*) FILTER (WHERE published_at IS NULL) AS pendientes,
       min(occurred_at) FILTER (WHERE published_at IS NULL) AS mas_viejo,
       count(*) FILTER (WHERE attempts >= 10) AS trabados
FROM outbox_events;

-- 2. ¿Por qué fallan? last_error tiene el mensaje
SELECT event_type, attempts, left(last_error, 160), count(*)
FROM outbox_events
WHERE published_at IS NULL AND last_error IS NOT NULL
GROUP BY 1,2,3 ORDER BY 4 DESC LIMIT 20;
```

**Diagnóstico, en orden:**

1. **¿Está corriendo el job?** `publish_outbox` está agendado *every minute* en
   `config/recurring.yml:24-26` y `queue_as :outbox`. Si el worker de la cola
   `outbox` no está levantado (`config/queue.yml` define `processes: 2` para ella
   en producción), no publica nadie. Chequealo con la query de heartbeats de (b).
2. **¿El adapter es el correcto?** `OUTBOX_ADAPTER` por defecto es **`log`**
   (`app/services/outbox/publisher.rb:26`), que escribe al logger y **marca el
   evento como publicado**. Si esperabas webhooks y la variable no está seteada, el
   sistema "funciona" y no llega nada a ningún lado. Es el bug silencioso de este
   módulo.
3. **¿El destino responde?** Con `OUTBOX_ADAPTER=webhook`, `WebhookAdapter` tira
   `DeliveryError` con el código HTTP (`publisher.rb:80`), y eso queda en
   `last_error`. Un 401 es firma/secreto; un timeout es el `timeout: 5` del
   adapter.
4. **¿Hay eventos trabados?** El modelo define `MAX_ATTEMPTS = 10` y
   `claim_batch` filtra `where(attempts: ...MAX_ATTEMPTS)`
   (`app/models/outbox_event.rb:27-33`): pasados 10 intentos, el evento **deja de
   intentarse para siempre** y sólo se ve con el scope `stuck`. Esto es
   deliberado (no tapa la cola) pero significa que **hay que monitorearlo**: si
   nadie mira `OutboxEvent.stuck`, esos eventos se pierden en silencio.

**Reproceso manual** después de arreglar la causa:

```ruby
# bin/rails runner (o kamal app exec -i --reuse 'bin/rails console')
OutboxEvent.stuck.update_all(attempts: 0, last_error: nil)
Outbox::PublishPendingJob.perform_later
```

⚠️ Antes de resetear, acordate de la garantía: la entrega es **at-least-once** y
los consumidores deduplican por `event_id`
(`app/jobs/outbox/publish_pending_job.rb:12-17`). Si el consumidor **no** deduplica,
reprocesar 5.000 eventos le va a duplicar 5.000 operaciones. Verificá eso primero.

**Métrica que hay que tener en el dashboard:** la edad del evento pendiente más
viejo. Es una señal mucho mejor que la cantidad de pendientes: 10.000 pendientes de
hace 30 segundos es un pico normal; 3 pendientes de hace 4 horas es un incidente.

---

## Errores que ves en producción

| Síntoma | Causa | Arreglo |
|---|---|---|
| `ActiveSupport::MessageEncryptor::InvalidMessage` en el boot, sin más mensaje | la `RAILS_MASTER_KEY` del server no corresponde al `credentials.yml.enc` de la imagen | poner la llave correcta; si rotaste, actualizá el secreto **antes** de deployar |
| `ActiveSupport::EncryptedFile::MissingKeyError` | no hay `RAILS_MASTER_KEY` ni `config/master.key` (el `.dockerignore:14` la excluye de la imagen a propósito) | inyectarla por ENV en runtime |
| Booteaba en dev y en prod `NameError: uninitialized constant` | `eager_load = true` toca todo; archivo mal nombrado para Zeitwerk, o gema del grupo `development` (`BUNDLE_WITHOUT`) | `bin/rails zeitwerk:check` en el CI; revisar en qué grupo está la gema |
| `PG::ConnectionBad: FATAL: sorry, too many clients already` | procesos x threads x **4 bases** supera `max_connections` (§7.2) | PgBouncer, o bajar `WEB_CONCURRENCY`/`processes` |
| `ActiveRecord::ConcurrentMigrationError` en el deploy | varios contenedores corriendo `db:prepare` desde `bin/docker-entrypoint` a la vez | migrar una sola vez en un paso aparte (`kamal app exec 'bin/rails db:migrate'`) |
| El deploy se queda colgado y hace rollback solo | el boot tarda más que `deploy_timeout` (default **30 s** en Kamal) | subir `deploy_timeout`; sacar `db:prepare` del entrypoint |
| El healthcheck da 301 y el contenedor nunca queda sano | `force_ssl` prendido sin la exclusión de `/up` (`production.rb:34`) | descomentar `config.ssl_options` con el `exclude` |
| Assets 404 justo después del deploy, la página queda sin estilos | el HTML viejo pide `application-AAAA.css` y los contenedores nuevos sólo tienen `BBBB` | `asset_path` en `deploy.yml` (Kamal fusiona versiones), o CDN con retención |
| `PG::UndefinedColumn` unos segundos después de una migración | `remove_column` sin `ignored_columns` en un deploy previo; el esquema quedó cacheado en los procesos vivos | expand-contract: `ignored_columns` primero, `remove_column` en el deploy siguiente |
| Jobs que se pierden o se rehacen en cada deploy | `shutdown_timeout` de Solid Queue es **5 s** por default; los jobs se matan a la mitad y tardan hasta 5 min (`process_alive_threshold`) en liberarse | subir `shutdown_timeout`, hacer los jobs idempotentes, deployar workers antes que web |
| 502 durante el rollout | el proxy mandó `SIGTERM` antes de cortar el tráfico, o `exec` faltante en el entrypoint y la señal no llegó a Puma | respetar el orden (cortar tráfico → TERM → drenar); `exec "${@}"` |
| Archivos subidos que desaparecen | `active_storage.service = :local` en `production.rb:25`, disco efímero del contenedor | volumen persistente, o S3 |
| Un job "cron" corre N veces | crontab replicado en N máquinas | `config/recurring.yml` de Solid Queue (elige líder con lock) |
| El outbox "publica" pero no llega nada | `OUTBOX_ADAPTER` sin setear ⇒ `log`, que marca los eventos como publicados | setear `OUTBOX_ADAPTER=webhook` y alertar sobre `OutboxEvent.stuck` |
| Migración que tumba el sitio antes de empezar | un `ALTER` esperando un lock encola a todos los `SELECT` detrás suyo | `StrongMigrations.lock_timeout = 10.seconds` (ya está); `CONCURRENTLY` para índices |
| El restore falla en la primera línea | `CREATE EXTENSION citext` necesita superusuario; sin `citext` no se crea ni la tabla `products` | probar el restore periódicamente con el usuario real |

---

## Cómo responder esto en una entrevista

**1. "¿Cómo hacés un deploy sin downtime en Rails?"**

Tres piezas: (a) los contenedores nuevos arrancan al lado de los viejos y el proxy
sólo rota el tráfico cuando el healthcheck pasa; (b) el contenedor viejo primero
deja de recibir tráfico nuevo y **después** recibe `SIGTERM`, con un
`drain_timeout` mayor que la request p99; (c) —y esto es lo que realmente
importa— **toda migración es compatible hacia atrás**, porque durante la ventana
conviven las dos versiones del código contra la misma base. Sin (c), (a) y (b) no
alcanzan.
*Trade-off:* la compatibilidad hacia atrás cuesta deploys extra (un rename son
cuatro). Lo pagás con la capacidad de hacer rollback instantáneo.

**2. "¿Migrás antes o después de desplegar el código?"**

Depende del cambio, y esa es la respuesta: **agregar antes, sacar después**.
Agregar tabla, columna nullable o índice va antes (el código viejo lo ignora).
Borrar o renombrar va después y en varios pasos: expand-contract — columna nueva,
escribir en las dos, backfill en lotes, leer de la nueva, `ignored_columns`, y
recién ahí `remove_column`.
*Trade-off:* cuatro deploys en vez de uno. Si tenés una ventana de mantenimiento y
el negocio la tolera, migrar con la app apagada es más simple y perfectamente
válido; la pregunta es si podés permitírtelo.

**3. "¿Credenciales encriptadas o variables de entorno?"**

Las dos, con un criterio: si el valor **cambia entre entornos o servidores**, va a
ENV (`DATABASE_URL`, `REDIS_URL`, `WEB_CONCURRENCY`); si es un secreto del
código que es el mismo siempre, va a `credentials.yml.enc` (`secret_key_base`).
Las credentials se versionan y se revisan en un PR, pero cambiar un valor exige un
deploy. ENV lo rota tu gestor de secretos sin rebuild, pero se filtra en logs y en
`docker inspect`.
*Trade-off:* meter todo en credentials te obliga a deployar para cambiar un nivel
de log; meter todo en ENV te deja 40 variables sin trazabilidad. Y sea cual sea,
`secret_key_base` no se rota a la ligera: invalida todas las sesiones activas.

**4. "El healthcheck de Rails, ¿alcanza?"**

Para *liveness*, sí: `/up` devuelve 200 si el proceso bootea, y eso es
exactamente lo que querés. Para *readiness*, no: la propia documentación de
`Rails::HealthController` aclara que **no** chequea la base ni Redis, así que
devuelve 200 con Postgres caído. Un readiness honesto necesita un `SELECT 1` con
timeout corto.
*Trade-off, y es la parte que separa una buena respuesta:* meter la base en el
check de **liveness** es un error grave — un incidente de Postgres reinicia toda
la flota en loop y le agrega una tormenta de reconexiones al incidente que ya
tenías. Liveness chequea el proceso; readiness chequea las dependencias.

**5. "¿Kamal o Kubernetes?"**

Kamal es SSH + `docker run` + un proxy reverso: cero plano de control, cero
cluster, se aprende en una tarde y corre sobre VPS baratos o hierro propio. Lo que
**no** tiene es autoescalado ni autoreparación: si un servidor muere de noche,
nadie lo levanta. Kubernetes te da reconciliación continua y escalado, y a cambio
te cobra un cluster que alguien tiene que operar.
*Regla:* hasta ~20 servidores, carga previsible y un equipo, Kamal. Con carga
estacional, muchos servicios o varios equipos compartiendo infraestructura,
Kubernetes o un PaaS. Lo importante es decir **para qué** estás optimizando.

**6. "¿Qué pasa con los jobs que están corriendo cuando deployás?"**

Solid Queue trata `TERM`/`INT` como parada graceful, pero el `shutdown_timeout` por
default es de **5 segundos**: pasado eso, mata los procesos. El job interrumpido no
se pierde —su fila en `solid_queue_claimed_executions` queda huérfana cuando el
proceso deja de latir— pero tarda hasta 5 minutos
(`process_alive_threshold`) en volver a estar disponible. Conclusión: la garantía
real es **at-least-once**, así que los jobs tienen que ser idempotentes, punto.
*Trade-off:* subir `shutdown_timeout` reduce las interrupciones pero alarga cada
deploy y te acerca al `SIGKILL` del orquestador. La solución de fondo no es el
timeout: es partir los jobs largos en pasos con checkpoint.

**7. "¿Cómo respaldás Postgres?"**

`pg_dump -Fc` para lo cotidiano (staging, recuperar una tabla, cambiar de versión
mayor) y PITR con archivado de WAL para el desastre, porque es lo único que te deja
volver al segundo anterior al `DELETE` sin `WHERE`.
*Y el punto que hay que hacer sí o sí:* **un backup que nunca restauraste no es un
backup**. Un restore de este repo falla si el usuario destino no puede
`CREATE EXTENSION citext`, y sin `citext` no se crea ni la tabla `products`.
Lo que se automatiza es el restore periódico a una base descartable, con
verificación de conteos. Bonus específico de este dominio: `stock_movements` es un
ledger inmutable, así que la proyección `stock_items` se puede reconstruir sumando
el ledger (`Stock::ReconcileBalancesJob`) — son dos capas de recuperación
distintas y conviene distinguirlas.
