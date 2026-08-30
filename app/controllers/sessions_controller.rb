class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  # Rate limit NATIVO de Rails sobre el login: la segunda capa, después de
  # Rack::Attack. Acá contamos por IP + email juntos, que es más preciso.
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_session_path, alert: "Demasiados intentos. Probá de nuevo en unos minutos." }

  def new
  end

  def create
    # `authenticate_by` (Rails 7.1+) hace el lookup Y la verificación de bcrypt
    # con TIEMPO CONSTANTE respecto de si el usuario existe o no. Con
    # `find_by` + `authenticate`, un email inexistente responde en 1 ms y uno
    # existente en 80 ms (el costo de bcrypt): eso permite ENUMERAR usuarios
    # midiendo el tiempo de respuesta. Es una vulnerabilidad real y sutil.
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Email o contraseña incorrectos."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
