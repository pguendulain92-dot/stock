# frozen_string_literal: true

# ==============================================================================
# ApplicationPolicy — autorización con Pundit.
#
# UNA CLASE POR RECURSO, UN MÉTODO POR ACCIÓN. Es el patrón Strategy: el
# controller no sabe CÓMO se decide, sólo pregunta `authorize @product`.
#
# ¿Por qué no `if current_user.admin?` en el controller?
#   * La regla queda duplicada en el controller, la vista y el job.
#   * No se puede testear sin levantar un request.
#   * Cuando el negocio cambia ("los managers ahora sí pueden borrar"), hay que
#     buscar en 40 archivos.
# Con policies: UN archivo, tests unitarios puros, y `verify_authorized` en un
# after_action te AVISA si te olvidaste de autorizar una acción. Ese último
# punto es el que evita el agujero de seguridad clásico.
#
# La clase interna `Scope` es la otra mitad: filtra las COLECCIONES. Autorizar
# el `show` de un objeto no sirve de nada si el `index` te lista todo.
# ==============================================================================
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?   = viewer?
  def show?    = viewer?
  def create?  = operator?
  def new?     = create?
  def update?  = operator?
  def edit?    = update?
  def destroy? = manager?

  private

  # `user&.at_least?` con safe navigation: si no hay usuario (petición anónima),
  # devuelve nil => falsy => denegado. Fallar cerrado (deny by default) es la
  # única postura defendible en autorización.
  def viewer?   = user&.active? && user.at_least?("viewer")
  def operator? = user&.active? && user.at_least?("operator")
  def manager?  = user&.active? && user.at_least?("manager")
  def admin?    = user&.active? && user.admin?

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    # Por defecto NO se ve nada. Cada policy concreta abre lo que corresponde.
    # Si te olvidás de definir `resolve`, no se filtra información de más.
    def resolve = scope.none
  end
end
