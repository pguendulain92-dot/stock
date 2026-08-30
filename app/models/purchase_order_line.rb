# frozen_string_literal: true

class PurchaseOrderLine < ApplicationRecord
  include HasMoney

  belongs_to :purchase_order, inverse_of: :lines
  belongs_to :product

  has_money :unit_cost, currency_column: :currency

  # `subtotal_cents` es una columna generada de Postgres (quantity * unit_cost).
  # Rails la trata como readonly; leerla nunca puede dar un valor inconsistente.
  validates :quantity_ordered, numericality: { greater_than: 0, only_integer: true }
  validates :quantity_received, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :product_id, uniqueness: { scope: :purchase_order_id }
  validate :received_within_ordered

  # `touch: true` en el belongs_to actualizaría updated_at del padre, pero
  # necesitamos recalcular totales, así que lo hacemos explícito.
  # after_commit y no after_save: si la transacción hace rollback, no queremos
  # haber tocado el padre. (En este caso el padre está en la misma transacción,
  # pero la costumbre de usar after_commit para efectos evita sorpresas.)
  after_save :refresh_order_totals
  after_destroy :refresh_order_totals

  def subtotal = ValueObjects::Money.new(cents: subtotal_cents.to_i, currency:)
  def pending = quantity_ordered - quantity_received
  def fully_received? = quantity_received == quantity_ordered
  def partially_received? = quantity_received.positive? && quantity_received < quantity_ordered

  # El proveedor entrega en `currency` de la orden, no del producto.
  def currency = purchase_order&.currency || "USD"

  private

  def refresh_order_totals
    purchase_order.recalculate_totals!
  end

  def received_within_ordered
    return if quantity_received.to_i <= quantity_ordered.to_i

    errors.add(:quantity_received, "no puede superar lo pedido (#{quantity_ordered})")
  end
end
