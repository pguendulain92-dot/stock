# frozen_string_literal: true

require "rails_helper"

# ==============================================================================
# META-TEST: verifica que la HERRAMIENTA de detección de N+1 esté funcionando.
#
# ¿Por qué testear la herramienta y no sólo el código?
#
# Porque tuvimos exactamente esta falla: `gem "bullet"` estaba en
# `group :development` en vez de `group :development, :test`. La constante no
# existía en test, los guards `if defined?(Bullet)` daban false, y los ejemplos
# marcados `:n_plus_one` pasaban en verde AUNQUE HUBIERA N+1.
#
# Es la peor clase de bug de testing: la suite decía "todo bien" y no estaba
# mirando nada. Un chequeo verde que no verifica es peor que no tener chequeo,
# porque te saca las ganas de mirar.
#
# REGLA GENERAL: cuando una herramienta de test puede desactivarse en silencio
# (un linter, un detector, un mock que no se aplica), escribí un test que
# verifique que ESTÁ ACTIVA. Cuesta cinco líneas.
# ==============================================================================
RSpec.describe "Guardia de N+1 (Bullet)" do
  it "Bullet está cargado en el entorno de test" do
    expect(defined?(Bullet)).to eq("constant"),
      "Bullet no está cargado: revisá que la gema esté en `group :development, :test` del Gemfile."
  end

  it "Bullet está habilitado y configurado para ROMPER la suite" do
    expect(Bullet.enable?).to be(true)

    # `Bullet.raise` NO tiene getter (chocaría con Kernel#raise): el setter
    # instala el notificador UniformNotifier::Raise, así que preguntamos por él.
    expect(UniformNotifier.active_notifiers).to include(UniformNotifier::Raise),
                                               "Bullet no está configurado para levantar excepción: un N+1 se detectaría pero no haría fallar el test."
  end

  it "detecta de verdad un N+1 (prueba la TRAMPA, no el código)", :n_plus_one do
    create_list(:product, 3, :with_category)

    # Esto ES un N+1 a propósito: una query por producto para traer la categoría.
    expect {
      detectando_n_plus_one { Product.all.to_a.each { |p| p.category&.name } }
    }.to raise_error(Bullet::Notification::UnoptimizedQueryError, /category/)
  end

  it "NO se queja cuando el N+1 está resuelto con includes", :n_plus_one do
    create_list(:product, 3, :with_category)

    expect {
      detectando_n_plus_one { Product.includes(:category).to_a.each { |p| p.category&.name } }
    }.not_to raise_error
  end
end
