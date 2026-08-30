# frozen_string_literal: true

class StockTransfer < ApplicationRecord
  belongs_to :source_warehouse, class_name: "Warehouse"
  belongs_to :destination_warehouse, class_name: "Warehouse"
  belongs_to :transit_warehouse, class_name: "Warehouse", optional: true
  belongs_to :requested_by, class_name: "User"

  has_many :lines, class_name: "StockTransferLine", dependent: :destroy, inverse_of: :stock_transfer
  has_many :products, through: :lines
  has_many :stock_movements, as: :reference, dependent: :restrict_with_error

  # `accepts_nested_attributes_for` deja crear/actualizar las líneas desde un
  # único formulario o payload. Es cómodo, pero tiene mala fama: mezcla la
  # forma del INPUT con la forma del MODELO y las validaciones se vuelven
  # difíciles de leer. Para la API usamos un Form Object
  # (app/forms/stock_transfer_form.rb) que es explícito y testeable solo.
  accepts_nested_attributes_for :lines, allow_destroy: true, reject_if: :all_blank

  STATUSES = %w[draft in_transit received cancelled].freeze
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :reference, presence: true, uniqueness: true
  validate :warehouses_must_differ

  before_validation :assign_reference, on: :create

  scope :open, -> { where(status: %w[draft in_transit]) }
  scope :with_associations, -> { includes(:source_warehouse, :destination_warehouse, :requested_by, lines: :product) }

  # --- Máquina de estados -----------------------------------------------------
  # La modelamos explícitamente en vez de usar una gema (aasm/state_machines).
  # Para 4 estados y 3 transiciones, una gema es más peso conceptual que ayuda.
  # Lo importante es que las transiciones sean explícitas y estén testeadas.
  TRANSITIONS = {
    "draft"      => %w[in_transit cancelled],
    "in_transit" => %w[received cancelled],
    "received"   => [],
    "cancelled"  => []
  }.freeze

  def can_transition_to?(new_status) = TRANSITIONS.fetch(status, []).include?(new_status.to_s)

  def total_units_requested  = lines.sum(:quantity_requested)
  def total_units_dispatched = lines.sum(:quantity_dispatched)
  def total_units_received   = lines.sum(:quantity_received)

  # Diferencia entre lo despachado y lo recibido: mercadería perdida/dañada.
  def shrinkage = total_units_dispatched - total_units_received

  def to_s = reference

  private

  def assign_reference
    self.reference ||= self.class.next_reference
  end

  # Referencias correlativas sin huecos. La lógica (y el porqué) está en
  # app/models/sequence_counter.rb y en su migración.
  def self.next_reference = SequenceCounter.next_reference("TR")

  def warehouses_must_differ
    return if source_warehouse_id.blank? || destination_warehouse_id.blank?
    return if source_warehouse_id != destination_warehouse_id

    errors.add(:destination_warehouse, "debe ser distinto del depósito de origen")
  end
end
