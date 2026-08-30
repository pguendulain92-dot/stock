# frozen_string_literal: true

# spec_helper.rb: configuración de RSpec que NO depende de Rails.

# ── SimpleCov tiene que arrancar ANTES que cualquier código de la app ────────
# Si lo cargás después, las líneas ya ejecutadas no quedan registradas y la
# cobertura sale mal (típicamente muy por debajo de la real).
require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch   # no alcanza con "se ejecutó la línea": ¿se tomaron las dos ramas del if?
  add_filter "/spec/"
  add_filter "/config/"
  add_filter "/db/"

  add_group "Services", "app/services"
  add_group "Queries", "app/queries"
  add_group "Policies", "app/policies"
  add_group "Serializers", "app/serializers"
  add_group "Value Objects", "app/models/value_objects"
  add_group "Forms", "app/forms"
  add_group "Jobs", "app/jobs"

  # Un umbral bajo pero real. Poner 100% obliga a escribir tests basura para
  # tapar líneas triviales; poner 0 hace que la métrica no sirva de nada.
  minimum_coverage line: 70, branch: 45
end if ENV["COVERAGE"]

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    # VERIFYING DOUBLES: si mockeás un método que NO existe en la clase real,
    # el test FALLA. Sin esto, refactorizás un método, el doble sigue
    # respondiendo el nombre viejo, el test pasa en verde y producción explota.
    # Es lo más parecido que tenemos a que el compilador te avise.
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "tmp/rspec_examples.txt"
  config.disable_monkey_patching!
  config.warnings = false
  config.default_formatter = "doc" if config.files_to_run.one?
  config.profile_examples = 10 if ENV["PROFILE"]

  # ORDEN ALEATORIO. Es fundamental: si tus tests dependen del orden, tenés
  # estado compartido y no lo sabés. La semilla se imprime para poder
  # reproducir: `bundle exec rspec --seed 12345`.
  config.order = :random
  Kernel.srand config.seed
end
