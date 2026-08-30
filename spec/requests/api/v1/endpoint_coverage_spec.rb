# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# SMOKE TEST DE COBERTURA DE ENDPOINTS.
#
# Este spec existe por un bug real: `GET /api/v1/reservations` devolvía 500 para
# CUALQUIER request porque faltaba StockReservationPolicy, y nadie se enteró
# porque ningún test ejecutaba esa acción.
#
# La lección general: `verify_policy_scoped` te obliga a LLAMAR a policy_scope,
# pero no puede saber que la policy no existe hasta que alguien ejecuta el
# código. Los chequeos estáticos tienen ese límite.
#
# La solución sistemática: un test que recorre TODAS las rutas de la API y las
# ejecuta. No verifica la lógica (para eso están los otros specs) — verifica
# que ninguna devuelva 5xx. Es barato y atrapa toda una clase de bugs:
# policies que faltan, serializers rotos, constantes mal escritas, filtros que
# explotan.
#
# El test se ACTUALIZA SOLO: si mañana agregás un endpoint, aparece en la lista
# de rutas y si revienta, el test falla. No hay que acordarse de nada.
# ==============================================================================
RSpec.describe "API v1 · cobertura de endpoints", type: :request do
  let(:user) { create(:user, :admin) }
  let(:token) { ApiToken.issue!(user:, name: "smoke", scopes: ApiToken::SCOPES).plaintext }
  let(:headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  # Datos mínimos para que los endpoints con :id tengan algo que buscar.
  let!(:warehouse) { create(:warehouse, code: "BA-01") }
  let!(:transito) { create(:warehouse, :transit) }
  let!(:product) { create(:product, sku: "SMOKE-1") }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100) }
  let!(:supplier) { create(:supplier, tax_id: "30700000001") }
  let!(:reservation) do
    Stock::Reserve.call(product:, warehouse:, quantity: 5, user:,
                        event_recorder: Outbox::NullRecorder.new).value
  end
  let!(:transfer) do
    t = create(:stock_transfer, source_warehouse: warehouse,
                                destination_warehouse: create(:warehouse), requested_by: user)
    t.lines.create!(product:, quantity_requested: 1)
    t
  end
  let!(:order) do
    o = create(:purchase_order, supplier:, warehouse:, created_by: user)
    o.lines.create!(product:, quantity_ordered: 1, unit_cost_cents: 100)
    o
  end

  # Sustituye los segmentos dinámicos por valores que existen de verdad.
  def resolver(path, controller)
    valor =
      case controller
      when "api/v1/products"         then product.sku
      when "api/v1/warehouses"       then warehouse.code
      when "api/v1/stock_items"      then item.id
      when "api/v1/reservations"     then reservation.id
      when "api/v1/stock_transfers"  then transfer.id
      when "api/v1/purchase_orders"  then order.reference
      else 1
      end

    path.sub("(.:format)", "").gsub(/:\w+/, valor.to_s)
  end

  # Cuerpos válidos para los POST que los necesitan.
  BODIES = {
    "api/v1/stock_operations#receive" => -> (ctx) {
      { sku: ctx[:product].sku, warehouse_code: ctx[:warehouse].code, quantity: 1 }
    },
    "api/v1/stock_operations#issue" => -> (ctx) {
      { sku: ctx[:product].sku, warehouse_code: ctx[:warehouse].code, quantity: 1 }
    },
    "api/v1/stock_operations#adjust" => -> (ctx) {
      { sku: ctx[:product].sku, warehouse_code: ctx[:warehouse].code,
        counted_quantity: 99, reason: "smoke test" }
    },
    "api/v1/reservations#create" => -> (ctx) {
      { sku: ctx[:product].sku, warehouse_code: ctx[:warehouse].code, quantity: 1 }
    },
    "api/v1/products#create" => -> (_ctx) {
      { product: { sku: "SMOKE-NEW", name: "Nuevo", cost_cents: 1, price_cents: 2 } }
    },
    "api/v1/products#update" => -> (_ctx) { { product: { name: "Renombrado" } } },
    "api/v1/stock_transfers#create" => -> (ctx) {
      { stock_transfer: { source_warehouse_code: ctx[:warehouse].code,
                          destination_warehouse_code: ctx[:destino].code,
                          lines: [ { sku: ctx[:product].sku, quantity: 1 } ] } }
    },
    "api/v1/purchase_orders#create" => -> (ctx) {
      { purchase_order: { supplier_tax_id: ctx[:supplier].tax_id,
                          warehouse_code: ctx[:warehouse].code,
                          lines: [ { sku: ctx[:product].sku, quantity: 1, unit_cost_cents: 100 } ] } }
    }
  }.freeze

  it "ninguna ruta de la API devuelve 5xx" do
    contexto = { product:, warehouse:, supplier:, destino: create(:warehouse, code: "DEST-1") }

    rutas = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s
      next unless path.start_with?("/api/v1/")

      verbo = route.verb.to_s.presence || "GET"
      [ verbo, path, route.defaults[:controller], "#{route.defaults[:controller]}##{route.defaults[:action]}" ]
    end

    expect(rutas.size).to be >= 20   # si baja, alguien borró rutas sin querer

    fallas = []

    rutas.each do |verbo, path, controller, endpoint|
      url = resolver(path, controller)
      body = BODIES[endpoint]&.call(contexto)&.to_json

      case verbo
      when "GET"    then get url, headers: headers
      when "POST"   then post url, params: body, headers: headers
      when "PATCH"  then patch url, params: body, headers: headers
      when "PUT"    then put url, params: body, headers: headers
      when "DELETE" then delete url, headers: headers
      end

      if response.status >= 500
        fallas << "#{verbo} #{url} (#{endpoint}) -> #{response.status}: #{response.body.to_s.truncate(200)}"
      end
    end

    expect(fallas).to be_empty, "Endpoints con error 5xx:\n  #{fallas.join("\n  ")}"
  end
end
