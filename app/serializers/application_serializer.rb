# frozen_string_literal: true

# ==============================================================================
# ApplicationSerializer — POROs para armar el JSON de la API.
#
# ¿Por qué NO usar `render json: product` directo?
#   Porque `to_json` de ActiveRecord serializa TODAS las columnas. El día que
#   agregás `internal_cost_notes` o `supplier_secret_price`, se filtra sola en
#   la API pública. Es una fuga de datos por omisión.
#
# ¿Por qué NO jbuilder?
#   Jbuilder son VISTAS: se resuelven con lookup de templates, son más lentas y
#   no se pueden testear como objetos.
#
# ¿Por qué no una gema (alba, blueprinter, jsonapi-serializer)?
#   Se pueden y son buenas. Para este proyecto escribimos POROs a mano porque:
#     1. Cero magia: se ve exactamente qué sale.
#     2. Es un ejemplo directo de SRP y de "el contrato de la API es código
#        explícito, versionado y testeable".
#     3. Un serializer PORO es la clase más fácil de testear que existe.
#   (En el README están las alternativas con su trade-off.)
#
# Contrato: `.new(objeto).as_json` -> Hash. `.collection(array)` -> Array<Hash>.
# ==============================================================================
class ApplicationSerializer
  attr_reader :object, :options

  def initialize(object, **options)
    @object = object
    @options = options
  end

  def self.collection(objects, **options)
    objects.map { |o| new(o, **options).as_json }
  end

  def as_json
    raise NotImplementedError, "#{self.class} debe implementar #as_json"
  end

  private

  def iso(time) = time&.iso8601(3)
end
