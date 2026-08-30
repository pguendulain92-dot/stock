# frozen_string_literal: true

# ==============================================================================
# Content Security Policy — la última línea de defensa contra XSS.
#
# Este archivo venía ENTERO COMENTADO por el generador de Rails, así que
# `Rails.application.config.content_security_policy` devolvía nil... mientras el
# layout emitía `csp_meta_tag`. O sea: la etiqueta estaba, la política no.
# Es un caso típico de seguridad de utilería: parece que está protegido.
#
# QUÉ HACE: le dice al browser de dónde puede cargar cada tipo de recurso. Si
# un XSS logra inyectar `<script>`, el browser se niega a ejecutarlo porque la
# fuente no está permitida. NO reemplaza al escapado de ERB: es defensa en
# profundidad para cuando el escapado falla (un `html_safe` de más, una gema
# con un bug, un campo que se renderiza sin escapar).
#
# EL NONCE es la parte fina. Un `script_src :self` bloquea los scripts INLINE,
# y Rails necesita algunos (los import maps, por ejemplo). El nonce es un valor
# aleatorio por respuesta que va en la cabecera y en la etiqueta: el browser
# ejecuta sólo los inline que lo lleven. Un atacante no puede adivinarlo.
#
# CÓMO SE DESPLIEGA SIN ROMPER TODO: primero en modo REPORT-ONLY. El browser
# no bloquea nada, sólo reporta lo que habría bloqueado. Mirás los reportes
# unas semanas, ajustás, y recién ahí lo hacés efectivo. Activar una CSP de
# golpe es la forma más rápida de romper media aplicación.
# ==============================================================================
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline   # Tailwind inyecta estilos inline
    policy.connect_src :self
    policy.base_uri    :self
    policy.form_action :self
    # Impide que te embeban en un iframe (clickjacking).
    policy.frame_ancestors :none
  end

  # ── EL NONCE TIENE QUE SER ALEATORIO POR RESPUESTA ─────────────────────────
  #
  # El generador que sugiere la documentación de Rails es
  # `->(request) { request.session.id.to_s }`, y es una MALA idea:
  # el id de sesión es CONSTANTE durante toda la sesión del usuario. Un nonce
  # que no cambia no es un nonce: si un atacante lo consigue una vez (le basta
  # con leer el HTML de cualquier página), puede inyectar scripts con ese valor
  # durante todo lo que dure la sesión. La CSP queda de adorno.
  #
  # Un valor aleatorio por respuesta no se puede predecir ni reutilizar. Rails
  # memoiza el resultado por request, así que la etiqueta y la cabecera reciben
  # el mismo valor sin que tengas que hacer nada.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # ⚠️ ARRANCÁ EN REPORT-ONLY. Poné CSP_ENFORCE=1 recién cuando los reportes
  # estén limpios. En desarrollo lo dejamos en report-only siempre, para que un
  # bloqueo no te haga perder una tarde debuggeando el browser.
  config.content_security_policy_report_only = !ENV["CSP_ENFORCE"].present? || Rails.env.local?
end
