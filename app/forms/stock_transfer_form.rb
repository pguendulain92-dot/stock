# frozen_string_literal: true

# Arma una transferencia + sus líneas a partir de CÓDIGOS NATURALES (sku,
# warehouse code) en vez de ids internos. Es lo que un cliente de integración
# realmente tiene a mano.
class StockTransferForm < ApplicationForm
  attribute :source_warehouse_code, :string
  attribute :destination_warehouse_code, :string
  attribute :notes, :string

  attr_accessor :lines, :requested_by

  validates :source_warehouse_code, :destination_warehouse_code, presence: true
  validate :warehouses_exist
  validate :warehouses_differ
  validate :lines_are_valid

  def source_warehouse = @source_warehouse ||= Warehouse.find_by(code: source_warehouse_code.to_s.upcase)
  def destination_warehouse = @destination_warehouse ||= Warehouse.find_by(code: destination_warehouse_code.to_s.upcase)
  def source_warehouse_id = source_warehouse&.id
  def destination_warehouse_id = destination_warehouse&.id

  private

  def normalized_lines
    @normalized_lines ||= Array(lines).map { |l| l.respond_to?(:to_h) ? l.to_h.symbolize_keys : l }
  end

  # UNA query para todos los SKUs. Buscarlos de a uno adentro del loop de
  # validación sería un N+1 en la validación misma — el N+1 más invisible que
  # existe, porque nadie mira las queries de un `valid?`.
  def products_by_sku
    @products_by_sku ||= begin
      skus = normalized_lines.filter_map { |l| l[:sku]&.to_s&.upcase }
      Product.kept.where(sku: skus).index_by(&:sku)
    end
  end

  def warehouses_exist
    errors.add(:source_warehouse_code, "no existe") if source_warehouse.nil?
    errors.add(:destination_warehouse_code, "no existe") if destination_warehouse.nil?
    errors.add(:source_warehouse_code, "está inactivo") if source_warehouse && !source_warehouse.active?
  end

  def warehouses_differ
    return if source_warehouse.nil? || destination_warehouse.nil?
    return if source_warehouse.id != destination_warehouse.id

    errors.add(:destination_warehouse_code, "debe ser distinto del origen")
  end

  def lines_are_valid
    if normalized_lines.empty?
      errors.add(:lines, "no puede estar vacío")
      return
    end

    seen = Set.new
    normalized_lines.each_with_index do |line, index|
      sku = line[:sku].to_s.upcase
      quantity = line[:quantity].to_i

      errors.add(:lines, "línea #{index + 1}: SKU '#{sku}' no existe") if products_by_sku[sku].nil?
      errors.add(:lines, "línea #{index + 1}: la cantidad debe ser positiva") unless quantity.positive?
      errors.add(:lines, "línea #{index + 1}: SKU '#{sku}' repetido") unless seen.add?(sku)
    end
  end

  def persist!
    transfer = StockTransfer.create!(
      source_warehouse:, destination_warehouse:, requested_by:,
      notes:, status: "draft"
    )

    # `insert_all!` hace UN solo INSERT multi-fila en vez de N. Para 500 líneas
    # es la diferencia entre 500 round-trips y 1. Contra: NO corre validaciones
    # ni callbacks de ActiveRecord — por eso validamos antes, a mano, arriba.
    # Es un trade-off consciente, no un atajo.
    now = Time.current
    StockTransferLine.insert_all!(
      normalized_lines.map { |line|
        { stock_transfer_id: transfer.id,
          product_id: products_by_sku[line[:sku].to_s.upcase].id,
          quantity_requested: line[:quantity].to_i,
          quantity_dispatched: 0, quantity_received: 0,
          created_at: now, updated_at: now }
      }
    )

    Result.success(transfer.reload)
  end
end
