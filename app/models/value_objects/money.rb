# frozen_string_literal: true

module ValueObjects
  # ============================================================================
  # Money — Value Object para dinero.
  #
  # REGLA ABSOLUTA: nunca representes plata con Float. En IEEE-754 binario,
  # 0.1 + 0.2 == 0.30000000000000004. Con miles de operaciones, la diferencia
  # se acumula y el balance no cierra.
  #
  # Guardamos ENTEROS de la unidad mínima (centavos) y encapsulamos toda la
  # aritmética acá. Es el patrón de Stripe y de cualquier sistema financiero.
  #
  # Lo que hace este objeto y que un `Integer` pelado no puede:
  #   * Impide sumar USD con EUR (te tira una excepción, no un número mal).
  #   * Centraliza el redondeo (banker's rounding para no sesgar hacia arriba).
  #   * Se formatea solo.
  #
  # Es un Value Object de DDD: sin identidad, inmutable, comparado por valor.
  # `Data.define` te da ==, hash y freeze gratis (equivale a un record de Java
  # con equals/hashCode generados).
  # ============================================================================
  Money = Data.define(:cents, :currency) do
    SUBUNITS = {
      "USD" => 100, "EUR" => 100, "ARS" => 100, "BRL" => 100,
      "CLP" => 1,   # el peso chileno NO tiene centavos
      "JPY" => 1    # el yen tampoco
    }.freeze

    class CurrencyMismatch < StandardError; end

    class << self
      def zero(currency = "USD") = new(cents: 0, currency:)

      # Constructor desde unidades "humanas". Acepta String o BigDecimal,
      # nunca Float, justamente para no heredar el error de redondeo.
      def from_amount(amount, currency = "USD")
        decimal = BigDecimal(amount.to_s)
        new(cents: (decimal * SUBUNITS.fetch(currency, 100)).round.to_i, currency:)
      end
    end

    def initialize(cents:, currency: "USD")
      super(cents: cents.to_i, currency: currency.to_s.upcase)
    end

    def +(other) = combine(other) { |a, b| a + b }
    def -(other) = combine(other) { |a, b| a - b }

    # Multiplicar plata por un ESCALAR (cantidad, porcentaje) sí tiene sentido.
    # Multiplicar plata por plata NO (daría "dólares al cuadrado").
    def *(factor)
      raise ArgumentError, "no se puede multiplicar dinero por dinero" if factor.is_a?(Money)

      with(cents: (BigDecimal(cents.to_s) * BigDecimal(factor.to_s)).round.to_i)
    end

    def zero? = cents.zero?
    def negative? = cents.negative?
    def positive? = cents.positive?
    def -@ = with(cents: -cents)

    def subunit = SUBUNITS.fetch(currency, 100)
    def amount = BigDecimal(cents) / subunit

    def to_s = format("%s %.#{Math.log10(subunit).to_i}f", currency, amount)

    # Rails llama a esto al serializar a JSON. Devolvemos las tres cosas para
    # que el front no tenga que adivinar la escala.
    def as_json(*) = { cents:, currency:, formatted: to_s }

    # Comparable: habilita <, >, sort, min, max, clamp.
    include Comparable
    def <=>(other)
      assert_same_currency!(other)
      cents <=> other.cents
    end

    private

    def combine(other)
      assert_same_currency!(other)
      with(cents: yield(cents, other.cents))
    end

    def assert_same_currency!(other)
      return if other.is_a?(Money) && other.currency == currency

      raise CurrencyMismatch, "no se puede operar #{currency} con #{other.inspect}"
    end
  end
end
