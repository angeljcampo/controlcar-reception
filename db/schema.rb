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

ActiveRecord::Schema[8.1].define(version: 2026_05_30_185226) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_runs", force: :cascade do |t|
    t.string "agent_name", null: false
    t.string "ai_model"
    t.integer "cost_cents"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.integer "input_tokens"
    t.integer "latency_ms"
    t.integer "output_tokens"
    t.jsonb "raw_log"
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.bigint "work_order_id", null: false
    t.index ["created_at"], name: "index_agent_runs_on_created_at"
    t.index ["status"], name: "index_agent_runs_on_status"
    t.index ["work_order_id"], name: "index_agent_runs_on_work_order_id"
  end

  create_table "ai_analyses", force: :cascade do |t|
    t.string "category"
    t.decimal "confidence", precision: 3, scale: 2
    t.datetime "created_at", null: false
    t.jsonb "next_steps", default: [], null: false
    t.text "observations"
    t.jsonb "possible_failures", default: [], null: false
    t.text "priority_reason"
    t.boolean "requires_human_review", default: false, null: false
    t.jsonb "sources", default: [], null: false
    t.string "suggested_priority"
    t.datetime "updated_at", null: false
    t.bigint "work_order_id", null: false
    t.index ["work_order_id"], name: "index_ai_analyses_on_work_order_id", unique: true
  end

  create_table "knowledge_chunks", force: :cascade do |t|
    t.integer "chunk_index", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536
    t.bigint "knowledge_document_id", null: false
    t.integer "page_number"
    t.integer "tokens_count"
    t.datetime "updated_at", null: false
    t.index ["embedding"], name: "index_knowledge_chunks_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["knowledge_document_id"], name: "index_knowledge_chunks_on_knowledge_document_id"
  end

  create_table "knowledge_documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "embedding_cost_cents", default: 0, null: false
    t.integer "embedding_tokens", default: 0, null: false
    t.text "error_message"
    t.string "status", default: "pending", null: false
    t.string "title", null: false
    t.integer "total_chunks", default: 0, null: false
    t.integer "total_pages"
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_knowledge_documents_on_status"
  end

  create_table "vehicles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "make"
    t.string "model"
    t.string "patente", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["patente"], name: "index_vehicles_on_patente", unique: true
  end

  create_table "work_orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customer_name", null: false
    t.integer "mileage"
    t.string "priority", default: "medium", null: false
    t.text "reason", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.bigint "vehicle_id", null: false
    t.index ["created_at"], name: "index_work_orders_on_created_at"
    t.index ["status"], name: "index_work_orders_on_status"
    t.index ["vehicle_id"], name: "index_work_orders_on_vehicle_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_runs", "work_orders"
  add_foreign_key "ai_analyses", "work_orders"
  add_foreign_key "knowledge_chunks", "knowledge_documents"
  add_foreign_key "work_orders", "vehicles"
end
