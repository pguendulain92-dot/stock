require_relative "boot"

require "rails"
# Pick the frameworks you want:
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

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Stock
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # ─── Rate limiting de borde ─────────────────────────────────────────────
    #
    # DÓNDE VA EN EL STACK: esta decisión tiene una trampa importante.
    #
    # El instinto es `insert_before 0` (lo más arriba posible) para cortar antes
    # de gastar nada. PERO ahí Rack::Attack corre ANTES de
    # ActionDispatch::RemoteIp, y entonces `request.ip` es la IP del PEER TCP:
    # detrás de un load balancer, eso es la IP DEL BALANCEADOR. Resultado: TODOS
    # tus usuarios comparten un único contador y el primero que haga 300
    # requests deja afuera a todo el mundo.
    #
    # ActionDispatch::RemoteIp es el que interpreta X-Forwarded-For descartando
    # los proxies de confianza (config.action_dispatch.trusted_proxies). Por eso
    # insertamos DESPUÉS de él: seguimos estando muy arriba (antes de la sesión,
    # el routing y los controllers) pero ya con la IP del cliente real.
    #
    # ⚠️ Y NUNCA confíes en X-Forwarded-For sin configurar `trusted_proxies`:
    # es un header que manda el CLIENTE y lo puede falsificar para evadir el
    # rate limit. RemoteIp sólo lo respeta viniendo de un proxy conocido.
    #
    # Mirá el stack completo con: bin/rails middleware
    # `move_after`, NO `insert_after`.
    #
    # El railtie de rack-attack YA hace `app.middleware.use(Rack::Attack)` y lo
    # monta al final del stack. Con `insert_after` queda montado DOS VECES
    # (comprobalo con `bin/rails middleware`): no hay doble conteo —la gema se
    # protege con env["rack.attack.called"]— pero es un frame de Rack inútil en
    # cada request y una trampa para quien lea el stack.
    #
    # Y `delete` + `insert_after` TAMPOCO sirve: las operaciones sobre el stack
    # se acumulan y se aplican en orden al construirlo, así que el delete puede
    # llevarse el middleware que vos mismo insertaste y quedarte sin ninguno.
    # `move_after` mueve el que ya existe, que es exactamente lo que queremos.
    config.middleware.move_after ActionDispatch::RemoteIp, Rack::Attack

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
