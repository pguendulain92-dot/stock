# frozen_string_literal: true

class Supplier < ApplicationRecord
  has_many :product_suppliers, dependent: :destroy
  has_many :products, through: :product_suppliers
  has_many :purchase_orders, dependent: :restrict_with_error

  normalizes :tax_id, with: ->(v) { v.to_s.gsub(/[^0-9A-Za-z]/, "").upcase }
  normalizes :email, with: ->(v) { v.to_s.strip.downcase.presence }

  validates :name, presence: true, length: { maximum: 160 }
  validates :tax_id, presence: true, uniqueness: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :default_lead_time_days, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  scope :active, -> { where(active: true) }

  # Búsqueda por trigramas. `sanitize_sql_like` escapa % y _ para que un usuario
  # no pueda meter comodines y hacer un escaneo completo (o algo peor).
  scope :search, ->(term) {
    return all if term.blank?

    where("name ILIKE :q OR tax_id ILIKE :q", q: "%#{sanitize_sql_like(term)}%")
  }

  def to_s = name
end
