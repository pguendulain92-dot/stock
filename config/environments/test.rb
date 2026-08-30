# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  # ── Por qué :memory_store y no :null_store ──────────────────────────────────
  # El default de Rails en test es :null_store, para que ningún test dependa
  # sin querer de un valor cacheado. Suena razonable, pero tiene una
  # consecuencia grave: TODO lo que se apoya en el cache deja de funcionar EN
  # SILENCIO. En particular el rate limiting (que cuenta con
  # `store.increment`): con un null store, `increment` devuelve nil, la
  # comparación nunca supera el límite y tus tests de rate limiting dan verde
  # sin probar nada. Nos pasó exactamente eso escribiendo esta suite.
  #
  # Con :memory_store el cache funciona de verdad, y limpiamos entre ejemplos
  # (ver el `config.before` de spec/rails_helper.rb) para que no haya
  # dependencia de orden.
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # ── Rack::Attack apagado por defecto en test ────────────────────────────────
  # Si lo dejaras prendido, los contadores se comparten entre ejemplos y
  # cualquier spec que haga muchas requests empieza a recibir 429 al azar.
  # Los specs que SÍ prueban el rate limiting lo encienden a mano
  # (ver spec/requests/api/v1/rate_limiting_spec.rb).
  config.after_initialize do
    Rack::Attack.enabled = false
  end

  # ── Bullet: los N+1 ROMPEN la suite ─────────────────────────────────────────
  #
  # Va ACÁ y no en un `before(:suite)` de RSpec. `Bullet.enable = true` aplica
  # los parches sobre ActiveRecord en el momento de la asignación; hacerlo
  # después de que Rails terminó de bootear llega tarde para algunos de los
  # ganchos y la detección queda muda. La configuración de entorno corre en el
  # momento correcto del boot.
  #
  # `raise = true` hace que un N+1 levante
  # Bullet::Notification::UnoptimizedQueryError y el test FALLE. Es la única
  # forma de que los N+1 no vuelvan: que el CI los rechace.
  config.after_initialize do
    Bullet.enable = true
    Bullet.bullet_logger = false
    Bullet.rails_logger = false
    Bullet.raise = true

    # ── Por qué el detector de eager loading INNECESARIO es OPT-IN ────────────
    #
    # `unused_eager_loading` avisa cuando hacés `includes(:x)` y después no usás
    # `:x`. La idea es buena y encontró desperdicio real en este repo (un
    # `created_by` que ningún serializer mostraba).
    #
    # Pero como GATE de CI es contraproducente: cualquier código que precargue
    # para el camino feliz y corte antes por una validación lo dispara. Ejemplo
    # real: Purchasing::ReceiveOrder carga `includes(lines: :product)` porque
    # los necesita para recorrer las líneas, pero si la cantidad recibida es
    # inválida corta en la primera línea y la precarga "no se usó". No hay nada
    # que arreglar ahí: no podés saber de antemano si vas a fallar.
    #
    # Un chequeo que grita en casos correctos entrena a la gente a ignorarlo, y
    # ahí perdés también las alertas buenas. Lo dejamos disponible para correrlo
    # a propósito de vez en cuando:
    #
    #     BULLET_UNUSED=1 bundle exec rspec
    #
    # El detector de N+1, en cambio, queda SIEMPRE activo: sus hallazgos son
    # bugs reales, no ruido.
    Bullet.unused_eager_loading_enable = ENV["BULLET_UNUSED"].present?
  end
end
