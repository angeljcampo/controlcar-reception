# frozen_string_literal: true

# Orquesta el ingest de un PDF en la knowledge base:
#
#   PdfExtractor → Chunker (según chunking_strategy)
#                → SpanishTranslator (opcional)
#                → BatchEmbedder
#                → KnowledgeChunk.insert_all
#
# Status transitions:
#   pending → processing → ready
#                       └→ failed (con error_message)
#
# Idempotente:
#   - Si el documento ya está :ready, salimos sin hacer nada
#   - Re-ingesta limpia chunks viejos antes de insertar nuevos
#
# Param translate:
#   - true (default): traduce chunks al español antes de embeber.
#     Recomendado para producción y demo final.
#   - false: skip traducción. Útil para iteración rápida sin costo.
class IngestPdfJob < ApplicationJob
  queue_as :ai

  discard_on Ai::Ingestion::SpanishTranslator::MissingApiKey
  discard_on Ai::Ingestion::BatchEmbedder::MissingApiKey
  # Si el documento fue eliminado entre encolado y ejecución (cleanup,
  # re-ingest manual, etc.), descartar el job. No hay nada que reintentar.
  # Sin esto, retry_on agarra el RecordNotFound y reintenta 3 veces — ruido.
  discard_on ActiveRecord::RecordNotFound

  retry_on Ai::Ingestion::BatchEmbedder::EmbeddingError,
           Ai::Ingestion::SpanishTranslator::TranslationError,
           Net::ReadTimeout,
           wait: 10.seconds,
           attempts: 3

  # @param document_id [Integer]
  # @param translate [Boolean] traducir al español antes de embeber
  def perform(document_id, translate: true)
    @doc = KnowledgeDocument.find(document_id)

    if @doc.ready?
      Rails.logger.info("[IngestPdfJob] doc #{@doc.id} already ready, skipping")
      return
    end

    @doc.update!(status: "processing", error_message: nil)
    broadcast_safely

    pages         = extract
    chunks        = chunk_pages(pages)
    translated    = translate ? translate_chunks(chunks) : chunks
    embedded      = embed_chunks(translated)

    persist_chunks(embedded[:chunks])

    @doc.update!(
      status:                "ready",
      total_chunks:          embedded[:chunks].size,
      total_pages:           pages.size,
      embedding_tokens:      embedded[:total_tokens],
      embedding_cost_cents:  embedded[:total_cost_cents]
    )
    broadcast_safely
  rescue => e
    Rails.logger.error("[IngestPdfJob] failed: #{e.class}: #{e.message}")
    if @doc
      @doc.update(
        status:        "failed",
        error_message: "#{e.class}: #{e.message.truncate(500)}"
      )
      broadcast_safely
    end
    raise
  end

  private

  def extract
    Rails.logger.info("[IngestPdfJob] extracting #{@doc.title}")
    @doc.file.open do |tempfile|
      Ai::Ingestion::PdfExtractor.call(tempfile.path)
    end
  end

  def chunk_pages(pages)
    Rails.logger.info(
      "[IngestPdfJob] chunking #{@doc.title} with strategy=#{@doc.chunking_strategy}"
    )

    chunker_class = case @doc.chunking_strategy
                    when "structured_dtc" then Ai::Ingestion::StructuredDtcChunker
                    when "token_window"   then Ai::Ingestion::TokenWindowChunker
                    else
                      raise "Unknown chunking_strategy: #{@doc.chunking_strategy.inspect}"
                    end

    chunks = chunker_class.call(pages, document_title: @doc.title)
    Rails.logger.info("[IngestPdfJob] produced #{chunks.size} chunks")
    chunks
  rescue Ai::Ingestion::StructuredDtcChunker::DetectionError => e
    # Auto-fallback: el usuario eligió structured_dtc pero el PDF no es
    # un catálogo Ford-style. En lugar de fallar y dejarlo en :failed,
    # caemos a token_window (siempre funciona para prose) y actualizamos
    # la strategy del doc para que quede consistente con cómo se chunkeó
    # realmente. El user obtiene su KB sin tener que reintentar.
    Rails.logger.warn(
      "[IngestPdfJob] structured_dtc no detectó formato en #{@doc.title} " \
      "(#{e.message}). Auto-fallback a token_window."
    )
    @doc.update!(chunking_strategy: :token_window)
    chunks = Ai::Ingestion::TokenWindowChunker.call(pages, document_title: @doc.title)
    Rails.logger.info("[IngestPdfJob] fallback token_window produced #{chunks.size} chunks")
    chunks
  end

  def translate_chunks(chunks)
    Rails.logger.info("[IngestPdfJob] translating #{chunks.size} chunks to ES")
    Ai::Ingestion::SpanishTranslator.call(chunks)
  end

  # Embebe "breadcrumb + content" para que el código DTC del breadcrumb
  # entre en el embedding vector (mejora recall semántico, además del
  # peso 'A' que el breadcrumb tiene en el tsvector).
  def embed_chunks(chunks)
    Rails.logger.info("[IngestPdfJob] embedding #{chunks.size} chunks")

    texts  = chunks.map { |c| "#{c[:breadcrumb]}\n\n#{c[:content]}" }
    result = Ai::Ingestion::BatchEmbedder.call(texts)

    enriched = chunks.each_with_index.map do |c, i|
      c.merge(embedding: result[:embeddings][i])
    end

    {
      chunks:           enriched,
      total_tokens:     result[:total_tokens],
      total_cost_cents: result[:total_cost_cents]
    }
  end

  def persist_chunks(chunks)
    Rails.logger.info("[IngestPdfJob] persisting #{chunks.size} chunks")
    now = Time.current

    KnowledgeChunk.transaction do
      @doc.knowledge_chunks.delete_all   # idempotent re-ingest

      rows = chunks.each_with_index.map do |c, i|
        {
          knowledge_document_id: @doc.id,
          content:               c[:content],
          breadcrumb:            c[:breadcrumb],
          page_number:           c[:page],
          chunk_index:           i,
          embedding:             c[:embedding],
          metadata:              c[:metadata] || {},
          created_at:            now,
          updated_at:            now
        }
      end

      KnowledgeChunk.insert_all!(rows)
    end
  end

  # Best-effort Turbo broadcast. La UI de /knowledge se conecta y se entera
  # del cambio de status. Si Cable está roto no rompemos el job.
  def broadcast_safely
    Turbo::StreamsChannel.broadcast_replace_to(
      "knowledge_documents",
      target:  ActionView::RecordIdentifier.dom_id(@doc),
      partial: "knowledge_documents/row",
      locals:  { document: @doc }
    )
  rescue => e
    Rails.logger.warn("[IngestPdfJob] broadcast failed: #{e.class}: #{e.message}")
  end
end
