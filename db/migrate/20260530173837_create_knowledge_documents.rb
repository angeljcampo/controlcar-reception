class CreateKnowledgeDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_documents do |t|
      t.string :title, null: false
      t.string :status, null: false, default: "pending"
      t.integer :total_chunks, null: false, default: 0
      t.integer :total_pages
      t.integer :embedding_tokens, null: false, default: 0
      t.integer :embedding_cost_cents, null: false, default: 0
      t.text :error_message

      t.timestamps
    end

    add_index :knowledge_documents, :status
  end
end
