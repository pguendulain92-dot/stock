# frozen_string_literal: true

# ==============================================================================
# Discardable — soft delete (borrado lógico).
#
# En un sistema de stock NO podés borrar físicamente casi nada: los movimientos
# históricos referencian productos, depósitos y proveedores. Un DELETE real
# rompería la auditoría (y la FK con on_delete: :restrict no te dejaría).
#
# TRAMPA GRANDE: la tentación es poner `default_scope { kept }` para que todas
# las queries filtren solo. NO LO HAGAS. Un default_scope:
#   * se cuela en TODAS las asociaciones, joins y counts, incluso donde no querés;
#   * es dificilísimo de sacar después (`unscoped` te vuela TAMBIÉN el order,
#     el where del join, etc.);
#   * hace que `Product.count` mienta y que debuggear sea un infierno.
# La convención sana es scopes EXPLÍCITOS (`Product.kept`). Un poco más de
# tipeo, cero sorpresas. Ver docs/10 §default_scope.
#
# Esto es un `concern`: un módulo Ruby con esteroides. `ActiveSupport::Concern`
# resuelve el orden de inclusión y te da el bloque `included do ... end` para
# ejecutar macros de clase. Es composición por MIXIN, no herencia — Ruby no
# tiene herencia múltiple pero sí módulos, y es la forma idiomática de compartir
# comportamiento (el "I" y el "D" de SOLID salen bastante gratis acá).
# ==============================================================================
module Discardable
  extend ActiveSupport::Concern

  included do
    scope :kept,      -> { where(discarded_at: nil) }
    scope :discarded, -> { where.not(discarded_at: nil) }
  end

  def discarded? = discarded_at.present?
  def kept? = !discarded?

  def discard!
    return false if discarded?

    update!(discarded_at: Time.current)
  end

  def undiscard!
    return false if kept?

    update!(discarded_at: nil)
  end
end
