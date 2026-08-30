# Mismo criterio que Authentication#find_session_by_cookie: se filtra por
# `active` para que una sesión vencida no siga autenticando el WebSocket.
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      set_current_user || reject_unauthorized_connection
    end

    private
      def set_current_user
        if session = Session.active.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        end
      end
  end
end
