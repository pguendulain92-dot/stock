# frozen_string_literal: true

class ProductSupplier < ApplicationRecord
  include HasMoney

  belongs_to :product
  belongs_to :supplier

  has_money :cost

  validates :product_id, uniqueness: { scope: :supplier_id }
  validates :lead_time_days, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :minimum_order_quantity, numericality: { greater_than: 0, only_integer: true }
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  scope :preferred, -> { where(preferred: true) }

  # Al marcar uno como preferido hay que desmarcar el anterior, o el índice
  # único parcial `index_one_preferred_supplier_per_product` tira PG::UniqueViolation.
  # Lo hacemos DENTRO de la misma transacción del save para que sea atómico.
  before_save :unset_other_preferred, if: -> { preferred? && preferred_changed? }

  private

  def unset_other_preferred
    self.class.where(product_id:).where.not(id:).where(preferred: true)
        .update_all(preferred: false, updated_at: Time.current)
  end
end
