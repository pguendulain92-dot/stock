# frozen_string_literal: true

# ==============================================================================
# Result — manejo de errores SIN excepciones para el flujo esperado.
#
# ¿Por qué? En Java tenés checked exceptions y (desde Java 8) Optional, y quizá
# usaste Vavr/Either. En Ruby TODAS las excepciones son unchecked: nada en la
# firma te dice qué puede fallar. Si usás excepciones para reglas de negocio
# ("no hay stock suficiente"), el que llama no tiene forma de saberlo salvo
# leyendo la implementación. Y `rescue` sin tipo específico se come TODO.
#
# La regla que usamos en este proyecto (y la que conviene defender en una
# entrevista):
#
#   * FALLA ESPERADA (regla de negocio) -> devolvé Result.failure. Es un valor.
#     Ej: stock insuficiente, producto inactivo, permisos.
#
#   * FALLA INESPERADA (bug o infraestructura) -> excepción. Que explote,
#     que la vea el error tracker, que se reintente el job.
#     Ej: la base se cayó, un nil donde no puede haber nil.
#
# Esto hace que los controllers queden así:
#
#   case Stock::Receive.call(...)
#   in { ok: true, value: }   then render json: value
#   in { ok: false, error: } then render json: error, status: :unprocessable_entity
#   end
#
# ...usando PATTERN MATCHING de Ruby 3 (`case/in`), que es lo que hace que
# `deconstruct_keys` de abajo valga la pena.
# ==============================================================================
class Result
  # `Data.define` (Ruby 3.2+) crea una clase de valor INMUTABLE con ==, hash,
  # to_h y deconstrucción para pattern matching, en una línea.
  # Es el equivalente exacto a un `record` de Java 16+.
  # Diferencia con Struct: Data no tiene setters y exige todos los campos.
  Error = Data.define(:code, :message, :details) do
    def to_h = { code:, message:, details: }   # <- "hash shorthand" de Ruby 3.1
  end

  attr_reader :value, :error

  class << self
    def success(value = nil) = new(ok: true, value:)
    def failure(code, message, **details) =
      new(ok: false, error: Error.new(code:, message:, details:))
  end

  def initialize(ok:, value: nil, error: nil)
    @ok = ok
    @value = value
    @error = error
    freeze   # inmutable: nadie muta un Result después de creado
  end

  def ok? = @ok
  def failure? = !@ok

  # --- Composición monádica ---------------------------------------------------
  # Encadenás pasos y el primer failure corta la cadena, sin ifs anidados:
  #
  #   find_item.then_try { |i| check_stock(i) }.then_try { |i| write(i) }
  #
  # Es el `flatMap` de Optional/Either. La diferencia con las excepciones es que
  # el camino de error es EXPLÍCITO en el tipo de retorno.
  def then_try
    return self if failure?

    yield(value)
  end

  # `map` transforma el valor de éxito, dejando el error intacto.
  def map
    return self if failure?

    Result.success(yield(value))
  end

  # Escotilla de escape: cuando SÍ querés que explote (por ejemplo en un job
  # donde un failure inesperado debe activar el retry de Active Job).
  def value!
    raise Failure, error unless ok?

    value
  end

  # Habilita `case result in { ok: true, value: }` (pattern matching por hash).
  def deconstruct_keys(_keys) = { ok: @ok, value: @value, error: @error }

  # Habilita `case result in [true, value]` (pattern matching por array).
  def deconstruct = [ @ok, @ok ? @value : @error ]

  class Failure < StandardError
    attr_reader :error

    def initialize(error)
      @error = error
      super("#{error.code}: #{error.message}")
    end
  end
end
