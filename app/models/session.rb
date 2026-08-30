# frozen_string_literal: true

class Session < ApplicationRecord
  belongs_to :user

  DEFAULT_TTL = 30.days

  before_create { self.expires_at ||= DEFAULT_TTL.from_now }

  scope :active, -> { where(expires_at: Time.current..) }   # rango sin fin (Ruby 2.6+)

  def expired? = expires_at.present? && expires_at <= Time.current
end
