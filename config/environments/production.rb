require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  # ⚠️ :local guarda los adjuntos en el DISCO DEL CONTENEDOR, que es EFÍMERO:
  # cada deploy los borra. Sirve para arrancar; en producción de verdad va S3
  # (o el volumen persistente que declara config/deploy.yml). Lo dejamos
  # explícito para que la decisión sea consciente y no un olvido.
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local").to_sym

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Detrás de un proxy que ya terminó TLS (Kamal, nginx, un ALB), Rails no ve
  # que la conexión original era HTTPS. `assume_ssl` se lo dice, y sin eso
  # `force_ssl` entraría en un bucle de redirects infinito.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # force_ssl hace TRES cosas, y las tres importan:
  #   1. Redirige HTTP -> HTTPS.
  #   2. Manda la cabecera HSTS (el browser deja de intentar HTTP).
  #   3. Marca las cookies como `secure`, así no viajan nunca en claro.
  # Sin esto, la cookie de sesión sale sin el flag `secure` (sólo con httponly
  # y same_site: lax) y basta una request HTTP para que un atacante en la misma
  # red la capture. Era el único hallazgo de confianza alta de Brakeman -A.
  config.force_ssl = true
  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  # `host` NO es decorativo: es lo que arma las URLs de los mails (por ejemplo
  # el link de reseteo de contraseña). Con "example.com" los usuarios reciben
  # links rotos. Sale del entorno para que no haya un default que engañe.
  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "localhost") }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
