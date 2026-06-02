class CreateRetrievalRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :retrieval_runs do |t|
      t.references :agent_run, null: false, foreign_key: true, index: true

      # Lo que buscó el LLM (la query que pasó al tool).
      t.text :query, null: false

      # Parámetros de la búsqueda.
      t.integer :top_k, null: false

      # Métricas de calidad del retrieval. El LLM las usa para ajustar
      # confidence; nosotros las renderizamos en el agent_runs view como
      # talking point de observabilidad ("uso inteligente de IA").
      t.integer :total_matches,        null: false, default: 0
      t.integer :strong_matches_count, null: false, default: 0
      t.boolean :threshold_passed,     null: false, default: false
      t.decimal :best_vector_distance, precision: 6, scale: 4

      # Detalle granular: [{chunk_id, vector_rank, keyword_rank,
      #                     vector_distance, fused_rank, fused_score}, ...]
      t.jsonb :results, null: false, default: []

      # Costos / latencia del retrieval (separado del LLM).
      t.integer :latency_ms,       null: false, default: 0
      t.integer :embedding_tokens, null: false, default: 0

      t.timestamps
    end
  end
end
