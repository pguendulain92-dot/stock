# frozen_string_literal: true

# ==============================================================================
# FactoryBot vs fixtures (pregunta de entrevista clásica):
#
#   Fixtures: YAML estático, se carga UNA vez por suite, rapidísimo. Contra:
#     es estado global compartido, los tests se acoplan a datos que no declaran,
#     y cuando cambia el schema hay que tocar todos los YAML.
#
#   Factories: se construye lo que el test NECESITA, en el test. Cada ejemplo
#     declara sus datos, se lee solo. Contra: más lento (inserta de verdad) y
#     es fácil crear de más sin darte cuenta.
#
# Regla práctica: factories por defecto, y `build_stubbed` siempre que puedas
# (no toca la base). Ver el comentario en spec/models/product_spec.rb.
# ==============================================================================
FactoryBot.define do
  factory :user do
    # `sequence` garantiza unicidad sin depender del azar. Con Faker a secas,
    # tarde o temprano dos emails colisionan y tenés un test flakey imposible
    # de reproducir.
    sequence(:email_address) { |n| "user#{n}@stock.test" }
    name { Faker::Name.name }
    password { "password123" }
    role { "operator" }
    active { true }

    # TRAITS: variaciones nombradas. `create(:user, :admin)` se lee mucho mejor
    # que `create(:user, role: "admin")` y centraliza el significado.
    trait(:admin)    { role { "admin" } }
    trait(:manager)  { role { "manager" } }
    trait(:operator) { role { "operator" } }
    trait(:viewer)   { role { "viewer" } }
    trait(:inactive) { active { false } }
  end
end
