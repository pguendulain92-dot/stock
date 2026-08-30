# frozen_string_literal: true

class Warehouse < ApplicationRecord
  has_many :stock_items, dependent: :restrict_with_error
  has_many :products, through: :stock_items
  has_many :stock_movements, dependent: :restrict_with_error

  normalizes :code, with: ->(c) { c.to_s.strip.upcase }

  validates :code, presence: true, uniqueness: true,
            format: { with: /\A[A-Z0-9-]{2,12}\z/, message: "sólo mayúsculas, números y guiones (2-12)" }
  validates :name, presence: true, length: { maximum: 120 }
  validates :timezone, inclusion: { in: ActiveSupport::TimeZone::MAPPING.values + ActiveSupport::TimeZone.all.map(&:name) }

  scope :active,   -> { where(active: true) }
  scope :physical, -> { where(virtual: false) }
  scope :virtual_only, -> { where(virtual: true) }

  # El depósito virtual de tránsito. `Rails.cache.fetch` evita ir a la base en
  # cada transferencia; el TTL es corto porque casi nunca cambia.
  TRANSIT_CODE = "IN-TRANSIT"

  def self.transit
    Rails.cache.fetch("warehouse/transit", expires_in: 1.hour) do
      find_by!(code: TRANSIT_CODE)
    end
  end

  def to_s = "#{code} — #{name}"
end
