# frozen_string_literal: true

require "capybara/rspec"
require "capybara/cuprite"

# ==============================================================================
# SYSTEM TESTS: Capybara maneja un BROWSER REAL (Chromium headless) contra un
# servidor Puma que RSpec levanta en otro thread.
#
# ¿Cuándo vale la pena un system test? Cuando lo que probás es EXACTAMENTE la
# integración browser + JS + servidor: que el formulario mande lo que creés, que
# Turbo actualice lo que corresponde, que el flujo completo del usuario ande.
# Para todo lo demás, un request spec es 20 veces más rápido y más fácil de
# debuggear. Un puñado de system tests bien elegidos > cincuenta.
#
# ─── LOS DRIVERS Y CUÁNDO USAR CADA UNO ──────────────────────────────────────
#
#   :rack_test  -> NO hay browser. Capybara parsea el HTML y simula clicks.
#                  Instantáneo. NO ejecuta JavaScript. Es nuestro default.
#
#   :cuprite    -> Chromium de verdad, hablando Chrome DevTools Protocol (CDP)
#                  DIRECTO. No necesita chromedriver, así que no hay versiones
#                  que sincronizar. Es nuestro driver para `js: true`.
#
#   :selenium   -> el estándar de la industria (W3C WebDriver). Necesita
#                  chromedriver, y su versión MAYOR tiene que coincidir con la
#                  del Chrome instalado. Es la causa número uno de "el CI se
#                  rompió solo": Chrome se autoactualiza y el driver queda viejo.
#                  (En este entorno justamente no coinciden: Chromium 141 vs
#                  ChromeDriver 147. Por eso usamos cuprite.)
#
# ─── ⚠️ TRAMPA GRANDE: `driven_by` RE-REGISTRA EL DRIVER ─────────────────────
#
# Lo natural es hacer:
#
#     Capybara.register_driver(:cuprite) { |app| ...mis opciones... }   # ❌
#     driven_by :cuprite
#
# ...y tus opciones SE PIERDEN. En Rails 8,
# ActionDispatch::SystemTesting::Driver#registerable? incluye :cuprite (además
# de :selenium, :rack_test y :playwright), así que `driven_by :cuprite`
# SOBREESCRIBE la registración con la suya, construida a partir de lo que le
# pasaste en `options:`.
#
# El síntoma es desconcertante: el browser arranca bien si lo probás a mano con
# Ferrum, pero en la suite falla con
#   "Browser did not produce websocket url within 10 seconds"
# (10 s = el default de Ferrum, o sea que tu `process_timeout:` nunca llegó).
# Y una vez que falla, TODOS los demás system tests fallan también, porque el
# `Capybara.reset_sessions!` de después de cada ejemplo vuelve a intentar
# arrancar el browser y vuelve a esperar el timeout.
#
# La forma CORRECTA en Rails 8 es pasar la configuración por `options:`, que es
# lo que `driven_by` le reenvía a Capybara::Cuprite::Driver.new. Eso es lo que
# hacemos abajo.
# ==============================================================================

# Preferimos `headless_shell`: es el build de Chromium pensado para
# automatización (sin UI, sin actualizador, sin integración con el escritorio).
# Arranca más rápido y usa menos memoria que el `chrome` completo.
CHROME_CANDIDATES = [
  ENV["CHROME_BIN"],
  "/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell",
  "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  "/usr/bin/chromium",
  "/usr/bin/google-chrome"
].compact.freeze

CHROME_BINARY = CHROME_CANDIDATES.find { |path| File.exist?(path) }

CUPRITE_OPTIONS = {
  browser_path: CHROME_BINARY,
  headless: true,
  browser_options: {
    "no-sandbox" => nil,             # obligatorio corriendo como root en un contenedor
    "disable-dev-shm-usage" => nil,  # /dev/shm chico en Docker -> Chrome crashea sin esto
    "disable-gpu" => nil
  },
  # Cuánto esperamos a que Chromium imprima su URL de WebSocket al arrancar.
  # El default de Ferrum (10 s) alcanza en una máquina ociosa; en un CI cargado
  # NO, y falla con un ProcessTimeoutError intermitente que parece un bug de la
  # app y no lo es. Subilo sin culpa.
  process_timeout: 60,
  timeout: 20,
  # `js_errors: true` hace FALLAR el test si el browser tira una excepción de
  # JavaScript. Es enorme: sin esto, un error de JS silencioso rompe la UI en
  # producción y ningún test se entera.
  js_errors: true
}.compact.freeze

# OJO: `driven_by` MUTA el hash de opciones (le hace `delete(:name)`), así que
# hay que pasarle una copia. Con el hash congelado tirás FrozenError; con el
# hash sin congelar te lo modifican en el primer ejemplo y el segundo arranca
# con otra configuración. Copia defensiva, siempre.
def cuprite_options = CUPRITE_OPTIONS.dup

Capybara.default_max_wait_time = 5      # cuánto reintenta un matcher antes de fallar
Capybara.server = :puma, { Silent: true }
Capybara.disable_animation = true
Capybara.save_path = Rails.root.join("tmp/capybara")

RSpec.configure do |config|
  # Sin JS: rack_test, que es instantáneo.
  config.before(:each, type: :system) { driven_by :rack_test }

  # Con JS: Chromium de verdad. Las opciones van por `options:` — ver la nota
  # de arriba sobre por qué NO alcanza con Capybara.register_driver.
  config.before(:each, type: :system, js: true) do
    driven_by :cuprite, screen_size: [ 1400, 1000 ], options: cuprite_options
  end
end
