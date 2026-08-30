# frozen_string_literal: true

# ==============================================================================
# StockItem — el AGREGADO del dominio (en el sentido de DDD).
#
# Es la unidad de consistencia transaccional: toda operación que cambia stock
# bloquea EXACTAMENTE una fila de esta tabla. Eso nos da dos cosas:
#   * Serialización de las operaciones sobre el mismo par (producto, depósito).
#   * Paralelismo total entre pares distintos (no hay un lock global).
#
# NOTA IMPORTANTE SOBRE DÓNDE VIVE LA LÓGICA:
# Este modelo expone métodos de LECTURA y las invariantes simples. Las
# OPERACIONES (recibir, despachar, reservar) viven en app/services/stock/*,
# no acá. ¿Por qué? Porque una operación real necesita: bloquear, validar
# reglas de negocio, escribir el movimiento en el ledger, emitir el evento de
# outbox y devolver un Result. Eso es un CASO DE USO, no responsabilidad de la
# entidad de persistencia. Meter todo eso acá es el camino directo al "modelo
# gordo" de 2000 líneas — viola SRP y hace imposible testear las reglas sin
# base de datos. Ver docs/05.
# ==============================================================================
class StockItem < ApplicationRecord
  self.locking_column = "lock_version"

  belongs_to :product
  belongs_to :warehouse

  has_many :stock_movements, dependent: :restrict_with_error
  has_many :stock_reservations, dependent: :restrict_with_error

  # `quantity_available` es una COLUMNA GENERADA de Postgres: se puede leer y
  # filtrar, pero no escribir. Rails la marca como readonly automáticamente.
  validates :quantity_on_hand, :quantity_reserved,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :reorder_point, :reorder_quantity,
            numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :product_id, uniqueness: { scope: :warehouse_id }
  validate  :reserved_cannot_exceed_on_hand

  scope :for_warehouse, ->(w) { where(warehouse: w) }
  scope :in_stock,      -> { where(quantity_available: 1..) }
  scope :out_of_stock,  -> { where(quantity_available: ..0) }

  # Usa el índice parcial `index_stock_items_needing_reorder`. Comparar dos
  # columnas requiere SQL crudo — `where` con hash sólo compara contra valores.
  scope :needing_reorder, -> { where("quantity_available <= reorder_point") }

  scope :with_associations, -> { includes(:product, :warehouse) }

  # --- Lecturas ---------------------------------------------------------------

  def available = quantity_available.to_i
  def on_hand   = quantity_on_hand.to_i
  def reserved  = quantity_reserved.to_i

  def available_quantity = ValueObjects::Quantity.new(amount: available, unit: product.unit)

  def can_fulfil?(amount) = available >= amount.to_i
  def below_reorder_point? = available <= reorder_point
  def out_of_stock? = available <= 0

  # Valuación al costo del producto. Se usa en el reporte de inventario.
  def valuation = product.cost * on_hand

  # --- Escrituras de bajo nivel ------------------------------------------------
  #
  # Estos dos métodos son los ÚNICOS que tocan las cantidades, y son
  # deliberadamente "tontos": no validan reglas de negocio ni escriben el
  # ledger. Eso lo hace el service, que además garantiza el lock.
  #
  # `update!` (y no `update_column`) para que corran las validaciones y el
  # optimistic locking. Si otro proceso tocó la fila, StaleObjectError.

  # Aplica un delta con signo al stock físico.
  def apply_delta!(delta)
    self.quantity_on_hand = on_hand + delta
    self.last_movement_at = Time.current
    save!
    self
  end

  def apply_reservation_delta!(delta)
    self.quantity_reserved = reserved + delta
    save!
    self
  end

  # ---------------------------------------------------------------------------
  # UPDATE ATÓMICO SIN LOCK EXPLÍCITO.
  #
  # Esta es la variante de máximo throughput: un solo UPDATE con el WHERE que
  # incluye la condición de negocio. Postgres bloquea la fila durante el UPDATE
  # y evalúa el WHERE sobre la versión más reciente. Si devuelve 0 filas, es
  # que la condición no se cumplió (no había stock) y no cambiamos nada.
  #
  # Ventaja: cero round-trips extra, cero riesgo de deadlock por orden de locks.
  # Desventaja: no podés hacer lógica compleja en Ruby entre el chequeo y la
  #             escritura, y perdés el lock_version optimista.
  #
  # Cuándo usar cuál (respuesta de entrevista):
  #   * 1 fila + condición expresable en SQL  -> este UPDATE condicional.
  #   * Varias filas / lógica compleja / hay que leer antes -> SELECT FOR UPDATE.
  #   * Conflictos raros y el usuario puede reintentar -> optimistic locking.
  # ---------------------------------------------------------------------------
  def self.atomically_decrement(stock_item_id, amount)
    updated = where(id: stock_item_id)
              .where("quantity_on_hand - quantity_reserved >= ?", amount)
              .update_all([
                            "quantity_on_hand = quantity_on_hand - ?, " \
                            "lock_version = lock_version + 1, " \
                            "last_movement_at = ?, updated_at = ?",
                            amount, Time.current, Time.current
                          ])
    updated == 1
  end

  # `find_or_create_by!` tiene una race condition: dos requests concurrentes
  # pueden pasar el `find` a la vez y las dos intentar el `create`. Una gana y
  # la otra recibe PG::UniqueViolation (que Rails traduce a RecordNotUnique).
  # La forma correcta es CONFIAR EN EL ÍNDICE ÚNICO y rescatar el choque.
  # Ver docs/10 §find_or_create_by.
  def self.find_or_provision!(product:, warehouse:)
    find_by(product:, warehouse:) || create!(product:, warehouse:)
  rescue ActiveRecord::RecordNotUnique
    # El otro proceso ganó la carrera: su fila ya está commiteada, la leemos.
    find_by!(product:, warehouse:)
  end

  def to_s = "#{product.sku} @ #{warehouse.code}: #{available}"

  private

  def reserved_cannot_exceed_on_hand
    return if quantity_reserved.to_i <= quantity_on_hand.to_i

    errors.add(:quantity_reserved, "no puede superar el stock físico (#{quantity_on_hand})")
  end
end
