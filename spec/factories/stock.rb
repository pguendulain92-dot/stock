# frozen_string_literal: true

FactoryBot.define do
  factory :stock_item do
    association :product
    association :warehouse
    quantity_on_hand { 100 }
    quantity_reserved { 0 }
    reorder_point { 10 }
    reorder_quantity { 50 }

    trait(:empty) { quantity_on_hand { 0 } }
    trait(:low) do
      quantity_on_hand { 5 }
      reorder_point { 20 }
    end
    trait(:with_reservations) do
      quantity_on_hand { 100 }
      quantity_reserved { 40 }
    end
  end

  factory :stock_movement do
    association :stock_item
    kind { "receipt" }
    quantity { 10 }
    quantity_after { 10 }
    occurred_at { Time.current }

    # `after(:build)` copia los ids denormalizados desde el stock_item, igual
    # que hace el callback del modelo. Sin esto, los movimientos creados por la
    # factory tendrían product_id/warehouse_id de otro producto y los tests de
    # los reportes darían resultados incoherentes.
    after(:build) do |movement|
      movement.product_id ||= movement.stock_item&.product_id
      movement.warehouse_id ||= movement.stock_item&.warehouse_id
    end

    # Traits EXPLÍCITOS: cada uno respeta el CHECK que exige que el signo de la
    # cantidad coincida con el tipo de movimiento (ver la migración).
    trait(:issue) do
      kind { "issue" }
      quantity { -5 }
    end

    trait(:transfer_in) do
      kind { "transfer_in" }
      quantity { 5 }
    end

    trait(:transfer_out) do
      kind { "transfer_out" }
      quantity { -5 }
    end

    trait(:scrap) do
      kind { "scrap" }
      quantity { -1 }
    end

    trait(:adjustment) do
      kind { "adjustment" }
      quantity { -2 }
      reason { "Ajuste por conteo" }
    end
  end

  factory :stock_reservation do
    association :stock_item
    quantity { 5 }
    status { "held" }
    expires_at { 30.minutes.from_now }

    trait(:expired_soon) { expires_at { 1.second.from_now } }

    # Los tres estados terminales necesitan su marca de tiempo, o el CHECK
    # constraint los rechaza. Por eso los escribimos a mano en vez de dejar que
    # factory_bot los invente desde el enum (ver spec/support/factory_bot.rb).
    trait(:already_expired) do
      status { "expired" }
      released_at { Time.current }
      expires_at { 1.hour.ago }
    end

    trait(:released) do
      status { "released" }
      released_at { Time.current }
    end

    trait(:committed) do
      status { "committed" }
      committed_at { Time.current }
    end
  end

  factory :stock_transfer do
    association :source_warehouse, factory: :warehouse
    association :destination_warehouse, factory: :warehouse
    association :requested_by, factory: :user
    status { "draft" }
  end

  factory :stock_transfer_line do
    association :stock_transfer
    association :product
    quantity_requested { 10 }
  end

  factory :purchase_order do
    association :supplier
    association :warehouse
    association :created_by, factory: :user
    status { "draft" }
    currency { "USD" }
  end

  factory :purchase_order_line do
    association :purchase_order
    association :product
    quantity_ordered { 10 }
    unit_cost_cents { 500 }
  end

  factory :outbox_event do
    aggregate_type { "StockItem" }
    aggregate_id { 1 }
    event_type { "stock.receipt" }
    payload { { quantity: 10 } }
    occurred_at { Time.current }
  end
end
