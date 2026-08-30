# frozen_string_literal: true

# shoulda-matchers: matchers declarativos para validaciones y asociaciones.
#   it { is_expected.to validate_presence_of(:sku) }
# En una línea testea lo mismo que 6 líneas a mano, y lee como la especificación.
require "shoulda/matchers"

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
