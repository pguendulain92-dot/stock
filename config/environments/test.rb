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
end
