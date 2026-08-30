# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# REQUEST SPEC: ejercita la app entera sobre HTTP real — router, middlewares,
# autenticación, autorización, controller, service, base, serializer.
#
# Es lo más parecido a un test de integración de Spring con MockMvc, pero SIN
# mocks: la base es de verdad.
#
# Regla: los request specs prueban el CONTRATO HTTP (status, forma del JSON,
# cabeceras, permisos). La lógica de negocio se prueba en los specs de service,
# que son 10 veces más rápidos. Si duplicás toda la lógica acá, la suite se
# vuelve lentísima y frágil.
# ==============================================================================
# ─── NOTA DE SINTAXIS ─────────────────────────────────────────────────────────
# Escribimos `headers: headers` y no el shorthand `headers:` de Ruby 3.1.
# El shorthand funciona, PERO si queda como último token de la línea y sin
# paréntesis, el parser no sabe si la línea siguiente continúa el hash y tira
# `syntax error, unexpected local variable or method, expecting end`.
# O ponés paréntesis, o escribís el valor. Nos pasó de verdad escribiendo esto.
RSpec.describe "API v1 · Operaciones de stock", type: :request do
  let(:user) { create(:user, :manager) }
  let(:token) { ApiToken.issue!(user:, name: "spec", scopes: ApiToken::SCOPES).plaintext }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  let(:product) { create(:product, sku: "TOR-001") }
  let(:warehouse) { create(:warehouse, code: "BA-01") }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100) }

  def payload(**overrides)
    { sku: product.sku, warehouse_code: warehouse.code, quantity: 10 }.merge(overrides).to_json
  end

  describe "autenticación" do
    it "sin token devuelve 401 y la cabecera WWW-Authenticate" do
      post "/api/v1/stock/receive", params: payload, headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to include("Bearer")
      expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
    end

    it "con un token inventado devuelve 401" do
      post "/api/v1/stock/receive", params: payload,
           headers: headers.merge("Authorization" => "Bearer stk_falso")
      expect(response).to have_http_status(:unauthorized)
    end

    it "con un token revocado devuelve 401" do
      api_token = ApiToken.issue!(user:, name: "revocado", scopes: ApiToken::SCOPES)
      api_token.revoke!

      post "/api/v1/stock/receive", params: payload,
           headers: headers.merge("Authorization" => "Bearer #{api_token.plaintext}")
      expect(response).to have_http_status(:unauthorized)
    end

    it "si el usuario del token está deshabilitado devuelve 403" do
      user.update!(active: false)
      post "/api/v1/stock/receive", params: payload, headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("account_disabled")
    end
  end

  describe "scopes del token" do
    it "un token de sólo lectura NO puede escribir" do
      solo_lectura = ApiToken.issue!(user:, name: "ro", scopes: %w[stock:read]).plaintext

      post "/api/v1/stock/receive", params: payload,
           headers: headers.merge("Authorization" => "Bearer #{solo_lectura}")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("insufficient_scope")
      expect(response.parsed_body.dig("error", "details", "required_scope")).to eq("stock:write")
    end
  end

  describe "POST /api/v1/stock/receive" do
    it "ingresa mercadería y devuelve 201 con el movimiento" do
      post "/api/v1/stock/receive", params: payload(quantity: 25), headers: headers
      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["kind"]).to eq("receipt")
      expect(data["quantity"]).to eq(25)
      expect(data["quantity_after"]).to eq(125)
      expect(item.reload.quantity_on_hand).to eq(125)
    end

    it "404 si el SKU no existe (sin filtrar qué modelo era)" do
      post "/api/v1/stock/receive", params: payload(sku: "NO-EXISTE"), headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "message")).not_to include("Product")
    end

    it "400 si falta un parámetro obligatorio" do
      post "/api/v1/stock/receive", params: { sku: product.sku }.to_json, headers: headers
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "code")).to eq("parameter_missing")
    end

    it "400 si la cantidad no es un entero (no la convierte en 0 en silencio)" do
      post "/api/v1/stock/receive", params: payload(quantity: "diez"), headers: headers
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/v1/stock/issue" do
    it "422 cuando no alcanza el stock, con detalle accionable" do
      post "/api/v1/stock/issue", params: payload(quantity: 500), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      error = response.parsed_body["error"]
      expect(error["code"]).to eq("insufficient_stock")
      expect(error["details"]).to include("available" => 100, "requested" => 500)
    end

    it "no modifica nada cuando falla" do
      expect {
        post "/api/v1/stock/issue", params: payload(quantity: 500), headers: headers
      }.not_to change { item.reload.quantity_on_hand }
    end
  end

  describe "idempotencia" do
    let(:key) { SecureRandom.uuid }
    let(:idem) { headers.merge("Idempotency-Key" => key) }

    it "el reintento devuelve la MISMA respuesta y no aplica dos veces" do
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem
      primera = response.parsed_body

      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq(primera)
      expect(response.headers["Idempotent-Replay"]).to eq("true")
      expect(item.reload.quantity_on_hand).to eq(110)   # sumó 10 UNA vez
    end

    it "la misma clave con OTRO cuerpo devuelve 422 (previene el reuso accidental)" do
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem
      post "/api/v1/stock/receive", params: payload(quantity: 99), headers: idem

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("idempotency_key_reuse")
      expect(item.reload.quantity_on_hand).to eq(110)
    end

    it "claves distintas aplican las dos veces" do
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: headers.merge("Idempotency-Key" => "a")
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: headers.merge("Idempotency-Key" => "b")
      expect(item.reload.quantity_on_hand).to eq(120)
    end

    it "sin la cabecera, funciona normal (es opcional)" do
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: headers
      expect(response).to have_http_status(:created)
      expect(response.headers["Idempotent-Replay"]).to be_nil
    end

    it "las claves están SCOPEADAS POR USUARIO (no se envenena la cache de otro)" do
      post "/api/v1/stock/receive", params: payload(quantity: 10), headers: idem

      otro_user = create(:user, :manager)
      otro_token = ApiToken.issue!(user: otro_user, name: "otro", scopes: ApiToken::SCOPES).plaintext

      post "/api/v1/stock/receive", params: payload(quantity: 7),
           headers: idem.merge("Authorization" => "Bearer #{otro_token}")

      expect(response).to have_http_status(:created)
      expect(item.reload.quantity_on_hand).to eq(117)
    end
  end

  describe "POST /api/v1/stock/adjust" do
    it "requiere rol manager o superior" do
      operador = create(:user, :operator)
      tk = ApiToken.issue!(user: operador, name: "op", scopes: ApiToken::SCOPES).plaintext

      post "/api/v1/stock/adjust",
           params: { sku: product.sku, warehouse_code: warehouse.code,
                     counted_quantity: 95, reason: "Conteo" }.to_json,
           headers: headers.merge("Authorization" => "Bearer #{tk}")

      expect(response).to have_http_status(:forbidden)
    end

    it "un manager sí puede" do
      post "/api/v1/stock/adjust",
           params: { sku: product.sku, warehouse_code: warehouse.code,
                     counted_quantity: 95, reason: "Conteo cíclico" }.to_json,
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("data", "quantity")).to eq(-5)
    end
  end
end
