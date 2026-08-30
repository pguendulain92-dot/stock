# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  def index?   = admin?
  def show?    = admin? || record == user
  def create?  = admin?
  def update?  = admin? || record == user
  def destroy? = admin? && record != user     # nadie se borra a sí mismo

  # Sólo un admin cambia roles. Sin esta regla, un usuario podría
  # auto-promoverse editando su propio perfil: escalada de privilegios clásica.
  def change_role? = admin? && record != user

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user&.active?

      user.admin? ? scope.all : scope.where(id: user.id)
    end
  end
end
