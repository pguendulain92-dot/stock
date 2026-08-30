# frozen_string_literal: true

# ==============================================================================
# ApplicationService — la clase base de los CASOS DE USO.
#
# ¿POR QUÉ EXISTE ESTA CAPA? (pregunta segura de entrevista)
#
# ActiveRecord mezcla persistencia y dominio. Si además le metés los casos de
# uso, terminás con el "God Model" de 2000 líneas donde todo depende de todo.
# El controller tampoco es el lugar: sólo debería traducir HTTP <-> dominio.
#
# Un Service Object es UNA clase con UN método público (`call`). Eso es
# literalmente el patrón Command, y te da los principios SOLID casi gratis:
#
#  S (SRP)  Una clase = una operación de negocio. Si el nombre necesita un
#           "y" ("recibirYnotificar"), son dos clases.
#  O (OCP)  Agregar una operación nueva = agregar una clase, sin tocar las que
#           ya funcionan y están testeadas.
#  L (LSP)  Todas responden `call` y devuelven `Result`. Son intercambiables:
#           el controller no sabe ni le importa cuál está ejecutando.
#  I (ISP)  Interfaz mínima: `call`. El que llama no ve 40 métodos que no usa.
#  D (DIP)  Las dependencias entran por el constructor (`clock:`, `event_recorder:`),
#           no se instancian adentro. Sin container de DI: en Ruby los argumentos
#           con nombre y valor por defecto ALCANZAN. Los objetos se pasan como
#           valores; no hace falta Spring ni Guice.
#
# CONTRATO DE ESTA CLASE:
#   * `.call(...)` es la única entrada pública.
#   * Devuelve SIEMPRE un Result (nunca lanza excepción por reglas de negocio).
#   * Todo lo que escribe va dentro de UNA transacción.
# ==============================================================================
class ApplicationService
  # Excepción interna para abortar una transacción desde adentro.
  #
  # ¿Por qué una excepción y no un `return Result.failure`?
  #
  # Porque desde Rails 7 un `return` dentro de un bloque `transaction`
  # HACE COMMIT de lo que ya se haya escrito (antes hacía rollback; el cambio
  # rompió mucho código en silencio). Y `raise ActiveRecord::Rollback` dentro
  # de una transacción ANIDADA sin `requires_new: true` se traga la excepción
  # SIN revertir la transacción de afuera — otra trampa clásica.
  #
  # Con una excepción propia que viaja hasta el `rescue` de `call`, el rollback
  # está garantizado en los dos casos, y afuera seguimos devolviendo un Result.
  # Ver docs/10 §transacciones.
  class BusinessRuleViolation < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super(result.error.message)
    end
  end

  class << self
    def call(...) = new(...).call
  end

  def call
    raise NotImplementedError, "#{self.class} debe implementar #call"
  end

  private

  # Envuelve el cuerpo en una transacción y traduce las excepciones esperadas
  # a Results. Este método es EL punto donde la app decide qué es "error de
  # negocio" (Result) y qué es "bug/infraestructura" (excepción que sube).
  def transactional
    ApplicationRecord.transaction { yield }
  rescue BusinessRuleViolation => e
    e.result
  rescue ActiveRecord::RecordInvalid => e
    Result.failure(:validation_failed, e.record.errors.full_messages.to_sentence,
                   errors: e.record.errors.to_hash)
  rescue ActiveRecord::StaleObjectError
    # Optimistic locking: otro proceso modificó la fila entre nuestra lectura y
    # nuestra escritura. Es un conflicto ESPERADO en un sistema concurrente:
    # se lo devolvemos al cliente para que reintente (HTTP 409).
    Result.failure(:conflict, "El registro fue modificado por otra operación. Reintentá.")
  rescue ActiveRecord::RecordNotUnique => e
    Result.failure(:duplicate, "Ya existe un registro con esos datos.", detail: e.message)
  rescue ActiveRecord::LockWaitTimeout
    Result.failure(:locked, "El recurso está bloqueado por otra operación. Reintentá.")
  end

  # Aborta la transacción y devuelve el failure desde `transactional`.
  def fail!(code, message, **details)
    raise BusinessRuleViolation, Result.failure(code, message, **details)
  end

  def success(value = nil) = Result.success(value)
end
