# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Authentication
  include Pundit::Authorization
  include Pagy::Backend

  # Bloquea browsers viejos que no soportan las features que usa Hotwire.
  allow_browser versions: :modern

  # El ETag de la respuesta depende del importmap: si cambian los JS, se
  # invalida el cache del browser automáticamente.
  stale_when_importmap_changes

  # ──────────────────────────────────────────────────────────────────────────
  # PROTECCIÓN CSRF
  #
  # ActionController::Base la trae ACTIVADA por defecto (protect_from_forgery
  # with: :exception). Rails inyecta un token en cada formulario y lo verifica
  # en toda petición no-GET.
  #
  # ¿Por qué hace falta acá y NO en la API?
  #   El ataque CSRF explota que el BROWSER manda la cookie de sesión sola,
  #   aunque la petición la origine otro sitio. Si tu autenticación es una
  #   cookie => sos vulnerable => necesitás el token.
  #   Si tu autenticación es un header Authorization (la API), el browser NO lo
  #   manda solo => no hay CSRF => el token es innecesario.
  #
  # `same_site: :lax` en la cookie de sesión (lo pone el generador de auth) es
  # la segunda capa: el browser ya no manda la cookie en POSTs cross-site.
  # ──────────────────────────────────────────────────────────────────────────

  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  before_action :set_current_request_context

  private

  def set_current_request_context
    Current.request_id = request.request_id
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
  end

  def pundit_user = Current.user
  helper_method :current_user
  def current_user = Current.user

  def user_not_authorized
    redirect_back fallback_location: root_path,
                  alert: "No tenés permisos para realizar esa acción."
  end
end
