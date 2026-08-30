# frozen_string_literal: true

class StockItemPolicy < ApplicationPolicy
  def receive? = operator?
  def issue?   = operator?
  def adjust?  = manager?     # ajustar inventario cambia la contabilidad: manager+
  def reserve? = operator?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
