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

  # ---------------------------------------------------------------------------
  # Plan de ejecución de una relación, sin salir de la consola de Rails.
  #
  # ⚠️ LA FORMA CON HASH NO EXISTE. Esto estaba escrito como
  # `relation.explain(analyze: true, verbose: true)` y NO funciona: el adapter
  # de Postgres arma la cláusula con `options.join(", ").upcase`, así que el
  # hash se interpola como texto y Postgres recibe
  #     EXPLAIN ({:ANALYZE=>TRUE, :VERBOSE=>TRUE}) SELECT ...
  # y contesta `PG::SyntaxError: syntax error at or near "{"`.
  # La forma correcta son SÍMBOLOS POSICIONALES: `.explain(:analyze, :verbose)`.
  #
  # Y ojo con el otro detalle: `explain` devuelve un ExplainProxy, no un String.
  # `puts relation.explain(...)` no imprime el plan; hay que usar `.inspect`
  # (o dejar que la consola lo inspeccione sola).
  #
  # ⚠️ `:analyze` EJECUTA LA QUERY DE VERDAD. Sobre un UPDATE o un DELETE
  # modifica datos. Para esos casos, envolvelo en una transacción con rollback.
  # ---------------------------------------------------------------------------
  def self.explain_analyze(relation = all)
    relation.explain(:analyze, :verbose).inspect
  end
end
