# frozen_string_literal: true

# ==============================================================================
# ApplicationRecord = la superclase de todos los modelos.
#
# `primary_abstract_class` le dice a Rails: "esta clase NO tiene tabla, es sólo
# para heredar, y es la que define la conexión primaria". Es lo que permite
# tener otras jerarquías con otra base (ej: SolidQueue usa la suya).
#
# En Java esto sería una @MappedSuperclass. La diferencia grande: ActiveRecord
# es el patrón ACTIVE RECORD (el objeto sabe persistirse a sí mismo), mientras
# que JPA/Hibernate implementa DATA MAPPER (un EntityManager separado gestiona
# la persistencia). Consecuencias prácticas:
#
#   * En Rails no hay "entidades detached" ni sesión de persistencia: cada
#     `save` es un INSERT/UPDATE inmediato. No hay flush automático ni dirty
#     checking diferido al final de la transacción.
#   * No hay lazy loading transparente de asociaciones dentro de una sesión:
#     tocar `product.category` dispara UNA query en ese instante. Por eso el
#     N+1 es tan fácil de crear en Rails (ver docs/04).
#   * Como el modelo mezcla persistencia y dominio, la disciplina SOLID hay que
#     ponerla nosotros: modelos flacos + service objects (ver docs/05).
# ==============================================================================
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # --- Helpers de bloqueo ------------------------------------------------------

  # Bloqueo pesimista sobre ESTE registro, recargándolo dentro de la transacción.
  # Traduce a: BEGIN; SELECT ... FOR UPDATE; <tu bloque>; COMMIT;
  #
  # `with_lock` ya viene en Rails; lo envolvemos sólo para poder pasar
  # `no_wait:` (NOWAIT) y fallar rápido en vez de encolarnos detrás de otro.
  def lock_or_fail!(&)
    with_lock("FOR UPDATE NOWAIT", &)
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid => e
    raise unless e.message.include?("could not obtain lock")

    raise ActiveRecord::LockWaitTimeout, "#{self.class.name}##{id} está bloqueado por otra operación"
  end

  # Devuelve el plan de ejecución de una relación. Atajo para no tener que ir a
  # psql: `Product.active.explain(analyze: true)`. Ver docs/04.
  def self.explain_analyze(relation = all)
    relation.explain(analyze: true, verbose: true)
  end
end
