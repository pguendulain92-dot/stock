# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Vencimiento de sesión", type: :request do
  let!(:user) { create(:user, :manager, email_address: "ana@stock.test", password: "password123") }

  def iniciar_sesion
    post session_path, params: { email_address: user.email_address, password: "password123" }
  end

  it "una sesión viva autentica" do
    iniciar_sesion
    get root_path
    expect(response).to have_http_status(:ok)
  end

  # ─────────────────────────────────────────────────────────────────────────
  # BUG REAL: `find_session_by_cookie` usaba `Session.find_by` en vez de
  # `Session.active.find_by`, así que una sesión vencida seguía autenticando
  # para siempre. Tener `expires_at` en la base y no filtrarlo es peor que no
  # tenerlo: da una falsa sensación de que las sesiones expiran.
  # ─────────────────────────────────────────────────────────────────────────
  it "una sesión VENCIDA ya no autentica" do
    iniciar_sesion
    Session.last.update_column(:expires_at, 1.minute.ago)

    get root_path

    expect(response).to redirect_to(new_session_path)
  end

  it "la sesión se crea con vencimiento por defecto" do
    iniciar_sesion
    expect(Session.last.expires_at).to be_within(1.hour).of(Session::DEFAULT_TTL.from_now)
  end
end
