# frozen_string_literal: true

# Formato de error ÚNICO para toda la API. Que el cliente pueda parsear los
# errores igual siempre es la mitad del valor de una API.
# Sigue el espíritu de RFC 9457 (Problem Details for HTTP APIs).
class ErrorSerializer
  def self.from_result(result, status:)
    {
      error: {
        code: result.error.code.to_s,
        message: result.error.message,
        details: result.error.details.presence
      }.compact,
      status:
    }
  end

  def self.from_record(record, status: 422)
    {
      error: {
        code: "validation_failed",
        message: record.errors.full_messages.to_sentence,
        # `errors.to_hash(true)` da { campo => ["mensaje completo"] }: es lo que
        # el front necesita para pintar el error al lado de cada input.
        details: record.errors.to_hash(true)
      },
      status:
    }
  end

  def self.simple(code, message, status:, **details)
    { error: { code: code.to_s, message:, details: details.presence }.compact, status: }
  end
end
