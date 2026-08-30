# frozen_string_literal: true

# ==============================================================================
# Mission Control — el dashboard web de Solid Queue.
#
# Viene con HTTP Basic auth activado. Lo desactivamos porque YA lo protegemos
# con algo mejor: el `constraints` de config/routes.rb, que exige una sesión de
# un usuario con rol admin.
#
# ¿Por qué es mejor que Basic auth?
#   * Basic manda usuario:contraseña en cada request. Una contraseña compartida
#     en una variable de entorno no se revoca por persona ni se audita:
#     "¿quién reintentó ese job?" -> "alguien que tenía la password".
#   * Con la sesión, el acceso queda atado a la identidad real y al rol. Si
#     alguien deja la empresa, se desactiva el usuario y listo.
#
# ⚠️ Desactivar el Basic SIN poner otra protección deja el panel de jobs abierto
# a internet: se ven argumentos de jobs (ids, emails, montos) y se pueden
# RE-EJECUTAR jobs a voluntad. Es un hallazgo típico de bug bounty. Los dos
# cambios (este archivo + el constraints de routes.rb) van SIEMPRE juntos.
#
# ─── LECCIÓN SOBRE EL ORDEN DE BOOT DE RAILS ─────────────────────────────────
#
# El instinto es escribir esto:
#
#     Rails.application.configure do
#       config.mission_control.jobs.http_basic_auth_enabled = false
#     end
#
# ...y NO FUNCIONA desde config/initializers/. ¿Por qué? Porque el engine de
# Mission Control copia `config.mission_control.jobs.*` a sus accessors dentro
# de un `config.before_initialize`, y ese hook corre ANTES que los archivos de
# config/initializers/. O sea que cuando este archivo se ejecuta, la copia ya
# se hizo y tu valor llega tarde.
#
# Dos salidas:
#   a) Poner la línea `config.mission_control.jobs...` en config/application.rb
#      (que se evalúa antes del before_initialize).
#   b) Setear el accessor del módulo DIRECTAMENTE, como hacemos acá. Funciona
#      porque el controller lo lee en cada request, no al bootear.
#
# El orden real es:
#   application.rb -> railties/engines -> before_initialize -> initializers de
#   gemas -> config/initializers/*.rb (alfabético) -> after_initialize
#
# Cuando una opción de configuración "no toma", el 90% de las veces es esto.
# Verificalo con: bin/rails initializers
# ==============================================================================

MissionControl::Jobs.http_basic_auth_enabled = false
