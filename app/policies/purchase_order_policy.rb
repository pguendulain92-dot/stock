# frozen_string_literal: true

class PurchaseOrderPolicy < ApplicationPolicy
  def create?  = operator?
  def submit?  = manager? && record.can_transition_to?("submitted")
  def receive? = operator? && record.status.in?(%w[submitted partially_received])
  def cancel?  = manager? && record.can_transition_to?("cancelled")
  def destroy? = manager? && record.draft?

  class Scope < ApplicationPolicy::Scope
    def resolve = user&.active? ? scope.all : scope.none
  end
end
