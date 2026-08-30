# frozen_string_literal: true

# ==============================================================================
# Bullet en el entorno de test.
#
# `raise = true` hace que un N+1 detectado LEVANTE UNA EXCEPCIÓN y el test falle.
# Es la única forma efectiva de que los N+1 no vuelvan: que el CI los rechace.
#
# Sólo se activa en los ejemplos marcados con `:n_plus_one`, porque en muchos
# specs unitarios el "N+1" es intencional (probás un método que consulta) y
# activarlo globalmente generaría falsos positivos que la gente termina
# silenciando... y ahí perdés la herramienta.
# ==============================================================================
if defined?(Bullet)
  RSpec.configure do |config|
    config.before(:suite) do
      Bullet.enable = true
      Bullet.bullet_logger = false
      Bullet.rails_logger = false
      Bullet.raise = true   # <- el N+1 rompe el test

      # Detecta también el problema INVERSO: hiciste includes de algo que
      # después no usaste. Es una query de más y memoria desperdiciada.
      Bullet.unused_eager_loading_enable = true
    end
  end
end
