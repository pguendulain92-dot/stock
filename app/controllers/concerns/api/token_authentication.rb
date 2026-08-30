# frozen_string_literal: true

module Api
  # ============================================================================
  # Autenticación por Bearer token para la API.
  #
  # `Authorization: Bearer stk_xxxxx`
  #
  # DECISIONES Y POR QUÉ:
  #
  # 1) SIN COOKIES ni sesión. La API es stateless. Esto además elimina de raíz el
  #    CSRF: un ataque CSRF funciona porque el browser adjunta la cookie sola;
  #    un header Authorization no se adjunta solo. Por eso en el BaseController
  #    de la API desactivamos la protección CSRF — pero SÓLO ahí, y sólo porque
  #    no usamos cookies. Desactivarla "porque molesta" en un controller con
  #    sesión es un agujero grave.
  #
  # 2) SCOPES por token, no sólo roles por usuario. Un token de integración de
  #    solo lectura no debería poder escribir aunque su dueño sea admin. Es el
  #    principio de mínimo privilegio.
  #
  # 3) `ActiveSupport::SecurityUtils.secure_compare` NO hace falta acá porque
  #    buscamos por índice sobre el DIGEST: nunca comparamos el secreto en Ruby.
  #    Sí haría falta si compararas dos strings secretos directamente (ahí un
  #    `==` común filtra información por timing).
  # ============================================================================
  module TokenAuthentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate_api_token!
      before_action :set_current_context
    end

    class_methods do
      # Declara el scope que exige una acción:
      #   requires_scope "stock:write", only: %i[create update]
      def requires_scope(scope, **options)
        before_action(**options) { require_scope!(scope) }
      end
    end

    private

    def authenticate_api_token!
      token = ApiToken.authenticate(bearer_token)

      if token.nil?
        # `WWW-Authenticate` es parte del estándar HTTP para el 401: le dice al
        # cliente CÓMO autenticarse. Muchas APIs se lo olvidan.
        response.set_header("WWW-Authenticate", 'Bearer realm="stock-api"')
        return render_error(:unauthorized, "Token de API inválido o ausente.", status: :unauthorized)
      end

      unless token.user.active?
        return render_error(:account_disabled, "La cuenta asociada al token está deshabilitada.",
                            status: :forbidden)
      end

      @current_api_token = token
      token.touch_usage!
    end

    def bearer_token
      header = request.get_header("HTTP_AUTHORIZATION").to_s
      # `match` con anclas y sin backtracking peligroso. Ojo con los regex
      # "creativos" en headers: son un vector de ReDoS.
      header.start_with?("Bearer ") ? header.delete_prefix("Bearer ").strip.presence : nil
    end

    def require_scope!(scope)
      return if current_api_token&.permits?(scope)

      render_error(:insufficient_scope,
                   "El token no tiene el permiso '#{scope}'.",
                   status: :forbidden, required_scope: scope,
                   token_scopes: current_api_token&.scopes)
    end

    def set_current_context
      Current.api_token = @current_api_token
      Current.request_id = request.request_id
      Current.ip_address = request.remote_ip
      Current.user_agent = request.user_agent
    end

    def current_api_token = @current_api_token
    def current_user = @current_api_token&.user
  end
end
