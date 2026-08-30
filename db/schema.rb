# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_30_161300) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gin"
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.integer "requests_count", default: 0, null: false
    t.datetime "revoked_at"
    t.string "scopes", default: [], null: false, array: true
    t.string "token_digest", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["scopes"], name: "index_api_tokens_on_scopes", using: :gin
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id", "created_at"], name: "index_api_tokens_on_user_id_and_created_at", where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "categories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "depth", default: 0, null: false
    t.text "description"
    t.string "name", null: false
    t.bigint "parent_id"
    t.string "path", default: "", null: false
    t.citext "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_categories_on_parent_id"
    t.index ["path"], name: "index_categories_on_path"
    t.index ["slug"], name: "index_categories_on_slug", unique: true
    t.check_constraint "depth >= 0 AND depth <= 5", name: "categories_depth_check"
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.string "request_fingerprint", null: false
    t.string "request_method", null: false
    t.string "request_path", null: false
    t.jsonb "response_body"
    t.integer "response_status"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["expires_at"], name: "index_idempotency_keys_on_expires_at"
    t.index ["user_id", "key"], name: "index_idempotency_keys_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_idempotency_keys_on_user_id"
    t.check_constraint "status::text = ANY (ARRAY['processing'::character varying::text, 'completed'::character varying::text, 'failed'::character varying::text])", name: "idempotency_keys_status_check"
  end

  create_table "outbox_events", force: :cascade do |t|
    t.bigint "aggregate_id", null: false
    t.string "aggregate_type", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.uuid "event_id", default: -> { "gen_random_uuid()" }, null: false
    t.string "event_type", null: false
    t.integer "event_version", default: 1, null: false
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "published_at"
    t.index ["aggregate_type", "aggregate_id", "id"], name: "index_outbox_events_on_aggregate_type_and_aggregate_id_and_id"
    t.index ["event_id"], name: "index_outbox_events_on_event_id", unique: true
    t.index ["event_type", "occurred_at"], name: "index_outbox_events_on_event_type_and_occurred_at"
    t.index ["id"], name: "index_outbox_events_unpublished", where: "(published_at IS NULL)"
  end

  create_table "product_suppliers", force: :cascade do |t|
    t.bigint "cost_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.integer "lead_time_days", default: 7, null: false
    t.integer "minimum_order_quantity", default: 1, null: false
    t.boolean "preferred", default: false, null: false
    t.bigint "product_id", null: false
    t.bigint "supplier_id", null: false
    t.string "supplier_sku"
    t.datetime "updated_at", null: false
    t.index ["product_id", "supplier_id"], name: "index_product_suppliers_on_product_id_and_supplier_id", unique: true
    t.index ["product_id"], name: "index_one_preferred_supplier_per_product", unique: true, where: "preferred"
    t.index ["supplier_id"], name: "index_product_suppliers_on_supplier_id"
  end

  create_table "products", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.jsonb "attributes_data", default: {}, null: false
    t.string "barcode"
    t.bigint "category_id"
    t.bigint "cost_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.integer "lock_version", default: 0, null: false
    t.string "name", null: false
    t.bigint "price_cents", default: 0, null: false
    t.citext "sku", null: false
    t.string "unit", default: "unit", null: false
    t.datetime "updated_at", null: false
    t.decimal "weight_grams", precision: 12, scale: 3
    t.index ["barcode"], name: "index_products_on_barcode", where: "(barcode IS NOT NULL)"
    t.index ["category_id", "name"], name: "index_products_active_by_category", where: "((discarded_at IS NULL) AND active)"
    t.index ["category_id"], name: "index_products_on_category_id"
    t.index ["name"], name: "index_products_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["sku"], name: "index_products_on_sku", unique: true
    t.check_constraint "char_length(currency::text) = 3", name: "products_currency_check"
    t.check_constraint "cost_cents >= 0", name: "products_cost_check"
    t.check_constraint "price_cents >= 0", name: "products_price_check"
    t.check_constraint "unit::text = ANY (ARRAY['unit'::character varying::text, 'kg'::character varying::text, 'g'::character varying::text, 'l'::character varying::text, 'ml'::character varying::text, 'm'::character varying::text, 'cm'::character varying::text, 'box'::character varying::text, 'pallet'::character varying::text])", name: "products_unit_check"
  end

  create_table "purchase_order_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.bigint "purchase_order_id", null: false
    t.integer "quantity_ordered", null: false
    t.integer "quantity_received", default: 0, null: false
    t.virtual "subtotal_cents", type: :bigint, as: "((quantity_ordered)::bigint * unit_cost_cents)", stored: true
    t.bigint "unit_cost_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_purchase_order_lines_on_product_id"
    t.index ["purchase_order_id", "product_id"], name: "index_purchase_order_lines_on_purchase_order_id_and_product_id", unique: true
    t.check_constraint "quantity_ordered > 0", name: "po_lines_ordered_positive"
    t.check_constraint "quantity_received >= 0 AND quantity_received <= quantity_ordered", name: "po_lines_received_within_ordered"
    t.check_constraint "unit_cost_cents >= 0", name: "po_lines_cost_non_negative"
  end

  create_table "purchase_orders", force: :cascade do |t|
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.string "currency", default: "USD", null: false
    t.date "expected_at"
    t.integer "lines_count", default: 0, null: false
    t.text "notes"
    t.datetime "received_at"
    t.string "reference", null: false
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.bigint "supplier_id", null: false
    t.bigint "total_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["created_by_id"], name: "index_purchase_orders_on_created_by_id"
    t.index ["reference"], name: "index_purchase_orders_on_reference", unique: true
    t.index ["status", "expected_at"], name: "index_open_purchase_orders", where: "((status)::text = ANY (ARRAY[('submitted'::character varying)::text, ('partially_received'::character varying)::text]))"
    t.index ["supplier_id", "status"], name: "index_purchase_orders_on_supplier_id_and_status"
    t.index ["supplier_id"], name: "index_purchase_orders_on_supplier_id"
    t.index ["warehouse_id"], name: "index_purchase_orders_on_warehouse_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'submitted'::character varying::text, 'partially_received'::character varying::text, 'received'::character varying::text, 'cancelled'::character varying::text])", name: "purchase_orders_status_check"
    t.check_constraint "total_cents >= 0", name: "purchase_orders_total_non_negative"
  end

  create_table "sequence_counters", primary_key: "key", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "value", default: 0, null: false
    t.check_constraint "value >= 0", name: "sequence_counters_value_non_negative"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at", where: "(expires_at IS NOT NULL)"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "stock_items", force: :cascade do |t|
    t.string "bin_location"
    t.datetime "created_at", null: false
    t.datetime "last_counted_at"
    t.datetime "last_movement_at"
    t.integer "lock_version", default: 0, null: false
    t.integer "maximum_level"
    t.bigint "product_id", null: false
    t.virtual "quantity_available", type: :integer, as: "(quantity_on_hand - quantity_reserved)", stored: true
    t.integer "quantity_on_hand", default: 0, null: false
    t.integer "quantity_reserved", default: 0, null: false
    t.integer "reorder_point", default: 0, null: false
    t.integer "reorder_quantity", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["product_id", "warehouse_id"], name: "index_stock_items_on_product_id_and_warehouse_id", unique: true
    t.index ["warehouse_id", "product_id"], name: "index_stock_items_on_warehouse_id_and_product_id"
    t.index ["warehouse_id", "quantity_available"], name: "index_stock_items_needing_reorder", where: "(quantity_available <= reorder_point)"
    t.check_constraint "maximum_level IS NULL OR maximum_level >= reorder_point", name: "stock_items_max_gte_reorder"
    t.check_constraint "quantity_on_hand >= 0", name: "stock_items_on_hand_non_negative"
    t.check_constraint "quantity_reserved <= quantity_on_hand", name: "stock_items_reserved_lte_on_hand"
    t.check_constraint "quantity_reserved >= 0", name: "stock_items_reserved_non_negative"
    t.check_constraint "reorder_point >= 0", name: "stock_items_reorder_point_non_negative"
  end

  create_table "stock_movements", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.string "idempotency_key"
    t.string "kind", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", null: false
    t.integer "quantity_after", null: false
    t.text "reason"
    t.bigint "reference_id"
    t.string "reference_type"
    t.bigint "stock_item_id", null: false
    t.bigint "unit_cost_cents"
    t.bigint "user_id"
    t.bigint "warehouse_id", null: false
    t.index ["idempotency_key"], name: "index_stock_movements_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["product_id", "occurred_at"], name: "index_stock_movements_on_product_id_and_occurred_at", order: { occurred_at: :desc }
    t.index ["reference_type", "reference_id"], name: "index_stock_movements_on_reference_type_and_reference_id", where: "(reference_type IS NOT NULL)"
    t.index ["stock_item_id", "occurred_at", "id"], name: "index_stock_movements_ledger", order: { occurred_at: :desc, id: :desc }
    t.index ["user_id"], name: "index_stock_movements_on_user_id"
    t.index ["warehouse_id", "occurred_at"], name: "index_stock_movements_on_warehouse_id_and_occurred_at", order: { occurred_at: :desc }
    t.check_constraint "(kind::text = ANY (ARRAY['receipt'::character varying::text, 'transfer_in'::character varying::text, 'return'::character varying::text])) AND quantity > 0 OR (kind::text = ANY (ARRAY['issue'::character varying::text, 'transfer_out'::character varying::text, 'scrap'::character varying::text])) AND quantity < 0 OR (kind::text = ANY (ARRAY['adjustment'::character varying::text, 'count_correction'::character varying::text]))", name: "stock_movements_sign_matches_kind"
    t.check_constraint "kind::text = ANY (ARRAY['receipt'::character varying::text, 'issue'::character varying::text, 'adjustment'::character varying::text, 'transfer_in'::character varying::text, 'transfer_out'::character varying::text, 'return'::character varying::text, 'scrap'::character varying::text, 'count_correction'::character varying::text])", name: "stock_movements_kind_check"
    t.check_constraint "quantity <> 0", name: "stock_movements_quantity_not_zero"
    t.check_constraint "quantity_after >= 0", name: "stock_movements_quantity_after_non_negative"
  end

  create_table "stock_reservations", force: :cascade do |t|
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "idempotency_key"
    t.integer "quantity", null: false
    t.text "reason"
    t.bigint "reference_id"
    t.string "reference_type"
    t.datetime "released_at"
    t.string "status", default: "held", null: false
    t.bigint "stock_item_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["expires_at"], name: "index_active_reservations_by_expiry", where: "((status)::text = 'held'::text)"
    t.index ["idempotency_key"], name: "index_stock_reservations_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["reference_type", "reference_id"], name: "index_stock_reservations_on_reference_type_and_reference_id", where: "(reference_type IS NOT NULL)"
    t.index ["stock_item_id", "status"], name: "index_stock_reservations_on_stock_item_id_and_status"
    t.index ["user_id"], name: "index_stock_reservations_on_user_id"
    t.check_constraint "(status::text <> ALL (ARRAY['released'::character varying::text, 'expired'::character varying::text])) OR released_at IS NOT NULL", name: "stock_reservations_released_at_present"
    t.check_constraint "quantity > 0", name: "stock_reservations_quantity_positive"
    t.check_constraint "status::text <> 'committed'::text OR committed_at IS NOT NULL", name: "stock_reservations_committed_at_present"
    t.check_constraint "status::text = ANY (ARRAY['held'::character varying::text, 'committed'::character varying::text, 'released'::character varying::text, 'expired'::character varying::text])", name: "stock_reservations_status_check"
  end

  create_table "stock_transfer_lines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.integer "quantity_dispatched", default: 0, null: false
    t.integer "quantity_received", default: 0, null: false
    t.integer "quantity_requested", null: false
    t.bigint "stock_transfer_id", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_stock_transfer_lines_on_product_id"
    t.index ["stock_transfer_id", "product_id"], name: "index_stock_transfer_lines_on_stock_transfer_id_and_product_id", unique: true
    t.index ["stock_transfer_id"], name: "index_stock_transfer_lines_on_stock_transfer_id"
    t.check_constraint "quantity_dispatched >= 0", name: "transfer_lines_dispatched_non_negative"
    t.check_constraint "quantity_received <= quantity_dispatched", name: "transfer_lines_received_lte_dispatched"
    t.check_constraint "quantity_requested > 0", name: "transfer_lines_requested_positive"
  end

  create_table "stock_transfers", force: :cascade do |t|
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.bigint "destination_warehouse_id", null: false
    t.datetime "dispatched_at"
    t.text "notes"
    t.datetime "received_at"
    t.string "reference", null: false
    t.bigint "requested_by_id", null: false
    t.bigint "source_warehouse_id", null: false
    t.string "status", default: "draft", null: false
    t.bigint "transit_warehouse_id"
    t.datetime "updated_at", null: false
    t.index ["destination_warehouse_id"], name: "index_stock_transfers_on_destination_warehouse_id"
    t.index ["reference"], name: "index_stock_transfers_on_reference", unique: true
    t.index ["requested_by_id"], name: "index_stock_transfers_on_requested_by_id"
    t.index ["source_warehouse_id"], name: "index_stock_transfers_on_source_warehouse_id"
    t.index ["status", "created_at"], name: "index_stock_transfers_on_status_and_created_at"
    t.index ["transit_warehouse_id"], name: "index_stock_transfers_on_transit_warehouse_id"
    t.check_constraint "source_warehouse_id <> destination_warehouse_id", name: "stock_transfers_different_warehouses"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying::text, 'in_transit'::character varying::text, 'received'::character varying::text, 'cancelled'::character varying::text])", name: "stock_transfers_status_check"
  end

  create_table "suppliers", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "address"
    t.datetime "created_at", null: false
    t.integer "default_lead_time_days", default: 7, null: false
    t.citext "email"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "phone"
    t.citext "tax_id", null: false
    t.datetime "updated_at", null: false
    t.index ["metadata"], name: "index_suppliers_on_metadata", opclass: :jsonb_path_ops, using: :gin
    t.index ["name"], name: "index_suppliers_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["tax_id"], name: "index_suppliers_on_tax_id", unique: true
    t.check_constraint "default_lead_time_days >= 0", name: "suppliers_lead_time_check"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.citext "email_address", null: false
    t.datetime "last_seen_at"
    t.string "name", default: "", null: false
    t.string "password_digest", null: false
    t.string "role", default: "operator", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "role::text = ANY (ARRAY['admin'::character varying::text, 'manager'::character varying::text, 'operator'::character varying::text, 'viewer'::character varying::text])", name: "users_role_check"
  end

  create_table "warehouses", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "address"
    t.citext "code", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.boolean "virtual", default: false, null: false
    t.index ["active"], name: "index_warehouses_on_active", where: "active"
    t.index ["code"], name: "index_warehouses_on_code", unique: true
  end

  add_foreign_key "api_tokens", "users", on_delete: :cascade
  add_foreign_key "categories", "categories", column: "parent_id", on_delete: :restrict
  add_foreign_key "idempotency_keys", "users", on_delete: :cascade
  add_foreign_key "product_suppliers", "products", on_delete: :cascade
  add_foreign_key "product_suppliers", "suppliers", on_delete: :cascade
  add_foreign_key "products", "categories", on_delete: :restrict
  add_foreign_key "purchase_order_lines", "products", on_delete: :restrict
  add_foreign_key "purchase_order_lines", "purchase_orders", on_delete: :cascade
  add_foreign_key "purchase_orders", "suppliers", on_delete: :restrict
  add_foreign_key "purchase_orders", "users", column: "created_by_id", on_delete: :restrict
  add_foreign_key "purchase_orders", "warehouses", on_delete: :restrict
  add_foreign_key "sessions", "users", on_delete: :cascade
  add_foreign_key "stock_items", "products", on_delete: :restrict
  add_foreign_key "stock_items", "warehouses", on_delete: :restrict
  add_foreign_key "stock_movements", "products", on_delete: :restrict
  add_foreign_key "stock_movements", "stock_items", on_delete: :restrict
  add_foreign_key "stock_movements", "users", on_delete: :nullify
  add_foreign_key "stock_movements", "warehouses", on_delete: :restrict
  add_foreign_key "stock_reservations", "stock_items", on_delete: :restrict
  add_foreign_key "stock_reservations", "users", on_delete: :nullify
  add_foreign_key "stock_transfer_lines", "products", on_delete: :restrict
  add_foreign_key "stock_transfer_lines", "stock_transfers", on_delete: :cascade
  add_foreign_key "stock_transfers", "users", column: "requested_by_id", on_delete: :restrict
  add_foreign_key "stock_transfers", "warehouses", column: "destination_warehouse_id", on_delete: :restrict
  add_foreign_key "stock_transfers", "warehouses", column: "source_warehouse_id", on_delete: :restrict
  add_foreign_key "stock_transfers", "warehouses", column: "transit_warehouse_id", on_delete: :restrict
end
