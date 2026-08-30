# frozen_string_literal: true

# ==============================================================================
# StockMovement — el asiento del libro mayor. INMUTABLE.
#
# `readonly?` devolviendo true una vez persistido hace que Rails levante
# ActiveRecord::ReadOnlyRecord ante cualquier intento de UPDATE. Es una barrera
# a nivel aplicación; la barrera real de producción sería un trigger o revocar
# el UPDATE al rol de la app. Pero para el 99% de los accidentes alcanza.
# ==============================================================================
class StockMovement < ApplicationRecord
  # Sin updated_at: la tabla no lo tiene y el registro no se modifica nunca.
  self.record_timestamps = true

  belongs_to :stock_item
  belongs_to :product
  belongs_to :warehouse
  belongs_to :user, optional: true
  belongs_to :reference, polymorphic: true, optional: true

  KINDS = %w[receipt issue adjustment transfer_in transfer_out return scrap count_correction].freeze
  INBOUND  = %w[receipt transfer_in return].freeze
  OUTBOUND = %w[issue transfer_out scrap].freeze

  enum :kind, KINDS.index_by(&:itself), validate: true

  validates :quantity, numericality: { only_integer: true, other_than: 0 }
  validates :quantity_after, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :occurred_at, presence: true

  # Coherencia de signo, espejo del CHECK constraint de la migración.
  # Sí, está duplicado a propósito: la validación de Rails da un mensaje lindo
  # al usuario; el CHECK garantiza que NADIE (ni un script, ni un psql) meta
  # basura. Defensa en profundidad.
  validate :sign_matches_kind

  before_validation :denormalize_from_stock_item, on: :create
  before_validation { self.occurred_at ||= Time.current }

  scope :inbound,  -> { where(kind: INBOUND) }
  scope :outbound, -> { where(kind: OUTBOUND) }
  scope :recent,   -> { order(occurred_at: :desc, id: :desc) }
  scope :between,  ->(from, to) { where(occurred_at: from..to) }
  scope :with_associations, -> { includes(:product, :warehouse, :user) }

  # El registro es inmutable una vez guardado.
  def readonly? = persisted?

  def inbound? = INBOUND.include?(kind)
  def outbound? = OUTBOUND.include?(kind)

  def signed_quantity = quantity
  def absolute_quantity = quantity.abs

  def total_cost
    return nil if unit_cost_cents.nil?

    ValueObjects::Money.new(cents: unit_cost_cents * quantity.abs, currency:)
  end

  # Atajo de conveniencia. La consulta vive en un Query Object
  # (app/queries/stock_items/reconciliation.rb) porque es una consulta de
  # REPORTE, no una responsabilidad del modelo. Ver docs/05.
  def self.discrepancies(...) = StockItems::Reconciliation.call(...)

  private

  def denormalize_from_stock_item
    return if stock_item.nil?

    self.product_id   ||= stock_item.product_id
    self.warehouse_id ||= stock_item.warehouse_id
    self.currency = stock_item.product.currency if currency.blank?
  end

  def sign_matches_kind
    return if kind.blank? || quantity.nil?

    if INBOUND.include?(kind) && quantity.negative?
      errors.add(:quantity, "debe ser positiva para un movimiento de entrada (#{kind})")
    elsif OUTBOUND.include?(kind) && quantity.positive?
      errors.add(:quantity, "debe ser negativa para un movimiento de salida (#{kind})")
    end
  end
end
