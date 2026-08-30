# frozen_string_literal: true

module ValueObjects
  # ============================================================================
  # Quantity — cantidad de stock con su unidad de medida.
  #
  # ¿Por qué envolver un Integer? Porque un Integer pelado deja pasar bugs que
  # el tipo puede atrapar:
  #   * sumar 5 kilos + 3 unidades  -> ahora explota en vez de dar "8"
  #   * cantidades negativas donde no corresponde
  #   * la unidad "se pierde" al pasar de capa en capa
  #
  # Es exactamente el argumento de "Primitive Obsession" de Fowler, y en Java
  # lo resolverías con un record + validación en el constructor compacto.
  # ============================================================================
  Quantity = Data.define(:amount, :unit) do
    UNITS = %w[unit kg g l ml m cm box pallet].freeze

    class UnitMismatch < StandardError; end
    class InvalidUnit < StandardError; end

    def initialize(amount:, unit: "unit")
      unit = unit.to_s
      raise InvalidUnit, "unidad desconocida: #{unit}" unless UNITS.include?(unit)

      super(amount: Integer(amount), unit:)
    end

    def +(other) = combine(other) { |a, b| a + b }
    def -(other) = combine(other) { |a, b| a - b }
    def -@ = with(amount: -amount)

    def zero? = amount.zero?
    def positive? = amount.positive?
    def negative? = amount.negative?
    def abs = with(amount: amount.abs)

    def to_i = amount
    def to_s = "#{amount} #{unit}"
    def as_json(*) = { amount:, unit: }

    include Comparable
    def <=>(other)
      assert_same_unit!(other)
      amount <=> other.amount
    end

    private

    def combine(other)
      assert_same_unit!(other)
      with(amount: yield(amount, other.amount))
    end

    def assert_same_unit!(other)
      return if other.is_a?(Quantity) && other.unit == unit

      raise UnitMismatch, "no se puede operar #{unit} con #{other.inspect}"
    end
  end
end
