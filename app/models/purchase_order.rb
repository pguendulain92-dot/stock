# frozen_string_literal: true

class PurchaseOrder < ApplicationRecord
  include HasMoney

  belongs_to :supplier
  belongs_to :warehouse
  belongs_to :created_by, class_name: "User"

  has_many :lines, class_name: "PurchaseOrderLine", dependent: :destroy, inverse_of: :purchase_order
  has_many :products, through: :lines
  has_many :stock_movements, as: :reference, dependent: :restrict_with_error

  has_money :total

  STATUSES = %w[draft submitted partially_received received cancelled].freeze
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :reference, presence: true, uniqueness: true
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }

  before_validation :assign_reference, on: :create

  scope :open, -> { where(status: %w[submitted partially_received]) }
  scope :with_associations, -> { includes(:supplier, :warehouse, :created_by, lines: :product) }

  TRANSITIONS = {
    "draft"              => %w[submitted cancelled],
    "submitted"          => %w[partially_received received cancelled],
    "partially_received" => %w[received cancelled],
    "received"           => [],
    "cancelled"          => []
  }.freeze

  def can_transition_to?(new_status) = TRANSITIONS.fetch(status, []).include?(new_status.to_s)

  def fully_received? = lines.any? && lines.all?(&:fully_received?)
  def partially_received? = lines.any?(&:partially_received?)

  # Recalcula el total desde las líneas. Se llama desde un callback de la línea,
  # dentro de la misma transacción. `sum(:subtotal_cents)` usa la columna
  # GENERADA de Postgres: no hay riesgo de que el subtotal esté desactualizado.
  def recalculate_totals!
    update_columns(
      total_cents: lines.sum(:subtotal_cents),
      lines_count: lines.count,
      updated_at: Time.current
    )
  end

  def to_s = reference

  private

  def assign_reference
    self.reference ||= SequenceCounter.next_reference("PO")
  end
end
