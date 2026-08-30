# frozen_string_literal: true

module Api
  module V1
    # ==========================================================================
    # BaseController — el tronco común de la API v1.
    #
    # Hereda de ActionController::API, NO de ActionController::Base. La diferencia
    # es el stack de módulos que se carga: API se saltea vistas, helpers, flash,
    # cookies, CSRF y assets. Menos memoria por request y menos superficie de
    # ataque. Si necesitás algo de eso, se incluye el módulo puntual.
    # ==========================================================================
    class BaseController < ActionController::API
      include Api::ErrorHandling
      include Api::TokenAuthentication
      include Api::Idempotency
      include Pundit::Authorization
      include Pagy::Backend

      # ------------------------------------------------------------------------
      # CAPA 2 DE RATE LIMITING: `rate_limit` NATIVO DE RAILS (8.x).
      #
      # ¿Por qué DOS capas si ya tenemos Rack::Attack?
      #
      #   Rack::Attack (borde)     -> barato, genérico, sin contexto de negocio.
      #                               Sabe la IP y el header. NO sabe quién sos,
      #                               de qué empresa, ni de qué plan.
      #   rate_limit (controller)  -> corre después de autenticar, así que puede
      #                               limitar POR USUARIO, POR PLAN, POR TENANT.
      #                               Cuesta más (ya autenticaste) pero es el
      #                               único lugar donde tenés esa información.
      #
      # Es defensa en capas: la de afuera absorbe el volumen bruto, la de adentro
      # aplica la política comercial ("el plan free tiene 100 escrituras/hora").
      #
      # `by:` es el DISCRIMINADOR (por quién se cuenta).
      # `store:` es importante: por defecto usa Rails.cache, que acá es Solid
      # Cache (Postgres). Para contadores de alta frecuencia preferimos Redis.
      # ------------------------------------------------------------------------
      # ⚠️ UN RATE LIMITER SOBRE UN NULL STORE NO LIMITA NADA, Y NO AVISA.
      # `rate_limit` hace `store.increment(...)`; ActiveSupport::Cache::NullStore
      # devuelve nil, la comparación `count && count > to` nunca se cumple y el
      # límite queda desactivado sin un solo mensaje. Es un fallo silencioso de
      # seguridad: creés que estás protegido y no lo estás.
      # Por eso elegimos el store explícitamente y avisamos si no sirve.
      RATE_LIMIT_STORE =
        if ENV["REDIS_URL"].present?
          ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"], namespace: "ratelimit")
        elsif Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
          Rails.logger.warn(
            "[RateLimit] Rails.cache es un NullStore: el rate limiting NO funcionaría. " \
            "Usando un MemoryStore local (sólo válido para un único proceso)."
          )
          ActiveSupport::Cache::MemoryStore.new
        else
          Rails.cache
        end

      # ⚠️ TRAMPA REAL, encontrada probando esto con curl.
      #
      # Rails arma la clave del contador así:
      #     ["rate-limit", scope, name, by].compact.join(":")
      # y `scope` por defecto es `controller_path`.
      #
      # Si declarás DOS `rate_limit` que aplican al mismo controller (uno acá en
      # la base y otro en la subclase) SIN pasar `name:`, las dos declaraciones
      # generan LA MISMA CLAVE. Resultado: comparten un solo contador y CADA
      # request lo incrementa DOS VECES. Un límite de 20 corta en 10.
      # Lo comprobamos: /reports (20/min) cortaba en la request 11.
      #
      # La solución es dar `name:` distinto a cada límite. Y usamos `scope:`
      # explícito para que este techo global se comparta entre TODOS los
      # controllers de la API v1 (que es lo que queremos: un tope por token
      # para toda la API, no uno por controller).
      rate_limit to: 600, within: 1.minute,
                 name: "api-global", scope: :api_v1,
                 by: -> { current_api_token&.id || request.remote_ip },
                 store: RATE_LIMIT_STORE,
                 with: -> { rate_limited!(60) }

      before_action :set_default_response_format

      private

      def rate_limited!(retry_after)
        response.set_header("Retry-After", retry_after.to_s)
        render_error(:rate_limit_exceeded,
                     "Superaste el límite de solicitudes de tu token.",
                     status: :too_many_requests, retry_after:)
      end

      def set_default_response_format
        request.format = :json unless params[:format]
      end

      # Pundit necesita saber quién es el usuario actual.
      def pundit_user = current_user

      # ------------------------------------------------------------------------
      # `verify_authorized` corre DESPUÉS de cada acción y explota si te
      # olvidaste de llamar a `authorize`. Es la red de seguridad que evita el
      # agujero clásico: agregás un endpoint nuevo, te olvidás el chequeo de
      # permisos, y queda abierto para todo el mundo durante meses.
      # En producción lo logueamos en vez de explotar, para no romper un endpoint
      # por un olvido; en desarrollo/test SÍ explota, para que lo arregles ya.
      # ------------------------------------------------------------------------
      # OJO: NO usamos `only: %i[index]` / `except: %i[index]` acá.
      # Desde Rails 7.1, declarar un callback con `only:`/`except:` apuntando a
      # una acción QUE NO EXISTE en ese controller levanta
      # AbstractController::ActionNotFound al ejecutarse. Como esta clase base
      # la heredan controllers que no tienen `index`
      # (StockOperationsController, ReportsController), un `only: %i[index]` acá
      # rompe TODAS sus acciones. Es un cambio de comportamiento sutil que
      # aparece al actualizar de Rails 7.0 a 7.1+.
      #
      # La solución robusta: UN callback que decide adentro.
      after_action :verify_pundit_usage

      def verify_pundit_usage
        action_name == "index" ? verify_policy_scoped : verify_authorized
      rescue Pundit::AuthorizationNotPerformedError, Pundit::PolicyScopingNotPerformedError => e
        # En dev/test EXPLOTA: querés enterarte al instante de que un endpoint
        # quedó sin control de acceso. En producción sólo lo logueamos, para no
        # tumbar un endpoint por un olvido — pero la alerta queda registrada.
        raise e if Rails.env.local?

        Rails.logger.error(event: "security.authorization_missing",
                           controller: controller_name, action: action_name,
                           error: e.class.name)
      end

      # Paginación offset estándar (para listados que el usuario navega).
      # Para el ledger usamos keyset — ver Api::V1::StockMovementsController.
      #
      # ⚠️ EL CLAMP NO ES OPCIONAL. Esto estuvo sin tope y `?limit=1000000` era
      # un DoS de una línea: instanciás un millón de objetos ActiveRecord y el
      # worker muere por memoria. Vale para CUALQUIER número que venga del
      # usuario y controle un recurso: tamaño de página, TTL, cantidad, rango
      # de fechas. Pagy tiene `max_limit` en su config, pero depende de que la
      # opción `limit` llegue por su camino: acotarlo acá es explícito y no se
      # rompe si mañana cambiamos de librería.
      MAX_PAGE_SIZE = 100

      def paginate(scope)
        pagy(scope, limit: page_limit)
      end

      def page_limit
        return Pagy::DEFAULT[:limit] if params[:limit].blank?

        Integer(params[:limit]).clamp(1, MAX_PAGE_SIZE)
      rescue ArgumentError, TypeError
        Pagy::DEFAULT[:limit]
      end

      def render_collection(pagy, records, serializer, **options)
        pagy_headers_merge(pagy)
        render json: {
          data: serializer.collection(records, **options),
          meta: {
            page: pagy.page, limit: pagy.limit,
            total_count: pagy.count, total_pages: pagy.pages,
            next_page: pagy.next, prev_page: pagy.prev
          }
        }
      end

      # `find_by!` sobre una clave natural (sku, code) en vez del id numérico.
      # Es mucho más usable para una API de integración: el cliente ya conoce el
      # SKU, no el id interno.
      def find_product!
        Product.find_by!(sku: params.require(:sku).to_s.strip.upcase)
      end

      def find_warehouse!
        Warehouse.find_by!(code: params.require(:warehouse_code).to_s.strip.upcase)
      end
    end
  end
end
