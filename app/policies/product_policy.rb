# frozen_string_literal: true

class ProductPolicy < ApplicationPolicy
  def destroy? = manager? && record.stock_items.none? { |i| i.quantity_on_hand.positive? }
  def discard? = manager?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user&.active?

      # Los viewers no ven productos dados de baja: es ruido y puede filtrar
      # información comercial (qué dejamos de vender).
      user.at_least?("operator") ? scope.all : scope.kept.active
    end
  end
end
