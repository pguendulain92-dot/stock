# frozen_string_literal: true

# ==============================================================================
# Ciclo de vida de Bullet por ejemplo.
#
# La CONFIGURACIÓN (enable, raise) vive en config/environments/test.rb, porque
# `Bullet.enable = true` aplica los parches sobre ActiveRecord en el momento de
# la asignación y tiene que pasar durante el boot. Acá sólo abrimos y cerramos
# el "request" alrededor de cada ejemplo marcado con `:n_plus_one`.
#
# ⚠️ ESTE ARCHIVO ESTUVO INERTE DURANTE TODO EL PROYECTO. La gema estaba sólo
# en `group :development` del Gemfile, así que la constante Bullet no existía
# en test, el guard `if defined?(Bullet)` daba false y los ejemplos marcados
# `:n_plus_one` pasaban en verde hubiera o no un N+1. Un chequeo verde que no
# verifica nada es peor que no tener chequeo. La regresión la cubre
# spec/n_plus_one_guard_spec.rb, que testea LA HERRAMIENTA, no el código.
#
# Sólo se activa en los ejemplos marcados: en muchos specs unitarios el "N+1"
# es intencional (probás un método que consulta) y activarlo globalmente
# generaría falsos positivos que la gente termina silenciando... y ahí perdés
# la herramienta.
# ==============================================================================
# ┌────────────────────────────────────────────────────────────────────────────┐
# │ EL DETALLE QUE HACE QUE BULLET "NO DETECTE NADA" EN LOS TESTS.             │
# │                                                                            │
# │ Bullet clasifica los objetos en POSIBLES e IMPOSIBLES. Un objeto que se    │
# │ cargó de a UNO (o que acabás de crear) queda marcado como IMPOSIBLE, y     │
# │ Bullet no reporta N+1 sobre él — es una heurística para no llenarte de     │
# │ falsos positivos.                                                          │
# │                                                                            │
# │ Consecuencia en un test: si hacés `create_list(...)` DENTRO del request de │
# │ Bullet, esos registros quedan marcados como imposibles y la detección se   │
# │ vuelve muda, aunque el N+1 exista. Es exactamente lo que pasaba acá.       │
# │                                                                            │
# │ La solución: crear los datos PRIMERO y abrir el request de Bullet recién   │
# │ antes de la consulta que querés auditar. Para eso está el helper           │
# │ `detectando_n_plus_one`.                                                   │
# └────────────────────────────────────────────────────────────────────────────┘
module BulletHelpers
  # Envolvé SÓLO la consulta que querés auditar, después de armar los datos:
  #
  #   it "no tiene N+1", :n_plus_one do
  #     create_list(:product, 5, :with_category)
  #     detectando_n_plus_one { Products::Search.call.each { |p| p.category.name } }
  #   end
  def detectando_n_plus_one
    Bullet.end_request
    Bullet.start_request
    yield
    Bullet.perform_out_of_channel_notifications if Bullet.notification?
  ensure
    # ⚠️ SEGUNDA TRAMPA, y esta es de las que te hacen perder una hora:
    # `perform_out_of_channel_notifications` NOTIFICA (levanta la excepción)
    # pero NO LIMPIA el colector. Si no lo reseteás acá, el `after` hook de más
    # abajo vuelve a encontrar la misma notificación y la levanta OTRA VEZ.
    # RSpec entonces marca el ejemplo como FALLADO aunque tu
    # `expect { }.to raise_error` lo haya capturado perfectamente, y el reporte
    # apunta al hook y no a tu test. Reiniciar el request vacía el colector.
    Bullet.end_request
    Bullet.start_request
  end
end

RSpec.configure do |config|
  config.include BulletHelpers, :n_plus_one

  config.before(:each, :n_plus_one) { Bullet.start_request }

  config.after(:each, :n_plus_one) do
    Bullet.perform_out_of_channel_notifications if Bullet.notification?
    Bullet.end_request
  end
end
