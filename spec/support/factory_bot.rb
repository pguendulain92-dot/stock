# frozen_string_literal: true

require "factory_bot_rails"

# ==============================================================================
# ⚠️ TRAITS AUTOMÁTICOS DE ENUM: APAGADOS A PROPÓSITO.
#
# Desde factory_bot 6.x, `automatically_define_enum_traits` viene en TRUE: por
# cada valor de un `enum` de ActiveRecord, factory_bot inventa un trait con ese
# nombre. Suena cómodo y es una fuente de problemas:
#
#   1. Los traits inventados IGNORAN las invariantes del modelo. Acá generaba
#      `stock_reservation` con status "expired" pero SIN `released_at`, que
#      viola el CHECK constraint `stock_reservations_released_at_present`. El
#      resultado: `FactoryBot.lint` (y el step de CI que lo corre) fallaba con
#      PG::CheckViolation por traits que nadie escribió.
#
#   2. COLISIONAN en silencio con los traits que sí escribís. La factory
#      :stock_movement tenía el trait `issue` dos veces (el mío y el
#      autogenerado); `defined_traits` lo listaba duplicado y cuál ganaba
#      dependía del orden de carga.
#
#   3. Te dan la ilusión de tener cobertura de estados que en realidad no
#      probaste, porque nunca los escribiste ni los pensaste.
#
# Apagarlos obliga a declarar cada estado con TODOS los campos que la máquina de
# estados exige, que es justamente lo que querés en un dominio con invariantes.
# ==============================================================================
FactoryBot.automatically_define_enum_traits = false

# `FactoryBot.lint` construye TODAS las factories y traits y verifica que sean
# válidos. Corrélo en CI con: LINT_FACTORIES=1 bundle exec rspec
# Una factory rota se descubre normalmente en el peor momento: cuando agregás un
# test seis meses después y no entendés por qué falla.
RSpec.configure do |config|
  config.before(:suite) do
    FactoryBot.lint(traits: true) if ENV["LINT_FACTORIES"]
  end
end
