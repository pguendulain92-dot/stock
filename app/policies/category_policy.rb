# frozen_string_literal: true

class CategoryPolicy < ApplicationPolicy
  def create?  = manager?
  def update?  = manager?
  def destroy? = admin?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
