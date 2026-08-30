# frozen_string_literal: true

# Crea una orden de compra con sus líneas a partir de claves naturales
# (tax_id del proveedor, código de depósito, SKUs).
class PurchaseOrderForm < ApplicationForm
  attribute :supplier_tax_id, :string
  attribute :warehouse_code, :string
  attribute :expected_at, :date
  attribute :currency, :string, default: "USD"
  attribute :notes, :string

  attr_accessor :lines, :created_by

  validates :supplier_tax_id, :warehouse_code, presence: true
  validate :references_exist
  validate :lines_are_valid

  def supplier
    @supplier ||= Supplier.active.find_by(tax_id: supplier_tax_id.to_s.gsub(/[^0-9A-Za-z]/, "").upcase)
  end

  def warehouse = @warehouse ||= Warehouse.active.find_by(code: warehouse_code.to_s.upcase)

  private

  def normalized_lines
    @normalized_lines ||= Array(lines).map { |l| l.respond_to?(:to_h) ? l.to_h.symbolize_keys : l }
  end

  # Una query para todos los SKUs (ver el comentario en StockTransferForm).
  def products_by_sku
    @products_by_sku ||= Product.kept.where(
      sku: normalized_lines.filter_map { |l| l[:sku]&.to_s&.upcase }
    ).index_by(&:sku)
  end

  def references_exist
    errors.add(:supplier_tax_id, "no existe o está inactivo") if supplier.nil?
    errors.add(:warehouse_code, "no existe o está inactivo") if warehouse.nil?
  end

  def lines_are_valid
    if normalized_lines.empty?
      errors.add(:lines, "no puede estar vacío")
      return
    end

    seen = Set.new
    normalized_lines.each_with_index do |line, index|
      sku = line[:sku].to_s.upcase
      product = products_by_sku[sku]

      errors.add(:lines, "línea #{index + 1}: SKU '#{sku}' no existe") if product.nil?
      errors.add(:lines, "línea #{index + 1}: la cantidad debe ser positiva") unless line[:quantity].to_i.positive?
      errors.add(:lines, "línea #{index + 1}: el costo no puede ser negativo") if line[:unit_cost_cents].to_i.negative?
      errors.add(:lines, "línea #{index + 1}: SKU '#{sku}' repetido") unless seen.add?(sku)
    end
  end

  def persist!
    order = PurchaseOrder.create!(
      supplier:, warehouse:, created_by:, currency: currency.to_s.upcase,
      expected_at:, notes:, status: "draft"
    )

    # Acá SÍ usamos create! (y no insert_all!) porque el callback
    # `refresh_order_totals` de PurchaseOrderLine tiene que correr para
    # recalcular total_cents y lines_count. Es el contra-ejemplo del
    # StockTransferForm: cuando hay callbacks que importan, el bulk insert no
    # sirve. Saber cuándo aplica cada uno es la mitad del trabajo.
    normalized_lines.each do |line|
      order.lines.create!(
        product: products_by_sku[line[:sku].to_s.upcase],
        quantity_ordered: line[:quantity].to_i,
        unit_cost_cents: line[:unit_cost_cents].to_i
      )
    end

    Result.success(PurchaseOrder.with_associations.find(order.id))
  end
end
