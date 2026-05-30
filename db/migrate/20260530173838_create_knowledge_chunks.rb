class CreateKnowledgeChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_chunks do |t|
      t.references :knowledge_document, null: false, foreign_key: true
      t.text :content, null: false
      t.integer :page_number
      t.integer :chunk_index, null: false
      t.integer :tokens_count
      t.vector :embedding, limit: 1536

      t.timestamps
    end

    # HNSW index for cosine-distance semantic search (better recall + speed
    # for incremental writes than ivfflat in pgvector >= 0.5.0).
    add_index :knowledge_chunks, :embedding,
              using: :hnsw, opclass: :vector_cosine_ops
  end
end
