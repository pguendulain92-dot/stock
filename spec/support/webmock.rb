# frozen_string_literal: true

require "webmock/rspec"

# ==============================================================================
# WebMock — bloquea TODO el HTTP saliente durante los tests.
#
# ¿Por qué es obligatorio y no opcional?
#   * Un test que sale a internet es LENTO (cientos de ms por request).
#   * Es FLAKEY: el servicio se cae, cambia, o tenés rate limit.
#   * NO ES REPRODUCIBLE: la misma suite da distinto según el día.
#   * En CI muchas veces ni siquiera hay salida a internet.
#   * Y lo peor: podés estar mandando datos de prueba a un sistema REAL.
#
# `disable_net_connect!` hace que cualquier request no stubbeada tire una
# excepción con el comando exacto para stubbearla. Es la forma de descubrir que
# tenías una llamada HTTP escondida en un callback.
#
# `allow_localhost: true` es indispensable: Capybara levanta un Puma en
# 127.0.0.1 y el browser tiene que poder hablarle.
#
# Equivalente en Java: WireMock. La diferencia es que WebMock intercepta a
# nivel de Net::HTTP en el mismo proceso, sin levantar un servidor aparte.
# ==============================================================================
WebMock.disable_net_connect!(
  allow_localhost: true,
  # El CDP de Chromium (system tests) habla por WebSocket a un puerto local.
  allow: [ "127.0.0.1", "localhost" ]
)

RSpec.configure do |config|
  # Los tests marcados con `:external_http` documentan explícitamente que
  # tocan la red. Deberían ser CERO; el tag existe para poder auditarlos.
  config.before(:each, :external_http) do
    skip "Test que requiere red real. Corré con ALLOW_NET=1 si sabés lo que hacés." unless ENV["ALLOW_NET"]
  end
end
