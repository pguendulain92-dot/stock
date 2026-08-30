# frozen_string_literal: true

class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  # Rate limit NATIVO de Rails sobre el login: la segunda capa, después de
  # Rack::Attack.
  #
  # ⚠️ `by:` NO ES OPCIONAL SI QUERÉS ALGO DISTINTO DE LA IP. El default de
  # ActionController es `-> { request.remote_ip }`. Este código tuvo durante un
  # tiempo un comentario que decía "contamos por IP + email" mientras el
  # `rate_limit` no pasaba `by:` — o sea que contaba sólo por IP. El comentario
  # mentía y nadie se enteraba porque el límite igual "funcionaba".
  #
  # Contar por IP+email juntos hace el límite MÁS FINO: dos personas de la misma
  # oficina (misma IP) no se bloquean entre sí, y un atacante que rota IPs
  # contra una cuenta sí queda limitado por el lado del email. Los límites
  # gruesos (sólo IP, sólo email) los cubre Rack::Attack en la capa de borde.
  rate_limit to: 10, within: 3.minutes, only: :create,
             by: -> { "#{request.remote_ip}:#{params[:email_address].to_s.downcase.strip}" },
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
