# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operar stock desde la web", type: :system do
  let!(:user) { create(:user, :manager, email_address: "ana@stock.test", password: "password123") }
  let!(:warehouse) { create(:warehouse, code: "BA-01", name: "Buenos Aires") }
  let!(:product) { create(:product, sku: "TOR-001", name: "Tornillo hexagonal") }
  let!(:item) { create(:stock_item, product:, warehouse:, quantity_on_hand: 100, reorder_point: 20) }

  before { sign_in_as(user) }

  it "muestra el panel con las métricas del inventario" do
    expect(page).to have_content("Panel de control")
    expect(page).to have_content("Unidades en stock")
    expect(page).to have_content("100")
  end

  it "lista los productos y permite buscarlos" do
    create(:product, sku: "MAR-500", name: "Martillo")

    visit products_path
    expect(page).to have_content("TOR-001")
    expect(page).to have_content("MAR-500")

    fill_in "q", with: "Martillo"
    click_button "Filtrar"

    expect(page).to have_content("MAR-500")
    expect(page).not_to have_content("TOR-001")
  end

  it "ingresa mercadería y lo refleja en el ledger" do
    visit stock_item_path(item)

    within("form[action='#{receive_stock_item_path(item)}']") do
      fill_in "quantity", with: 25
      fill_in "reason", with: "Compra a proveedor"
      click_button "Ingresar"
    end

    expect(page).to have_content("Ingreso registrado.")
    expect(item.reload.quantity_on_hand).to eq(125)
    expect(page).to have_content("Compra a proveedor")
  end

  it "muestra un error claro cuando no alcanza el stock" do
    visit stock_item_path(item)

    within("form[action='#{issue_stock_item_path(item)}']") do
      fill_in "quantity", with: 5
      click_button "Egresar"
    end
    expect(page).to have_content("Egreso registrado.")

    # Ahora pedimos más de lo que hay, salteando el max del input.
    page.execute_script("document.querySelector(\"form[action='#{issue_stock_item_path(item)}'] input[name=quantity]\").removeAttribute('max')") rescue nil
    within("form[action='#{issue_stock_item_path(item)}']") do
      fill_in "quantity", with: 99_999
      click_button "Egresar"
    end

    expect(page).to have_content("Stock insuficiente")
    expect(item.reload.quantity_on_hand).to eq(95)
  end

  it "crea un producto nuevo" do
    visit new_product_path

    fill_in "product[sku]", with: "NUE-001"
    fill_in "product[name]", with: "Producto nuevo"
    fill_in "product[cost_cents]", with: 1_500
    fill_in "product[price_cents]", with: 3_000
    click_button "Create Product"

    expect(page).to have_content("Producto creado.")
    expect(Product.find_by(sku: "NUE-001")).to be_present
  end

  it "muestra los errores de validación sin perder lo cargado" do
    visit new_product_path

    fill_in "product[sku]", with: ""
    fill_in "product[name]", with: "Sin SKU"
    click_button "Create Product"

    expect(page).to have_content("impidieron guardar")
    expect(page).to have_field("product[name]", with: "Sin SKU")
  end

  it "el listado de reposición muestra los items bajo el mínimo" do
    item.update!(quantity_on_hand: 5)

    visit low_stock_stock_items_path

    expect(page).to have_content("TOR-001")
  end

  describe "permisos" do
    it "un viewer no ve los formularios de operación" do
      viewer = create(:user, :viewer, email_address: "v@stock.test", password: "password123")
      click_button "Salir"
      sign_in_as(viewer)

      visit stock_item_path(item)

      expect(page).to have_content("TOR-001")
      expect(page).not_to have_button("Ingresar")
      expect(page).not_to have_button("Egresar")
    end
  end
end
