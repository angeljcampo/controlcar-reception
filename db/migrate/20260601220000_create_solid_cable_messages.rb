class CreateSolidCableMessages < ActiveRecord::Migration[8.1]
  # Adds the table solid_cable needs for cross-process ActionCable in dev.
  # Lives in the primary DB (no multi-DB split) — solid_cable falls back
  # to ActiveRecord::Base's connection when cable.yml has no `connects_to`.
  # In production we keep the dedicated cable DB defined in database.yml,
  # so this migration is a no-op there (table already lives elsewhere).
  def change
    return if table_exists?(:solid_cable_messages)

    create_table :solid_cable_messages do |t|
      t.binary :channel, limit: 1024, null: false
      t.binary :payload, limit: 536_870_912, null: false
      t.integer :channel_hash, limit: 8, null: false
      t.datetime :created_at, null: false

      t.index :channel
      t.index :channel_hash
      t.index :created_at
    end
  end
end
