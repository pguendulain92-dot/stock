# frozen_string_literal: true

class StockTransferPolicy < ApplicationPolicy
  def create?   = operator?
  def dispatch? = operator? && record.can_transition_to?("in_transit")
  def receive?  = operator? && record.can_transition_to?("received")
  def cancel?   = manager? && record.can_transition_to?("cancelled")
  def destroy?  = manager? && record.draft?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
