# frozen_string_literal: true

FactoryBot.define do
  factory :category do
    sequence(:name) { |n| "Categoría #{n}" }
    sequence(:slug) { |n| "categoria-#{n}" }
    active { true }
  end

  factory :supplier do
    sequence(:name) { |n| "Proveedor #{n}" }
    sequence(:tax_id) { |n| "30#{n.to_s.rjust(9, '0')}" }
    email { Faker::Internet.email }
    default_lead_time_days { 7 }
    active { true }
  end

  factory :warehouse do
    sequence(:code) { |n| "WH#{n.to_s.rjust(2, '0')}" }
    sequence(:name) { |n| "Depósito #{n}" }
    timezone { "UTC" }
    active { true }
    virtual { false }

    trait(:inactive) { active { false } }
    trait(:transit) do
      code { Warehouse::TRANSIT_CODE }
      name { "En tránsito" }
      virtual { true }
    end
  end

  factory :product do
    sequence(:sku) { |n| "SKU-#{n.to_s.rjust(5, '0')}" }
    sequence(:name) { |n| "Producto #{n}" }
    unit { "unit" }
    cost_cents { 1_000 }
    price_cents { 2_500 }
    currency { "USD" }
    active { true }

    trait(:discarded) { discarded_at { Time.current } }
    trait(:inactive) { active { false } }
    trait(:with_category) { association :category }
  end

  factory :product_supplier do
    association :product
    association :supplier
    cost_cents { 900 }
    lead_time_days { 5 }
    minimum_order_quantity { 1 }
    preferred { false }
  end

  factory :api_token do
    association :user
    name { "spec token" }
    scopes { ApiToken::SCOPES }
    token_digest { ApiToken.digest(SecureRandom.hex(32)) }
    sequence(:token_prefix) { |n| "stk_test#{n}" }
  end
end
