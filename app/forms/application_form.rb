# frozen_string_literal: true

# ==============================================================================
# FORM OBJECTS — el "DTO validado" del mundo Rails.
#
# ¿Cuándo usás uno?
#   * Cuando la entrada NO se corresponde 1:1 con un modelo (varios modelos,
#     campos virtuales, una wizard de 3 pasos).
#   * Cuando querés validaciones que aplican al INPUT pero no al modelo
#     (ej. "confirmá el email", que sólo tiene sentido en el alta).
#   * Cuando querés armar varios registros en una transacción con mensajes de
#     error coherentes.
#
# `ActiveModel::Model` te da validaciones, errores y `to_key`/`to_param`, o sea
# que un form object FUNCIONA CON `form_with` igual que un modelo, sin tener
# tabla. Eso es duck typing puro: a Rails no le importa la clase, le importa
# que responda a la interfaz.
#
# Comparado con Java: es un @Valid RequestDTO con Bean Validation, pero además
# ejecuta la operación. Es el objeto que separa "la forma del formulario" de
# "la forma de la tabla" — y esa separación es lo que evita el
# `accepts_nested_attributes_for` con 200 líneas de hacks.
# ==============================================================================
class ApplicationForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  # Devuelve un Result, igual que los services: interfaz uniforme para el
  # controller (LSP: le da lo mismo si le habla a un form o a un service).
  def save
    return Result.failure(:validation_failed, errors.full_messages.to_sentence,
                          errors: errors.to_hash(true)) unless valid?

    ApplicationRecord.transaction { persist! }
  rescue ActiveRecord::RecordInvalid => e
    Result.failure(:validation_failed, e.record.errors.full_messages.to_sentence,
                   errors: e.record.errors.to_hash(true))
  end

  private

  def persist!
    raise NotImplementedError, "#{self.class} debe implementar #persist!"
  end
end
