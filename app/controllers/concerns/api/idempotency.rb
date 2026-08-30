# frozen_string_literal: true

module Api
  # ============================================================================
  # IDEMPOTENCIA HTTP, estilo Stripe.
  #
  # EL PROBLEMA: el cliente manda POST /stock/receive, el servidor lo procesa,
  # y la respuesta se pierde (timeout, red, el móvil perdió señal). El cliente
  # NO SABE si se aplicó. Si reintenta, puede duplicar el ingreso de mercadería.
  # Si no reintenta, puede haberlo perdido. Las dos opciones son malas.
  #
  # LA SOLUCIÓN: el cliente genera un UUID y lo manda en `Idempotency-Key`.
  # El servidor garantiza que ese POST se ejecuta UNA SOLA VEZ y que los
  # reintentos devuelven la MISMA respuesta.
  #
  # POR QUÉ ES RESPONSABILIDAD DEL CLIENTE generar la clave: sólo él sabe que
  # dos requests son "el mismo intento". El servidor no puede inferirlo (dos
  # ingresos idénticos de 10 unidades pueden ser legítimamente dos ingresos).
  #
  # EL FINGERPRINT es la parte que casi todos se olvidan: guardamos un hash del
  # body. Si llega la misma clave con un body DISTINTO, devolvemos 422 en vez de
  # la respuesta vieja. Sin eso, un cliente con un bug (clave fija) recibiría
  # silenciosamente el resultado de otra operación.
  #
  # CONCURRENCIA: el INSERT en estado 'processing' es la sección crítica. Si dos
  # requests con la misma clave llegan a la vez, el índice único hace que una
  # falle con RecordNotUnique; esa devuelve 409 (hay una en vuelo) en vez de
  # ejecutar dos veces. Es un lock distribuido implementado con un índice único.
  # ============================================================================
  module Idempotency
    extend ActiveSupport::Concern

    HEADER = "HTTP_IDEMPOTENCY_KEY"

    class_methods do
      # Marca acciones que requieren/soportan idempotencia.
      #   idempotent only: %i[create receive]
      def idempotent(**options)
        around_action :with_idempotency, **options
      end
    end

    private

    # La clave TAL COMO la mandó el cliente. Se usa sólo para el registro
    # HTTP (tabla idempotency_keys), que ya está scopeado por usuario con un
    # índice único sobre (user_id, key).
    def raw_idempotency_key = request.get_header(HEADER).presence

    # ┌──────────────────────────────────────────────────────────────────────┐
    # │ CLAVE SCOPEADA POR USUARIO — bug encontrado escribiendo los tests.   │
    # │                                                                      │
    # │ Los controllers le pasan esta clave a los services, que la guardan   │
    # │ en stock_movements.idempotency_key. Ese índice único es GLOBAL, no   │
    # │ por usuario. Si pasáramos la clave cruda:                            │
    # │                                                                      │
    # │   * el usuario A manda Idempotency-Key: "pedido-1"                   │
    # │   * el usuario B manda Idempotency-Key: "pedido-1" (¡otra empresa!)  │
    # │   * el service encuentra el movimiento de A y le devuelve ESE.       │
    # │                                                                      │
    # │ O sea: B recibe datos de A (fuga de información) y su operación NO   │
    # │ se ejecuta (pérdida de datos), en silencio. Con claves tipo          │
    # │ "pedido-1" o "1" —que la gente usa— la colisión no es hipotética.    │
    # │                                                                      │
    # │ Prefijar con el id del usuario aísla los espacios de nombres. El     │
    # │ test "las claves están SCOPEADAS POR USUARIO" cubre esta regresión.  │
    # └──────────────────────────────────────────────────────────────────────┘
    def idempotency_key
      key = raw_idempotency_key
      return nil if key.nil?

      "u#{current_user&.id || 'anon'}:#{key}"
    end

    def with_idempotency
      key = raw_idempotency_key

      # Sin header: se ejecuta normalmente. Lo hacemos opcional a propósito
      # (un GET no lo necesita y forzarlo rompería clientes existentes), pero
      # en una API de pagos lo harías OBLIGATORIO para POST.
      return yield if key.blank?

      if key.length > 255
        return render_error(:invalid_idempotency_key, "La clave no puede superar 255 caracteres.",
                            status: :bad_request)
      end

      fingerprint = IdempotencyKey.fingerprint(request.raw_post)
      record = claim_key(key, fingerprint)

      # `case/in` es PATTERN MATCHING (Ruby 3.0+). Compara ESTRUCTURA, no sólo
      # valores: `in { replay: true, record: IdempotencyKey => stored }` exige
      # que la clave :replay valga true Y que :record sea un IdempotencyKey, y
      # de paso lo liga a la variable `stored`. En Java necesitarías un
      # `instanceof` + cast, o los sealed classes + record patterns de Java 21.
      #
      # A diferencia de `case/when`, si NINGÚN patrón matchea, `case/in` levanta
      # NoMatchingPatternError en vez de devolver nil en silencio. Eso es
      # exactamente lo que querés en una máquina de estados: un estado no
      # contemplado tiene que ser ruidoso.
      case record
      in { replay: true, record: IdempotencyKey => stored }
        # Reintento de una operación YA COMPLETADA: devolvemos lo mismo.
        # `skip_authorization` es necesario porque cortamos ANTES de llegar a la
        # acción, así que nunca se llamó a `authorize`. Sin esto, el after_action
        # `verify_pundit_usage` levantaría AuthorizationNotPerformedError y el
        # replay devolvería 500 en vez de la respuesta cacheada.
        # (No hay agujero de seguridad: la respuesta que devolvemos ya pasó por
        # la autorización cuando se ejecutó la request original, y la clave está
        # scopeada por usuario.)
        skip_pundit_verification
        response.set_header("Idempotent-Replay", "true")
        render json: stored.response_body, status: stored.response_status
      in { conflict: true }
        skip_pundit_verification
        render_error(:idempotency_conflict,
                     "Ya hay una solicitud en curso con esta clave de idempotencia.",
                     status: :conflict)
      in { mismatch: true }
        skip_pundit_verification
        render_error(:idempotency_key_reuse,
                     "Esta clave ya se usó con un cuerpo distinto.",
                     status: :unprocessable_content)
      in { record: IdempotencyKey => fresh }
        # ⚠️ DOS TRAMPAS ENCADENADAS, las dos estuvieron vivas acá.
        #
        # (1) `with_idempotency` es un around_action. Si la acción levanta una
        #     excepción que después atrapa un `rescue_from` (404, 403, 422...),
        #     el flujo NO vuelve a la línea siguiente al yield: la fila quedaba
        #     en estado 'processing' para siempre y TODO reintento con esa clave
        #     recibía 409 durante las 24 h del TTL. Un error transitorio del
        #     cliente le quemaba la clave.
        #
        # (2) El arreglo obvio —envolver en `ensure`— TAMPOCO alcanza, y el
        #     motivo es sutil: el `ensure` corre mientras la excepción viaja
        #     hacia arriba, o sea ANTES de que el `rescue_from` renderice. En
        #     ese momento `response.status` todavía es 200 y marcaríamos la
        #     clave como 'completed' guardando un cuerpo vacío.
        #
        # La forma correcta es `rescue/else`: si hubo excepción marcamos
        # 'failed' y la RE-LANZAMOS (para que el rescue_from haga su trabajo);
        # si no la hubo, recién ahí persistimos la respuesta real.
        begin
          yield
        rescue StandardError
          mark_failed(fresh)
          raise
        else
          persist_response(fresh)
        end
      end
    end

    # Pundit expone `skip_authorization` / `skip_policy_scope`, que marcan la
    # request como "verificada a propósito". `respond_to?(..., true)` incluye
    # métodos privados: así este concern sigue sirviendo en un controller que
    # no use Pundit.
    def skip_pundit_verification
      skip_authorization if respond_to?(:skip_authorization, true)
      skip_policy_scope if respond_to?(:skip_policy_scope, true)
    end

    def claim_key(key, fingerprint)
      existing = IdempotencyKey.live.find_by(user_id: current_user&.id, key:)

      if existing
        return { mismatch: true } unless existing.matches_request?(fingerprint)
        return { replay: true, record: existing } if existing.completed?

        return { conflict: true } if existing.processing?

        # 'failed': dejamos reintentar. Un error no debería quemar la clave.
        existing.update!(status: "processing")
        return { record: existing }
      end

      record = IdempotencyKey.create!(
        user: current_user, key:, request_path: request.path,
        request_method: request.request_method, request_fingerprint: fingerprint,
        status: "processing"
      )
      { record: }
    rescue ActiveRecord::RecordNotUnique
      # Carrera perdida: otra request idéntica está en vuelo AHORA MISMO.
      { conflict: true }
    end

    def mark_failed(record)
      record.update!(status: "failed")
    rescue StandardError => e
      Rails.logger.error(event: "idempotency.mark_failed_error", key: record.key, error: e.message)
    end

    def persist_response(record)
      # Sólo cacheamos respuestas EXITOSAS (2xx). Cachear un 500 significaría
      # devolver ese 500 para siempre, aunque el problema ya esté resuelto.
      # Un 4xx tampoco se cachea: marcamos 'failed' para que el cliente pueda
      # corregir el pedido y reintentar con la MISMA clave.
      if response.successful?
        record.update!(
          status: "completed",
          response_status: response.status,
          response_body: safe_parse(response.body)
        )
      else
        record.update!(status: "failed", response_status: response.status)
      end
    rescue StandardError => e
      # Nunca dejamos que un fallo al persistir la clave tape el error real de
      # la acción: se loguea y seguimos.
      Rails.logger.error(event: "idempotency.persist_failed", key: record.key, error: e.message)
    end

    def safe_parse(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end
  end
end
