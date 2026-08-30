# frozen_string_literal: true

# ==============================================================================
# rails_helper.rb — el bootstrap de la suite CON Rails cargado.
#
# La diferencia con spec_helper.rb: spec_helper NO carga Rails. Los tests que no
# necesitan el framework (Value Objects, Result) sólo requieren spec_helper y
# arrancan en ~50 ms en vez de ~3 s. En una suite grande eso se nota mucho.
# ==============================================================================

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

# Salvavidas: si por un error de configuración RAILS_ENV apuntara a producción,
# la suite BORRARÍA la base de producción. Este abort ya salvó muchas empresas.
abort("¡El entorno de Rails está en modo producción!") if Rails.env.production?

require "rspec/rails"

# Carga todo lo que haya en spec/support/. Sin esto tendrías que requerir cada
# helper a mano en cada spec.
Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }

# Verifica que el schema de test esté al día con db/migrate. Si te olvidaste de
# correr las migraciones, te avisa en vez de fallar con errores raros de columnas.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]

  # ── TRANSACTIONAL FIXTURES ────────────────────────────────────────────────
  # Cada ejemplo corre dentro de una transacción que se revierte al terminar.
  # Es MUCHÍSIMO más rápido que truncar tablas: el rollback es O(1).
  #
  # LIMITACIÓN IMPORTANTE: si el código bajo test corre en OTRO hilo con OTRA
  # conexión (tests de concurrencia, system tests con un server aparte), ese
  # hilo NO ve los datos de tu transacción sin commitear. Por eso los specs de
  # concurrencia desactivan esto explícitamente (ver spec/support/concurrency.rb).
  config.use_transactional_fixtures = true

  # Infiere el tipo de spec por la carpeta (spec/models -> :model, etc).
  config.infer_spec_type_from_file_location!

  # Recorta el backtrace de las gemas: querés ver TU código, no 40 líneas de rspec.
  config.filter_rails_from_backtrace!

  # ── Helpers disponibles en los specs ──────────────────────────────────────
  config.include FactoryBot::Syntax::Methods            # create(:product) sin prefijo
  config.include ActiveSupport::Testing::TimeHelpers    # travel_to, freeze_time
  config.include ActiveJob::TestHelper, type: :job
  config.include ApiHelpers, type: :request
  config.include AuthHelpers, type: :system

  # Limpia el estado GLOBAL entre ejemplos. Si no lo hacés, un spec que setea
  # Current.user contamina al siguiente y aparecen fallas dependientes del orden
  # —el tipo de bug más frustrante que existe.
  config.before do
    Current.reset
    Rails.cache.clear
  end
end
