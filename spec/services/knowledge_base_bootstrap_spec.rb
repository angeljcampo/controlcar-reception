# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeBaseBootstrap do
  # Stub el directorio de seed_pdfs/ para no depender de archivos reales
  # gigantes en cada spec. Cada test arma su propio set de "PDFs disponibles".
  let(:tmp_pdfs_dir) { Rails.root.join("tmp/test_seed_pdfs_#{SecureRandom.hex(4)}") }

  before do
    FileUtils.mkdir_p(tmp_pdfs_dir)
    stub_const("KnowledgeBaseBootstrap::CATALOG", catalog)
    allow_any_instance_of(described_class)
      .to receive(:seed_dir).and_return(tmp_pdfs_dir)
  end

  after do
    FileUtils.rm_rf(tmp_pdfs_dir)
  end

  describe ".call" do
    context "con 1 PDF disponible en el filesystem" do
      let(:catalog) {
        [ {
          filename:          "test.pdf",
          title:             "Test Manual",
          chunking_strategy: :token_window,
          needs_translation: false
        } ]
      }

      before do
        File.write(tmp_pdfs_dir.join("test.pdf"), "fake pdf content")
      end

      it "crea el KnowledgeDocument con la title + chunking_strategy correctos" do
        described_class.call(mode: :async, translate: false)

        doc = KnowledgeDocument.find_by(title: "Test Manual")
        expect(doc).to be_present
        expect(doc.chunking_strategy).to eq("token_window")
        expect(doc.status).to eq("pending")
      end

      it "encola IngestPdfJob (modo async)" do
        expect {
          described_class.call(mode: :async, translate: false)
        }.to have_enqueued_job(IngestPdfJob)
      end

      it "devuelve Result con la lista de queued" do
        result = described_class.call(mode: :async, translate: false)

        expect(result.queued).to eq([ "Test Manual" ])
        expect(result.skipped).to be_empty
        expect(result.missing).to be_empty
      end
    end

    context "idempotencia: si el doc YA está :ready, skipea" do
      let(:catalog) {
        [ {
          filename:          "test.pdf",
          title:             "Already Done",
          chunking_strategy: :token_window,
          needs_translation: false
        } ]
      }

      before do
        File.write(tmp_pdfs_dir.join("test.pdf"), "fake")
        KnowledgeDocument.create!(
          title: "Already Done",
          chunking_strategy: :token_window,
          status: :ready,
          total_chunks: 42
        )
      end

      it "no encola job ni toca el doc existente" do
        expect {
          described_class.call(mode: :async, translate: false)
        }.not_to have_enqueued_job(IngestPdfJob)
      end

      it "reporta el doc como :skipped" do
        result = described_class.call(mode: :async, translate: false)

        expect(result.skipped).to eq([ "Already Done" ])
        expect(result.queued).to be_empty
      end
    end

    context "recover: si el doc existe pero está :failed, lo re-procesa" do
      let(:catalog) {
        [ {
          filename:          "test.pdf",
          title:             "Retry Me",
          chunking_strategy: :token_window,
          needs_translation: false
        } ]
      }

      before do
        File.write(tmp_pdfs_dir.join("test.pdf"), "fake")
        KnowledgeDocument.create!(
          title: "Retry Me",
          chunking_strategy: :token_window,
          status: :failed,
          error_message: "anterior crash"
        )
      end

      it "vuelve a poner en :pending y encola el job" do
        expect {
          described_class.call(mode: :async, translate: false)
        }.to have_enqueued_job(IngestPdfJob)

        doc = KnowledgeDocument.find_by(title: "Retry Me")
        expect(doc.status).to eq("pending")
        expect(doc.error_message).to be_nil
      end
    end

    context "cuando un PDF del CATALOG no existe en filesystem" do
      let(:catalog) {
        [
          { filename: "exists.pdf", title: "Existe",   chunking_strategy: :token_window, needs_translation: false },
          { filename: "missing.pdf", title: "No está", chunking_strategy: :token_window, needs_translation: false }
        ]
      }

      before { File.write(tmp_pdfs_dir.join("exists.pdf"), "fake") }

      it "skipea el missing y procesa los demás (no falla todo)" do
        result = described_class.call(mode: :async, translate: false)

        expect(result.queued).to eq([ "Existe" ])
        expect(result.missing).to eq([ "missing.pdf" ])
      end
    end

    context "needs_translation: false fuerza translate=false sin importar el flag global" do
      let(:catalog) {
        [ {
          filename:          "spanish.pdf",
          title:             "Manual ES",
          chunking_strategy: :token_window,
          needs_translation: false # ya está en español
        } ]
      }

      before { File.write(tmp_pdfs_dir.join("spanish.pdf"), "fake") }

      it "encola el job con translate=false aunque global translate=true" do
        described_class.call(mode: :async, translate: true)

        expect(IngestPdfJob).to have_been_enqueued.with(
          a_kind_of(Integer),
          translate: false
        )
      end
    end
  end
end
