# frozen_string_literal: true

# ==============================================================================
# db/seeds.rb — datos de arranque + un dataset de demo.
#
# REGLA DE ORO: los seeds tienen que ser IDEMPOTENTES. `bin/rails db:seed` se
# corre muchas veces (cada deploy, cada `db:prepare`, cada onboarding). Si usás
# `create!` a secas, la segunda corrida explota contra los índices únicos.
# Por eso todo va con `find_or_create_by!` / `upsert`.
#
# Corré `SEED_DEMO=false bin/rails db:seed` para cargar sólo lo imprescindible.
# ==============================================================================

require "securerandom"

puts "→ Sembrando datos base…"

# ── Usuarios ──────────────────────────────────────────────────────────────────
# En producción la contraseña sale de una variable de entorno; JAMÁS hardcodeada.
admin_password = ENV.fetch("SEED_ADMIN_PASSWORD", "password123")

users = {
  admin: [ "admin@stock.test", "Ana Admin", "admin" ],
  manager: [ "manager@stock.test", "Mateo Manager", "manager" ],
  operator: [ "operador@stock.test", "Olivia Operadora", "operator" ],
  viewer: [ "viewer@stock.test", "Valentín Viewer", "viewer" ]
}.transform_values do |(email, name, role)|
  User.find_or_create_by!(email_address: email) do |u|
    u.name = name
    u.role = role
    u.password = admin_password
  end
end

puts "  ✓ #{User.count} usuarios (contraseña: #{admin_password})"

# ── Token de API para probar con curl ────────────────────────────────────────
if ApiToken.where(user: users[:admin], name: "seed-token").none?
  token = ApiToken.issue!(
    user: users[:admin], name: "seed-token",
    scopes: %w[stock:read stock:write catalog:read catalog:write transfers:write]
  )
  puts "  ✓ Token de API (guardalo, no se vuelve a mostrar): #{token.plaintext}"
end

# ── Depósitos ─────────────────────────────────────────────────────────────────
# El depósito IN-TRANSIT es OBLIGATORIO: sin él no funcionan las transferencias.
# Ver el comentario en db/migrate/*_create_stock_transfers.rb.
warehouses = [
  { code: "BA-01", name: "Centro de distribución Buenos Aires",
    address: "Av. Corrientes 1234, CABA", timezone: "America/Argentina/Buenos_Aires" },
  { code: "CB-01", name: "Depósito Córdoba",
    address: "Bv. San Juan 500, Córdoba", timezone: "America/Argentina/Cordoba" },
  { code: "MZ-01", name: "Depósito Mendoza",
    address: "San Martín 800, Mendoza", timezone: "America/Argentina/Mendoza" },
  { code: Warehouse::TRANSIT_CODE, name: "Mercadería en tránsito", virtual: true }
].map { |attrs| Warehouse.find_or_create_by!(code: attrs[:code]) { |w| w.assign_attributes(attrs) } }

puts "  ✓ #{Warehouse.count} depósitos"

# ── Categorías (árbol) ────────────────────────────────────────────────────────
raiz = {
  "Ferretería" => [ "Tornillería", "Herramientas manuales", "Herramientas eléctricas" ],
  "Electricidad" => [ "Cables", "Iluminación" ],
  "Sanitarios" => [ "Grifería", "Caños" ]
}

categories = {}
raiz.each do |parent_name, children|
  parent = Category.find_or_create_by!(slug: parent_name.parameterize) { |c| c.name = parent_name }
  categories[parent_name] = parent
  children.each do |child_name|
    categories[child_name] = Category.find_or_create_by!(slug: child_name.parameterize) do |c|
      c.name = child_name
      c.parent = parent
    end
  end
end

puts "  ✓ #{Category.count} categorías"

exit 0 unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("SEED_DEMO", "true"))

puts "→ Sembrando dataset de demo…"

# ── Proveedores ───────────────────────────────────────────────────────────────
suppliers = [
  [ "Distribuidora del Plata SA", "30712345678", "ventas@delplata.test", 5 ],
  [ "Importadora Andina SRL", "30798765432", "pedidos@andina.test", 21 ],
  [ "Herrajes Nacionales", "30755544433", "contacto@herrajes.test", 10 ]
].map do |name, tax_id, email, lead|
  Supplier.find_or_create_by!(tax_id: tax_id) do |s|
    s.name = name
    s.email = email
    s.default_lead_time_days = lead
  end
end

# ── Productos ─────────────────────────────────────────────────────────────────
catalog = [
  [ "TOR-M5-20", "Tornillo métrica 5 x 20mm", "Tornillería", "unit", 12, 35 ],
  [ "TOR-M6-30", "Tornillo métrica 6 x 30mm", "Tornillería", "unit", 18, 49 ],
  [ "TUE-M5", "Tuerca métrica 5", "Tornillería", "unit", 7, 20 ],
  [ "ARA-M5", "Arandela plana 5mm", "Tornillería", "unit", 4, 12 ],
  [ "MAR-500", "Martillo carpintero 500g", "Herramientas manuales", "unit", 4_500, 9_900 ],
  [ "DES-PH2", "Destornillador Phillips PH2", "Herramientas manuales", "unit", 1_200, 2_800 ],
  [ "LLA-AJU-10", "Llave ajustable 10\"", "Herramientas manuales", "unit", 3_800, 8_500 ],
  [ "TAL-750", "Taladro percutor 750W", "Herramientas eléctricas", "unit", 42_000, 89_900 ],
  [ "AMO-115", "Amoladora angular 115mm", "Herramientas eléctricas", "unit", 38_000, 79_900 ],
  [ "CAB-25-100", "Cable unipolar 2.5mm x 100m", "Cables", "unit", 28_000, 54_000 ],
  [ "CAB-15-100", "Cable unipolar 1.5mm x 100m", "Cables", "unit", 19_000, 37_000 ],
  [ "LAM-LED-9", "Lámpara LED 9W E27", "Iluminación", "unit", 900, 2_400 ],
  [ "REF-LED-18", "Reflector LED 18W", "Iluminación", "unit", 5_600, 12_900 ],
  [ "CAN-FLE-12", "Canilla flexible 1/2\"", "Grifería", "unit", 2_100, 4_900 ],
  [ "CNO-PVC-110", "Caño PVC 110mm x 3m", "Caños", "m", 6_400, 13_500 ]
]

products = catalog.map do |sku, name, category_name, unit, cost, price|
  Product.find_or_create_by!(sku: sku) do |p|
    p.name = name
    p.category = categories[category_name]
    p.unit = unit
    p.cost_cents = cost
    p.price_cents = price
    p.currency = "ARS"
    p.barcode = "779#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}"
  end
end

# Relación producto-proveedor, con un preferido por producto.
products.each_with_index do |product, index|
  supplier = suppliers[index % suppliers.size]
  ProductSupplier.find_or_create_by!(product:, supplier:) do |ps|
    ps.cost_cents = (product.cost_cents * 0.92).round
    ps.currency = product.currency
    ps.lead_time_days = supplier.default_lead_time_days
    ps.preferred = true
  end
end

puts "  ✓ #{Product.count} productos"

# ── Existencias + historial ──────────────────────────────────────────────────
# Generamos el stock A TRAVÉS DE LOS SERVICES, no con INSERTs directos. Así el
# ledger queda coherente desde el primer día y los seeds prueban el dominio.
physical = warehouses.reject(&:virtual?)
operator = users[:operator]

if StockMovement.count.zero?
  products.each do |product|
    physical.each_with_index do |warehouse, index|
      # Cantidades variadas y determinísticas (sin rand: los seeds tienen que
      # ser REPRODUCIBLES; un seed aleatorio hace que los bugs no se repitan).
      base = ((product.id * 7 + warehouse.id * 13) % 120) + 5

      Stock::Receive.call(
        product:, warehouse:, quantity: base, user: operator,
        unit_cost_cents: product.cost_cents, reason: "Carga inicial de inventario"
      )

      # Algunos egresos para tener historial.
      outgoing = (base / 3.0).floor
      if outgoing.positive?
        Stock::Issue.call(product:, warehouse:, quantity: outgoing, user: operator,
                          reason: "Venta mostrador")
      end

      # Punto de reorden: dejamos algunos productos por debajo, a propósito,
      # para que el dashboard de reposición tenga datos.
      item = StockItem.find_by(product:, warehouse:)
      item&.update!(
        reorder_point: index.zero? ? (base * 0.8).round : (base * 0.2).round,
        reorder_quantity: base,
        bin_location: format("P%d-%s-%02d", (product.id % 8) + 1, ("A".."F").to_a[product.id % 6], (product.id % 20) + 1)
      )
    end
  end

  # Una reserva viva, para ver el flujo de disponibilidad.
  first_item = StockItem.where("quantity_available > 10").first
  if first_item
    Stock::Reserve.call(product: first_item.product, warehouse: first_item.warehouse,
                        quantity: 5, user: operator, ttl: 2.hours,
                        reason: "Pedido web #1024")
  end

  # Una transferencia en tránsito, para ver el estado intermedio.
  source, destination = physical.first(2)
  movable = StockItem.where(warehouse: source).where("quantity_available >= 10").limit(3).includes(:product)
  if movable.size >= 2 && destination
    transfer = StockTransfer.create!(source_warehouse: source, destination_warehouse: destination,
                                     requested_by: users[:manager], notes: "Reposición semanal")
    movable.each { |item| transfer.lines.create!(product: item.product, quantity_requested: 5) }
    Stock::Transfers::Dispatch.call(transfer:, user: operator)
  end
end

puts "  ✓ #{StockItem.count} existencias, #{StockMovement.count} movimientos"
puts "  ✓ #{OutboxEvent.count} eventos en el outbox"
puts ""
puts "Listo. Ingresá con admin@stock.test / #{admin_password}"
