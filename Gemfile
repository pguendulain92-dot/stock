# frozen_string_literal: true

# ==============================================================================
# Gemfile — el equivalente a pom.xml (Maven) o build.gradle (Gradle).
#
# Diferencias clave con Java para que no te sorprendan en la entrevista:
#
#  * NO hay "scopes" tipo compile/provided/runtime. Hay `group`s, y la app
#    decide qué grupos carga vía Bundler.require(*Rails.groups) en config/application.rb.
#  * `Gemfile.lock` == el lockfile resuelto (como el dependency:tree resuelto de
#    Maven, pero versionado en git y AUTORITATIVO). SIEMPRE se commitea.
#  * `require: false` significa "instalá la gema pero NO hagas `require` automático
#    al bootear". Se usa para herramientas de línea de comandos (rubocop, brakeman)
#    que no deben cargarse dentro del proceso de la app: cada gema cargada suma
#    RAM y tiempo de boot a TODOS los procesos (web, worker, consola).
#  * No existe el classpath. Ruby tiene `$LOAD_PATH` + `require`, y Rails encima
#    tiene Zeitwerk (autoloading por convención de nombres). Ver docs/10.
# ==============================================================================

source "https://rubygems.org"

ruby file: ".ruby-version"

# ------------------------------------------------------------------------------
# NÚCLEO DEL FRAMEWORK
# ------------------------------------------------------------------------------

# Rails 8.1 — el "Spring Boot" de Ruby, pero mucho más opinado.
# `rails` es un meta-gem: arrastra activerecord, actionpack, activejob,
# actionmailer, activesupport, railties, actioncable, activestorage.
gem "rails", "~> 8.1.3", ">= 8.1.3.1"

# Servidor de aplicación. Multi-proceso (workers) + multi-thread (threads).
# Equivalente conceptual: Tomcat/Undertow. Ver docs/06 para el modelo de
# concurrencia y por qué el GVL de Ruby cambia las reglas respecto de la JVM.
gem "puma", ">= 6.0"

# Driver nativo de PostgreSQL (extensión C). Equivalente al driver JDBC.
gem "pg", "~> 1.5"

# Pipeline de assets de Rails 8. Reemplaza a Sprockets: sólo sirve archivos con
# digest (fingerprint) para cache-busting; no transpila.
gem "propshaft"

# Import maps: JavaScript con ESM nativo del browser, SIN bundler (sin npm,
# sin webpack). Menos infra, ideal para un backend-heavy como este.
gem "importmap-rails"

# Hotwire = Turbo (navegación/streams sobre HTML) + Stimulus (JS mínimo).
# Filosofía: HTML sobre el cable en vez de JSON + SPA. Ver docs/11.
gem "turbo-rails"
gem "stimulus-rails"

# Tailwind CSS vía binario standalone (sin Node en runtime).
gem "tailwindcss-rails"

# Acelera el boot cacheando el árbol de `require` y el bytecode de YARV.
# `require: false` porque se carga a mano, temprano, en config/boot.rb.
gem "bootsnap", require: false

# tzinfo en plataformas que no traen la base de zonas horarias del SO.
gem "tzinfo-data", platforms: %i[windows jruby]

# ------------------------------------------------------------------------------
# BACKEND "SOLID" — el stack sin Redis de Rails 8
#
# Rails 8 empujó fuerte la idea de "no necesitás Redis para empezar".
# Las tres gemas Solid usan PostgreSQL como backend, en bases separadas.
# Ver docs/07 (colas) para el porqué y cuándo migrar a Sidekiq/Kafka.
# ------------------------------------------------------------------------------

gem "solid_queue"  # Active Job backend (colas en la DB, con FOR UPDATE SKIP LOCKED)
gem "solid_cache"  # Rails.cache en la DB (cache gigante y barato en disco)
gem "solid_cable"  # Action Cable pub/sub en la DB (WebSockets)

# UI web para inspeccionar/reintentar jobs de Solid Queue.
# Equivalente al dashboard de Sidekiq o a la consola de Quartz.
gem "mission_control-jobs"

# ------------------------------------------------------------------------------
# ALTERNATIVA DE COLAS: Sidekiq + Redis
#
# La incluimos a propósito para poder comparar los dos adapters con el MISMO
# código de jobs, cambiando sólo una variable de entorno (QUEUE_ADAPTER).
# Esto es exactamente el punto de Active Job: es una fachada / SPI.
# ------------------------------------------------------------------------------

gem "sidekiq", "~> 8.0"
gem "redis", "~> 5.3"

# ------------------------------------------------------------------------------
# AUTENTICACIÓN Y AUTORIZACIÓN
# ------------------------------------------------------------------------------

# Hashing de passwords (Blowfish/bcrypt, con work factor configurable).
# Lo usa `has_secure_password` de ActiveModel. NUNCA guardes SHA/MD5 de passwords.
gem "bcrypt", "~> 3.1"

# Pundit: autorización basada en POLICY OBJECTS (una clase por recurso).
# Es literalmente el patrón Strategy + un objeto por caso de uso.
# Mucho más testeable y SOLID que llenar los controllers de `if user.admin?`.
gem "pundit", "~> 2.4"

# ------------------------------------------------------------------------------
# RATE LIMITING
#
# Usamos DOS capas y en docs/08 explicamos por qué:
#  1) Rack::Attack  -> capa de borde (middleware Rack), corta ANTES de Rails.
#  2) ActionController#rate_limit -> nativo de Rails 8, por acción, con contexto
#     de negocio (por usuario autenticado, por tenant, etc).
# ------------------------------------------------------------------------------

gem "rack-attack", "~> 6.7"

# ------------------------------------------------------------------------------
# PERFORMANCE / QUERIES
# ------------------------------------------------------------------------------

# Paginación más rápida y liviana del ecosistema (no genera objetos de más,
# no hace COUNT(*) si no se lo pedís). Ver docs/04 sobre keyset pagination.
gem "pagy", "~> 9.3"

# Parser/serializador JSON en C. Reemplaza el JSON de la stdlib.
# En APIs con payloads grandes es un free win medible.
gem "oj", "~> 3.16"

# Migraciones seguras: falla en desarrollo si escribís una migración que
# tomaría un lock largo en producción (ej: agregar columna NOT NULL con
# default en Postgres viejo, agregar índice sin CONCURRENTLY, backfills, etc).
# Este gem sólo es MUY conocido en entrevistas senior. Ver docs/03.
gem "strong_migrations", "~> 2.0"

# ------------------------------------------------------------------------------
# GRUPOS DE DESARROLLO Y TEST
# ------------------------------------------------------------------------------

group :development, :test do
  # Debugger oficial de Ruby 3.x (breakpoints, step, remote debug).
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # --- Testing ---------------------------------------------------------------
  # RSpec: el framework de test dominante en Rails (alternativa: Minitest, que
  # viene de fábrica). Sintaxis BDD: describe/context/it. Ver docs/09.
  gem "rspec-rails", "~> 8.0"

  # Factories en vez de fixtures. Equivalente a los Object Mothers / builders
  # de Java, pero con soporte de traits, secuencias y asociaciones perezosas.
  gem "factory_bot_rails", "~> 6.4"

  # Datos falsos determinísticos (nombres, SKUs, direcciones).
  gem "faker", "~> 3.5"

  # Variables de entorno desde .env en dev/test (12-factor).
  gem "dotenv-rails", "~> 3.1"
end

group :development do
  # Consola interactiva en la página de error (¡sólo dev, nunca producción!).
  gem "web-console"

  # --- Análisis estático -----------------------------------------------------
  # RuboCop con el preset "omakase" de Rails 8 (el estilo oficial de DHH).
  gem "rubocop-rails-omakase", require: false
  gem "rubocop-rspec", require: false
  gem "rubocop-performance", require: false

  # Escáner de vulnerabilidades específico de Rails (SQLi, XSS, mass assignment,
  # redirect abierto...). Corre en CI. Es el "SpotBugs/Find-Sec-Bugs" de Rails.
  gem "brakeman", require: false

  # Chequea el Gemfile.lock contra la base de CVEs de Ruby Advisory DB.
  # Equivalente a OWASP dependency-check.
  gem "bundler-audit", require: false

  # --- Profiling en vivo -----------------------------------------------------
  # Badge flotante en cada página con el desglose de tiempo SQL/render.
  gem "rack-mini-profiler", require: false
  gem "memory_profiler", require: false
  gem "stackprof", require: false

  # Detector de N+1 queries y de eager loading innecesario. Lo activamos en
  # test para que un N+1 ROMPA la suite. Ver docs/04.
  gem "bullet", "~> 8.0"
end

group :test do
  # Matchers declarativos para validaciones/asociaciones de ActiveRecord.
  # `it { is_expected.to validate_presence_of(:sku) }`
  gem "shoulda-matchers", "~> 6.4"

  # Cobertura de código (line + branch coverage). Equivalente a JaCoCo.
  gem "simplecov", require: false

  # Stub de HTTP saliente. Sin esto los tests salen a internet y son flakey.
  # Equivalente a WireMock.
  gem "webmock", "~> 3.24"

  # Graba/reproduce interacciones HTTP reales en "cassettes" YAML.
  gem "vcr", "~> 6.3"

  # Tests de sistema (browser real, headless). Capybara maneja el DSL,
  # selenium-webdriver maneja el Chrome headless.
  gem "capybara", "~> 3.40"
  gem "selenium-webdriver", "~> 4.27"

  # Congelar/viajar en el tiempo. (ActiveSupport ya trae TimeHelpers; esto es
  # sólo por si necesitás algo más agresivo. Preferimos TimeHelpers.)
end

# ------------------------------------------------------------------------------
# DEPLOY
# ------------------------------------------------------------------------------

# Kamal: deploy de contenedores Docker sobre VPS "pelados", sin Kubernetes.
gem "kamal", require: false

# Thruster: proxy HTTP/2 + compresión + X-Sendfile delante de Puma,
# empaquetado en la misma imagen. Reemplaza a nginx en setups simples.
gem "thruster", require: false
