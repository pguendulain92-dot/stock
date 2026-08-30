# frozen_string_literal: true

# Helpers para los request specs de la API.
module ApiHelpers
  # Cabeceras de autenticación. Devuelve el token en claro, que sólo existe
  # en el momento de crearlo.
  def auth_headers(token = nil, extra = {})
    token ||= issue_token
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }.merge(extra)
  end

  def issue_token(user: nil, scopes: ApiToken::SCOPES)
    user ||= create(:user, :manager)
    ApiToken.issue!(user:, name: "spec", scopes:).plaintext
  end

  # `response.parsed_body` ya existe en Rails, pero con symbolize_keys los specs
  # quedan mucho más legibles: json[:data][:sku] en vez de json["data"]["sku"].
  def json
    @json ||= JSON.parse(response.body, symbolize_names: true)
  end

  # Se llama entre requests dentro de un mismo ejemplo, para no leer un body viejo.
  def reset_json = @json = nil

  def post_json(path, payload, headers = {})
    reset_json
    post path, params: payload.to_json, headers: auth_headers(nil, headers)
  end
end
