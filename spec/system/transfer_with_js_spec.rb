# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# SYSTEM TEST CON JAVASCRIPT REAL (Chromium headless).
#
# `js: true` cambia el driver de rack_test a Selenium. La diferencia es enorme:
#   * rack_test  -> parsea el HTML, no ejecuta JS, es instantáneo.
#   * selenium   -> browser de verdad, ejecuta Stimulus/Turbo, tarda ~1 s por test.
#
# Regla: sólo marcá `js: true` cuando el comportamiento QUE ESTÁS PROBANDO
# depende de JavaScript. Acá sí: el botón "Agregar línea" lo maneja un
# controller de Stimulus, y con rack_test no pasaría nada.
#
# NUNCA uses `sleep` para esperar al browser. Los matchers de Capybara
# (`have_selector`, `have_content`) ya reintentan hasta `default_max_wait_time`.
# Un `sleep 2` hace la suite lenta y flakey al mismo tiempo.
# ==============================================================================
RSpec.describe "Transferencias con JavaScript", type: :system, js: true do
  let!(:user) { create(:user, :manager, email_address: "ana@stock.test", password: "password123") }
  let!(:origen) { create(:warehouse, code: "BA-01", name: "Buenos Aires") }
  let!(:destino) { create(:warehouse, code: "CB-01", name: "Córdoba") }
  let!(:transito) { create(:warehouse, :transit) }
  let!(:p1) { create(:product, sku: "TOR-001", name: "Tornillo") }
  let!(:p2) { create(:product, sku: "MAR-500", name: "Martillo") }

  before do
    [ p1, p2 ].each do |p|
      Stock::Receive.call(product: p, warehouse: origen, quantity: 100, user:,
                          event_recorder: Outbox::NullRecorder.new)
    end
    sign_in_as(user)
  end

  it "el controller de Stimulus agrega líneas al formulario" do
    visit new_stock_transfer_path

    expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 1)

    click_button "+ Agregar línea"
    # Sin sleep: `have_css` con count espera solo hasta que se cumpla.
    expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 2)

    click_button "+ Agregar línea"
    expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 3)
  end

  it "crea una transferencia de dos líneas y la despacha" do
    visit new_stock_transfer_path

    select "BA-01 — Buenos Aires", from: "source_warehouse_code"
    select "CB-01 — Córdoba", from: "destination_warehouse_code"

    click_button "+ Agregar línea"
    expect(page).to have_css("[data-transfer-lines-target='container'] > div", count: 2)

    filas = all("[data-transfer-lines-target='container'] > div")
    within(filas[0]) do
      find("select").select("TOR-001 — Tornillo")
      find("input[type=number]").set("30")
    end
    within(filas[1]) do
      find("select").select("MAR-500 — Martillo")
      find("input[type=number]").set("15")
    end

    click_button "Crear transferencia"

    expect(page).to have_content("creada")
    transfer = StockTransfer.last
    expect(transfer.lines.count).to eq(2)
    expect(transfer.total_units_requested).to eq(45)

    click_button "Despachar"

    expect(page).to have_content("Transferencia despachada.")
    expect(transfer.reload).to be_in_transit
    expect(StockItem.find_by(product: p1, warehouse: origen).quantity_on_hand).to eq(70)
    expect(StockItem.find_by(product: p1, warehouse: transito).quantity_on_hand).to eq(30)
  end

  it "rechaza una transferencia con el mismo depósito de origen y destino" do
    visit new_stock_transfer_path

    select "BA-01 — Buenos Aires", from: "source_warehouse_code"
    select "BA-01 — Buenos Aires", from: "destination_warehouse_code"

    filas = all("[data-transfer-lines-target='container'] > div")
    within(filas[0]) do
      find("select").select("TOR-001 — Tornillo")
      find("input[type=number]").set("5")
    end

    click_button "Crear transferencia"

    expect(page).to have_content("debe ser distinto del origen")
  end
end
