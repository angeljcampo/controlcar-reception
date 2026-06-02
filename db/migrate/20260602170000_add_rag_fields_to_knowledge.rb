class AddRagFieldsToKnowledge < ActiveRecord::Migration[8.1]
  def change
    # ─── KnowledgeDocument ──────────────────────────────────────────────
    # chunking_strategy permite que el ingestor elija cómo trocear:
    #   - "token_window":   prose narrativa, 800 tokens overlap 150
    #   - "structured_dtc": tablas DTC, 1 chunk por código diagnóstico
    add_column :knowledge_documents, :chunking_strategy,
               :string, null: false, default: "token_window"
    add_index  :knowledge_documents, :chunking_strategy

    # ─── KnowledgeChunk ────────────────────────────────────────────────
    # Breadcrumb: ruta legible al chunk
    # ej: "Ford 2007 PCED › P0011 - Intake Camshaft Position Timing - Over-Advanced (Bank 1)"
    # Va prependido al content cuando el LLM lo recibe + boostea relevancia
    # en el ts_rank (setweight 'A' abajo).
    add_column :knowledge_chunks, :breadcrumb, :text

    # Metadata abierta: dtc_code, original_content_en (audit del translate),
    # cross_references resueltas, source_section, etc.
    add_column :knowledge_chunks, :metadata, :jsonb, null: false, default: {}
    add_index  :knowledge_chunks, :metadata, using: :gin

    # ─── Hybrid retrieval: tsvector generada ────────────────────────────
    # Columna STORED auto-mantenida por Postgres. Sin triggers.
    # 'spanish' config aplica stemming (vehículos→vehícul, fallas→fall).
    # Códigos como P0301 quedan como tokens literales (no son palabras),
    # así que keyword exacto funciona out-of-the-box.
    #
    # setweight: breadcrumb pesa más (A=1.0) que content (B=0.4) — los DTC
    # codes viven en breadcrumb, queremos que matcheen primero.
    execute <<~SQL.squish
      ALTER TABLE knowledge_chunks
      ADD COLUMN content_tsv tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('spanish', coalesce(breadcrumb, '')), 'A') ||
        setweight(to_tsvector('spanish', coalesce(content, '')),    'B')
      ) STORED;
    SQL

    add_index :knowledge_chunks, :content_tsv, using: :gin
  end
end
