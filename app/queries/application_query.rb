# frozen_string_literal: true

# ==============================================================================
# ApplicationQuery — base de los QUERY OBJECTS.
#
# ¿Por qué no meter todo en scopes del modelo?
#
# Los scopes son geniales para filtros chiquitos y reutilizables (`Product.active`).
# Pero cuando una consulta tiene 6 filtros opcionales, joins, agregaciones y
# paginación, meterla en el modelo:
#   * infla el modelo (viola SRP: el modelo pasa a saber de casos de uso de UI);
#   * hace imposible testear la consulta sin instanciar el modelo entero;
#   * mezcla el "qué es un producto" con el "cómo busca productos la pantalla X".
#
# Un Query Object es una clase con un `call` que devuelve un ActiveRecord::Relation
# (NO un array: así el que llama todavía puede paginar, contar o encadenar).
# Es el equivalente a un Repository de Spring Data con @Query, pero componible.
#
# REGLA: devolver Relation, no Array. `to_a` fuerza la ejecución y mata la
# lazy evaluation, la paginación y cualquier optimización posterior.
# ==============================================================================
class ApplicationQuery
  class << self
    def call(...) = new(...).call
  end

  def call
    raise NotImplementedError, "#{self.class} debe implementar #call"
  end

  private

  # Aplica un filtro sólo si el valor está presente. Evita el
  # `relation = relation.where(...) if x.present?` repetido 8 veces.
  def apply_if(relation, value)
    value.present? ? yield(relation, value) : relation
  end
end
