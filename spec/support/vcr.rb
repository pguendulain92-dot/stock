# frozen_string_literal: true

require "vcr"

# ==============================================================================
# VCR — graba las respuestas HTTP reales una vez y las reproduce siempre.
#
# WebMock vs VCR (los usás JUNTOS, no son alternativas):
#   * WebMock  -> stubs que escribís VOS. Control total, pero mantenerlos al día
#                 con la API real es tu problema.
#   * VCR      -> graba la interacción REAL en un "cassette" YAML la primera vez
#                 y después la reproduce. El stub es fiel por construcción.
#
# Cuándo cada uno:
#   * Integración con una API externa de verdad (un ERP, un courier) -> VCR.
#     El cassette documenta cómo responde el sistema real, con sus rarezas.
#   * Casos de error, timeouts, respuestas que no podés provocar -> WebMock.
#
# ⚠️ LO MÁS IMPORTANTE: FILTRAR LOS SECRETOS.
# Un cassette guarda las cabeceras TAL CUAL, incluido el Authorization. Sin
# `filter_sensitive_data`, commiteás tu API key en el repo. Es una de las
# formas más comunes de filtrar credenciales, y como el archivo es YAML dentro
# de spec/, nadie lo mira.
#
# `record: :once` graba la primera vez y después SÓLO reproduce. Si la request
# cambia (otra URL, otro body), falla en vez de salir a la red en silencio.
# ==============================================================================
VCR.configure do |config|
  config.cassette_library_dir = Rails.root.join("spec/fixtures/vcr_cassettes").to_s
  config.hook_into :webmock
  config.configure_rspec_metadata!   # habilita `it "...", :vcr do`

  # Nunca grabar el servidor local de Capybara.
  config.ignore_localhost = true

  # --- Filtrado de secretos ---------------------------------------------------
  config.filter_sensitive_data("<AUTHORIZATION>") { |i| i.request.headers["Authorization"]&.first }
  config.filter_sensitive_data("<API_KEY>") { ENV.fetch("EXTERNAL_API_KEY", nil) }
  config.filter_sensitive_data("<WEBHOOK_SECRET>") { ENV.fetch("OUTBOX_WEBHOOK_SECRET", nil) }

  config.default_cassette_options = {
    record: :once,
    # Dos requests son "la misma" si coinciden método + URI. Si tu API manda
    # datos distintos en cada llamada (timestamps, nonces), agregá :body y
    # normalizalo, o el cassette no matchea nunca y VCR intenta salir a la red.
    match_requests_on: %i[method uri],
    allow_playback_repeats: true
  }
end
