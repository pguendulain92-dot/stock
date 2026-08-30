# frozen_string_literal: true

module Api
  # ============================================================================
  # Manejo centralizado de errores para la API.
  #
  # `rescue_from` es el equivalente a @ControllerAdvice + @ExceptionHandler de
  # Spring: registra un handler por tipo de excepción para TODOS los controllers
  # que incluyan este concern.
  #
  # DETALLE QUE SE PREGUNTA: los `rescue_from` se evalúan EN ORDEN INVERSO al de
  # declaración (el último declarado gana). Por eso los más GENÉRICOS van
  # primero y los más específicos después. Si ponés StandardError al final, se
  # come todos los demás.
  #
  # Regla de oro de seguridad: NUNCA devolver `e.message` crudo de una excepción
  # inesperada. Los mensajes de Postgres filtran nombres de tablas, columnas y a
  # veces datos. Mensaje genérico para afuera, detalle completo en el log.
  # ============================================================================
  module ErrorHandling
    extend ActiveSupport::Concern

    included do
      rescue_from StandardError, with: :render_internal_error unless Rails.env.local?
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
      rescue_from ActiveRecord::StaleObjectError, with: :render_conflict
      rescue_from ActionController::ParameterMissing, with: :render_parameter_missing
      rescue_from ActionController::UnpermittedParameters, with: :render_unpermitted
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
      rescue_from ActiveRecord::LockWaitTimeout, with: :render_locked
    end

    private

    # Traduce un Result fallido al código HTTP correcto.
    # Este mapa es el CONTRATO de la API y por eso vive en un solo lugar.
    STATUS_FOR = {
      insufficient_stock: :unprocessable_content,
      insufficient_available_stock: :unprocessable_content,
      invalid_quantity: :unprocessable_content,
      validation_failed: :unprocessable_content,
      reason_required: :unprocessable_content,
      invalid_transition: :unprocessable_content,
      nothing_to_receive: :unprocessable_content,
      product_discarded: :unprocessable_content,
      warehouse_inactive: :unprocessable_content,
      reservation_expired: :gone,
      reservation_not_active: :conflict,
      conflict: :conflict,
      duplicate: :conflict,
      locked: :conflict,
      stock_item_not_found: :not_found,
      not_found: :not_found,
      forbidden: :forbidden
    }.freeze

    def render_result(result, success_status: :ok, serializer: nil)
      if result.ok?
        body = serializer && result.value ? serializer.new(result.value).as_json : result.value
        render json: { data: body }, status: success_status
      else
        status = STATUS_FOR.fetch(result.error.code, :unprocessable_content)
        render json: ErrorSerializer.from_result(result, status: Rack::Utils.status_code(status)),
               status:
      end
    end

    def render_error(code, message, status:, **details)
      render json: ErrorSerializer.simple(code, message, status: Rack::Utils.status_code(status), **details),
             status:
    end

    def render_not_found(exception)
      # No devolvemos qué modelo ni qué id: eso permite enumerar recursos.
      Rails.logger.info("[API] 404: #{exception.message}")
      render_error(:not_found, "Recurso no encontrado.", status: :not_found)
    end

    def render_record_invalid(exception)
      render json: ErrorSerializer.from_record(exception.record, status: 422),
             status: :unprocessable_content
    end

    def render_conflict(_exception)
      render_error(:conflict,
                   "El recurso fue modificado por otra operación. Recargá y reintentá.",
                   status: :conflict)
    end

    def render_locked(_exception)
      render_error(:locked, "El recurso está bloqueado por otra operación. Reintentá.",
                   status: :conflict)
    end

    def render_parameter_missing(exception)
      render_error(:parameter_missing, "Falta el parámetro '#{exception.param}'.",
                   status: :bad_request, param: exception.param)
    end

    def render_unpermitted(exception)
      render_error(:unpermitted_parameters,
                   "Parámetros no permitidos: #{exception.params.join(', ')}",
                   status: :bad_request, params: exception.params)
    end

    def render_forbidden(exception)
      policy = exception.respond_to?(:policy) ? exception.policy.class.name : nil
      render_error(:forbidden, "No tenés permisos para realizar esta acción.",
                   status: :forbidden, policy:)
    end

    def render_internal_error(exception)
      # El detalle completo va al log/error tracker; al cliente sólo un id de
      # correlación. Así soporte puede encontrar el error exacto sin exponer nada.
      Rails.logger.error(
        event: "api.internal_error", request_id: request.request_id,
        exception: exception.class.name, message: exception.message,
        backtrace: exception.backtrace&.first(15)
      )
      render_error(:internal_error,
                   "Ocurrió un error inesperado. Contactá a soporte con este id.",
                   status: :internal_server_error, request_id: request.request_id)
    end
  end
end
