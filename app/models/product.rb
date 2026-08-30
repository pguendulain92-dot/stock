# frozen_string_literal: true

class Product < ApplicationRecord
  include Discardable
  include HasMoney

  # Optimistic locking: Rails detecta la columna `lock_version` por convención
  # y agrega `AND lock_version = ?` a cada UPDATE. Ver docs/06.
  self.locking_column = "lock_version"

  belongs_to :category, optional: true

  has_many :stock_items, dependent: :restrict_with_error
  has_many :warehouses, through: :stock_items
  has_many :stock_movements, dependent: :restrict_with_error
  has_many :product_suppliers, dependent: :destroy
  has_many :suppliers, through: :product_suppliers
  has_many :purchase_order_lines, dependent: :restrict_with_error

  has_one :preferred_product_supplier, -> { where(preferred: true) },
          class_name: "ProductSupplier", inverse_of: :product, dependent: nil
  has_one :preferred_supplier, through: :preferred_product_supplier, source: :supplier

  has_money :cost
  has_money :price

  UNITS = %w[unit kg g l ml m cm box pallet].freeze

  normalizes :sku, with: ->(s) { s.to_s.strip.upcase }
  normalizes :barcode, with: ->(b) { b.to_s.strip.presence }

  # ¡OJO CON LOS ANCLAS DEL REGEX EN RUBY!
  #
  # En Ruby, `^` y `$` significan "principio/fin de LÍNEA", no de string
  # (a diferencia de Java, donde por defecto son principio/fin de INPUT).
  # O sea que /^[A-Z0-9]+$/ acepta ESTO:
  #
  #     "VALIDO\n<script>alert(1)</script>"
  #
  # ...porque la PRIMERA LÍNEA cumple. Es una vulnerabilidad clásica de Rails y
  # sale en todos los checklists de seguridad. La forma correcta es SIEMPRE
  # `\A` (principio de string) y `\z` (fin de string, sin permitir el \n final
  # que sí permite `\Z`). Brakeman marca esto automáticamente.
  #
  # Nota: [A-Z] es ASCII puro, así que un SKU con Ñ o acentos se rechaza. Es
  # deliberado: los SKUs viajan por códigos de barras, EDI y sistemas legacy
  # que suelen no ser UTF-8.
  validates :sku, presence: true, uniqueness: true,
            format: { with: /\A[A-Z0-9][A-Z0-9._-]{1,31}\z/,
                      message: "2-32 caracteres alfanuméricos ASCII, punto, guion o guion bajo" }
  validates :name, presence: true, length: { maximum: 200 }
  validates :unit, inclusion: { in: UNITS }
  validates :currency, format: { with: /\A[A-Z]{3}\z/ }
  validates :cost_cents, :price_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  scope :active,   -> { where(active: true) }
  scope :sellable, -> { kept.active }

  # `includes` evita el N+1 en los listados. Ver docs/04.
  scope :with_associations, -> { includes(:category, stock_items: :warehouse) }

  # -- Lecturas agregadas -------------------------------------------------------

  # OJO: esto dispara una query por producto si lo llamás en un loop (N+1).
  # Para listados usá Queries::StockItems::Availability, que lo resuelve con
  # un solo GROUP BY. Lo dejamos porque para UN producto es lo correcto.
  def total_on_hand  = stock_items.sum(:quantity_on_hand)
  def total_reserved = stock_items.sum(:quantity_reserved)
  def total_available = stock_items.sum(:quantity_available)

  def margin
    return ValueObjects::Money.zero(currency) if price.zero?

    price - cost
  end

  def margin_ratio
    return 0.0 if price.zero?

    ((price.cents - cost.cents).to_f / price.cents).round(4)
  end

  def quantity(amount) = ValueObjects::Quantity.new(amount:, unit:)

  def to_s = "#{sku} — #{name}"
end
