# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Ingestion::TokenWindowChunker do
  let(:doc_title) { "Manual Test" }

  describe ".call" do
    context "con texto corto (< TARGET_CHARS)" do
      let(:pages) { [{ page: 1, text: "Párrafo corto de prueba." }] }

      it "produce 1 solo chunk con todo el contenido" do
        chunks = described_class.call(pages, document_title: doc_title)
        expect(chunks.size).to eq(1)
        expect(chunks.first[:content]).to include("Párrafo corto")
      end
    end

    context "con texto largo que excede TARGET_CHARS" do
      # Generamos ~10k chars de prose en párrafos de ~500 chars cada uno
      let(:pages) do
        body = (1..20).map { |i| "Párrafo #{i}. " + ("Lorem ipsum dolor sit amet. " * 25) }.join("\n\n")
        [{ page: 1, text: body }]
      end

      it "produce múltiples chunks" do
        chunks = described_class.call(pages, document_title: doc_title)
        expect(chunks.size).to be > 1
      end

      it "respeta el target de tamaño aproximado (no chunks gigantes)" do
        chunks = described_class.call(pages, document_title: doc_title)
        chunks.each do |c|
          # TARGET_CHARS = 3200, permitimos 50% slack para overlap + último párrafo
          expect(c[:content].length).to be < 5000
        end
      end

      it "no parte párrafos por la mitad (preserva semántica)" do
        chunks = described_class.call(pages, document_title: doc_title)
        chunks.each do |c|
          # Si parte un párrafo, va a haber Lorem... cortado sin punto/párrafo
          # Verificamos que cada chunk termine en \n\n o final natural
          expect(c[:content].strip).not_to match(/Lorem ipsum dolor sit$/)
        end
      end
    end

    context "metadata del chunk" do
      let(:pages) { [{ page: 1, text: "contenido página uno" }, { page: 2, text: "contenido página dos" }] }

      it "incluye breadcrumb con título + página" do
        chunks = described_class.call(pages, document_title: doc_title)
        expect(chunks.first[:breadcrumb]).to include(doc_title)
        expect(chunks.first[:breadcrumb]).to include("Página 1")
      end

      it "marca strategy: token_window en metadata para auditoría" do
        chunks = described_class.call(pages, document_title: doc_title)
        expect(chunks.first[:metadata][:strategy]).to eq("token_window")
      end
    end

    context "input vacío" do
      it "devuelve array vacío sin error" do
        expect(described_class.call([], document_title: doc_title)).to eq([])
        expect(described_class.call([{ page: 1, text: "" }], document_title: doc_title)).to eq([])
      end
    end

    context "overlap entre chunks consecutivos" do
      let(:pages) do
        # Párrafos chicos (~200 chars) para que algunos quepan en el
        # OVERLAP_CHARS budget de 600. Si son más grandes que el overlap,
        # ningún párrafo cabe ahí y no hay overlap real (eso es por diseño
        # del chunker — preserva semántica de párrafos completos).
        body = (1..30).map { |i| "Marker#{i}. " + ("Texto técnico breve. " * 8) }.join("\n\n")
        [{ page: 1, text: body }]
      end

      it "preserva contexto vía overlap (algún marker aparece en >1 chunk)" do
        chunks = described_class.call(pages, document_title: doc_title)
        next if chunks.size < 2

        marker_counts = (1..30).map do |i|
          chunks.count { |c| c[:content].include?("Marker#{i}.") }
        end

        expect(marker_counts.max).to be >= 2
      end
    end
  end
end
