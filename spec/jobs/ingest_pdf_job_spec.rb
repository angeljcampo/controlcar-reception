# frozen_string_literal: true

require "rails_helper"

RSpec.describe IngestPdfJob do
  let(:doc) {
    d = KnowledgeDocument.create!(title: "Test Doc", chunking_strategy: :token_window, status: :pending)
    d.file.attach(
      io:           File.open(Rails.root.join("db/seed_pdfs/PCS_Diagnostic_Codes.pdf")),
      filename:     "PCS.pdf",
      content_type: "application/pdf"
    )
    d
  }

  # Stubs por defecto para que el job no toque OpenAI ni servicios pesados
  before do
    allow(Ai::Ingestion::SpanishTranslator).to receive(:call) { |chunks| chunks }
    allow(Ai::Ingestion::BatchEmbedder).to receive(:call).and_return(
      embeddings: Array.new(20) { Array.new(1536, 0.1) },
      total_tokens: 100,
      total_cost_cents: 1
    )
  end

  describe "happy path" do
    it "transiciona pending → processing → ready" do
      described_class.perform_now(doc.id, translate: false)

      expect(doc.reload.status).to eq("ready")
    end

    it "persiste KnowledgeChunks en BD" do
      expect {
        described_class.perform_now(doc.id, translate: false)
      }.to change(KnowledgeChunk, :count).by_at_least(1)
    end

    it "actualiza counters del doc (total_chunks, total_pages, tokens, cost)" do
      described_class.perform_now(doc.id, translate: false)
      doc.reload

      expect(doc.total_chunks).to be > 0
      expect(doc.total_pages).to eq(3) # PCS son 3 págs
      expect(doc.embedding_tokens).to eq(100)
      expect(doc.embedding_cost_cents).to eq(1)
    end
  end

  describe "idempotencia" do
    it "skipea si el doc ya está :ready" do
      doc.update!(status: :ready)

      expect(Ai::Ingestion::BatchEmbedder).not_to receive(:call)

      described_class.perform_now(doc.id, translate: false)
    end

    it "re-ingesta limpia chunks viejos primero" do
      doc.update!(status: :failed)
      doc.knowledge_chunks.create!(content: "viejo", chunk_index: 0, embedding: Array.new(1536, 0.5))
      old_id = doc.knowledge_chunks.first.id

      described_class.perform_now(doc.id, translate: false)

      expect(KnowledgeChunk.find_by(id: old_id)).to be_nil
    end
  end

  describe "translate flag" do
    it "cuando translate: true, llama al SpanishTranslator" do
      # No call_original: el stub ya devuelve los chunks tal cual
      expect(Ai::Ingestion::SpanishTranslator).to receive(:call).at_least(:once) { |chunks| chunks }

      described_class.perform_now(doc.id, translate: true)
    end

    it "cuando translate: false, NO llama al SpanishTranslator (ahorro $$)" do
      expect(Ai::Ingestion::SpanishTranslator).not_to receive(:call)

      described_class.perform_now(doc.id, translate: false)
    end
  end

  describe "auto-fallback: structured_dtc → token_window cuando no detecta formato" do
    let(:doc) {
      # PCS no tiene formato Ford-style → structured_dtc va a raise
      d = KnowledgeDocument.create!(title: "Test PCS", chunking_strategy: :structured_dtc, status: :pending)
      d.file.attach(
        io:           File.open(Rails.root.join("db/seed_pdfs/PCS_Diagnostic_Codes.pdf")),
        filename:     "PCS.pdf",
        content_type: "application/pdf"
      )
      d
    }

    it "cae a token_window automáticamente y termina ready" do
      described_class.perform_now(doc.id, translate: false)
      expect(doc.reload.status).to eq("ready")
    end

    it "actualiza chunking_strategy del doc para reflejar el fallback" do
      described_class.perform_now(doc.id, translate: false)
      expect(doc.reload.chunking_strategy).to eq("token_window")
    end
  end

  describe "manejo de errores" do
    it "marca doc :failed con error_message si algo en el pipeline raise" do
      allow(Ai::Ingestion::BatchEmbedder).to receive(:call).and_raise(StandardError, "boom")

      expect { described_class.perform_now(doc.id, translate: false) }.to raise_error(StandardError)

      doc.reload
      expect(doc.status).to eq("failed")
      expect(doc.error_message).to include("boom")
    end

    it "discard_on RecordNotFound (Fase 3 fix de retry zombie)" do
      expect {
        described_class.perform_now(999_999, translate: false)
      }.not_to raise_error
    end
  end
end
