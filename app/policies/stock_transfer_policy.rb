# frozen_string_literal: true

# Ver la nota sobre PERMISO vs ESTADO en app/policies/purchase_order_policy.rb.
# Acá también: la policy sólo mira el rol; el estado lo valida el service y
# devuelve 422 (`invalid_transition`), no 403.
class StockTransferPolicy < ApplicationPolicy
  def create?   = operator?
  def dispatch? = operator?
  def receive?  = operator?
  def cancel?   = manager?
  def destroy?  = manager?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
