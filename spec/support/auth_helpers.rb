# frozen_string_literal: true

# Helpers de login para los system specs (browser real).
module AuthHelpers
  def sign_in_as(user, password: "password123")
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Contraseña", with: password
    click_button "Ingresar"
    # Esperamos a que la navegación termine. Capybara ya hace waiting
    # automático en los matchers, por eso NO hace falta un sleep.
    expect(page).to have_current_path(root_path, wait: 5)
  end
end
