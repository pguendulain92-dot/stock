# frozen_string_literal: true

# ==============================================================================
# Current — estado "de la request actual", con alcance de thread/fiber.
#
# ActiveSupport::CurrentAttributes es un singleton por thread que Rails RESETEA
# automáticamente al final de cada request y de cada job. Esa garantía de reset
# es lo que lo hace seguro, a diferencia de un ThreadLocal a mano: en un pool de
# threads (Puma), si no limpiás, la request N+1 hereda los datos de la N. Fuga
# de datos entre usuarios; bug de seguridad real.
#
# REGLA DE USO: guardá acá SÓLO contexto transversal (usuario actual, request_id,
# IP). NO lo uses para pasar parámetros de negocio entre capas: eso convierte
# argumentos explícitos en dependencias globales invisibles y te arruina los
# tests. (Es el mismo abuso que hacerle "static" a todo en Java.)
# ==============================================================================
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :api_token
  attribute :request_id
  attribute :user_agent
  attribute :ip_address

  # El usuario puede venir de una sesión web o de un token de API.
  def user = session&.user || api_token&.user
end
