# frozen_string_literal: true

class StockTransferLine < ApplicationRecord
  belongs_to :stock_transfer, inverse_of: :lines
  belongs_to :product

  validates :quantity_requested, numericality: { greater_than: 0, only_integer: true }
  validates :quantity_dispatched, :quantity_received,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :product_id, uniqueness: { scope: :stock_transfer_id }
  validate  :received_cannot_exceed_dispatched

  def pending_dispatch = quantity_requested - quantity_dispatched
  def pending_receipt  = quantity_dispatched - quantity_received
  def fully_received?  = quantity_dispatched.positive? && quantity_received == quantity_dispatched

  private

  def received_cannot_exceed_dispatched
    return if quantity_received.to_i <= quantity_dispatched.to_i

    errors.add(:quantity_received, "no puede superar lo despachado (#{quantity_dispatched})")
  end
end
