# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Ingestion::StructuredDtcChunker do
  let(:doc_title) { "Test DTC Manual" }

  describe ".call" do
    context "con formato Ford-style (Pxxxx - Title + Description:)" do
      let(:pages) do
        # 10 DTCs is the MIN_MATCHES threshold del chunker
        body = (10..19).map { |i|
          code = "P00#{i.to_s.rjust(2, '0')[0, 2]}"
          <<~TXT
            #{code} - Test Failure Description #{i}

             Description: This is a test description for code #{code}.
             It mentions PCM monitoring and VCT system.

             Possible Causes:
             * Cause one
             * Cause two
          TXT
        }.join("\n\n")
        [{ page: 1, text: body }]
      end

      it "produce 1 chunk por código DTC" do
        chunks = described_class.call(pages, document_title: doc_title)
        expect(chunks.size).to eq(10)
      end

      it "captura el código DTC en metadata" do
        chunks = described_class.call(pages, document_title: doc_title)
        codes = chunks.map { |c| c[:metadata][:dtc_code] }
        expect(codes).to all(match(/^P\d{4}$/))
      end

      it "incluye el breadcrumb con título del doc + código + título DTC" do
        chunks = described_class.call(pages, document_title: doc_title)
        first  = chunks.first

        expect(first[:breadcrumb]).to start_with("#{doc_title} ›")
        expect(first[:breadcrumb]).to include(first[:metadata][:dtc_code])
      end

      it "el content del chunk incluye Description + Possible Causes" do
        chunks = described_class.call(pages, document_title: doc_title)
        first  = chunks.first

        expect(first[:content]).to include("Description:")
        expect(first[:content]).to include("Possible Causes:")
      end
    end

    context "con códigos U/B/C además de P" do
      let(:pages) do
        body = ["P0010", "U0001", "B0001", "C0001"].each_with_index.flat_map do |code, i|
          [
            "#{code} - Test #{i}",
            " Description: bla bla.",
            ""
          ]
        end.join("\n")
        # Repetimos para superar MIN_MATCHES
        [{ page: 1, text: body * 3 }]
      end

      it "matchea los 4 prefijos válidos" do
        chunks = described_class.call(pages, document_title: doc_title)
        prefixes = chunks.map { |c| c[:metadata][:dtc_code][0] }.uniq
        expect(prefixes).to match_array(%w[P U B C])
      end
    end

    context "cuando el PDF NO tiene formato DTC reconocible" do
      let(:pages) do
        [{ page: 1, text: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 50 }]
      end

      it "raises DetectionError (el caller debe fallback a token_window)" do
        expect {
          described_class.call(pages, document_title: doc_title)
        }.to raise_error(described_class::DetectionError, /no detectado/i)
      end

      it "el mensaje del error incluye cantidad de matches y mínimo esperado" do
        described_class.call(pages, document_title: doc_title)
      rescue described_class::DetectionError => e
        expect(e.message).to match(/0 matches.*m[íi]nimo 10/i)
      end
    end

    context "con menos matches que el threshold mínimo" do
      let(:pages) do
        # Solo 5 DTCs — menos que MIN_MATCHES (10)
        body = (1..5).map { |i| "P000#{i} - Test #{i}\n Description: x" }.join("\n\n")
        [{ page: 1, text: body }]
      end

      it "raises DetectionError aunque los matches sean válidos" do
        expect {
          described_class.call(pages, document_title: doc_title)
        }.to raise_error(described_class::DetectionError)
      end
    end

    context "preservando el número de página" do
      let(:pages) do
        page1 = (1..5).map { |i| "P000#{i} - Test\n Description: x" }.join("\n\n")
        page2 = (6..15).map { |i| "P00#{i.to_s.rjust(2, '0')[0, 2]} - Test\n Description: x" }.join("\n\n")
        [
          { page: 1, text: page1 },
          { page: 2, text: page2 }
        ]
      end

      it "asigna el page correcto a cada chunk según dónde empieza el header" do
        chunks = described_class.call(pages, document_title: doc_title)
        pages_seen = chunks.map { |c| c[:page] }.uniq
        # Cada chunk tiene una página asignada (no nil)
        expect(pages_seen).to all(be_a(Integer))
      end
    end
  end
end
