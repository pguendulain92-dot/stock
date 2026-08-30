# frozen_string_literal: true

require "factory_bot_rails"

# `FactoryBot.lint` verifica que TODAS las factories generen objetos válidos.
# Corrélo en CI con: LINT_FACTORIES=1 bundle exec rspec
# Una factory rota se descubre normalmente en el peor momento: cuando agregás
# un test nuevo seis meses después y no entendés por qué falla.
RSpec.configure do |config|
  config.before(:suite) do
    if ENV["LINT_FACTORIES"]
      DatabaseCleanerStub = nil
      FactoryBot.lint(traits: true)
    end
  end
end
