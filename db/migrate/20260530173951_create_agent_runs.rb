class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      t.references :work_order, null: false, foreign_key: true
      t.string :agent_name, null: false
      t.string :ai_model
      t.string :status, null: false, default: "running"
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cost_cents
      t.integer :latency_ms
      t.text :error_message
      t.jsonb :raw_log

      t.timestamps
    end

    add_index :agent_runs, :status
    add_index :agent_runs, :created_at
  end
end
