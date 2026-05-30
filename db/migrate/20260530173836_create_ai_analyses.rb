class CreateAiAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_analyses do |t|
      t.references :work_order, null: false, foreign_key: true, index: { unique: true }
      t.string :category
      t.jsonb :possible_failures, null: false, default: []
      t.string :suggested_priority
      t.text :priority_reason
      t.jsonb :next_steps, null: false, default: []
      t.jsonb :sources, null: false, default: []
      t.decimal :confidence, precision: 3, scale: 2
      t.boolean :requires_human_review, null: false, default: false

      t.timestamps
    end
  end
end
