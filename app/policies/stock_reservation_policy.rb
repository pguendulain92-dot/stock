# frozen_string_literal: true

# ==============================================================================
# Policy de las reservas.
#
# Esta clase FALTABA y el bug lo encontró un test: `policy_scope(StockReservation)`
# en el index tiraba Pundit::NotDefinedError y el endpoint devolvía 500 para
# cualquier request. Es un ejemplo perfecto de por qué `verify_policy_scoped`
# no alcanza solo: te obliga a LLAMAR a policy_scope, pero no puede saber que
# la policy no existe hasta que alguien ejecuta esa acción.
#
# La lección: cada endpoint necesita AL MENOS un request spec que lo ejecute.
# Un endpoint sin ningún test es un endpoint que no sabés si funciona.
#
# Ver la nota sobre PERMISO vs ESTADO en purchase_order_policy.rb: acá también
# la policy mira sólo el rol; que la reserva esté vencida o ya confirmada lo
# valida el service y devuelve 410 o 409, no 403.
# ==============================================================================
class StockReservationPolicy < ApplicationPolicy
  def create?  = operator?
  def commit?  = operator?
  def release? = operator?
  def destroy? = release?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
