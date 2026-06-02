# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Ingestion::PdfExtractor do
  # Usamos uno de los PDFs reales de seed_pdfs/ que ya están versionados
  # en el repo — más fiel que armar un PDF sintético, y rápido (3 págs).
  let(:pcs_path) { Rails.root.join("db/seed_pdfs/PCS_Diagnostic_Codes.pdf").to_s }

  describe ".call" do
    it "devuelve un array de {page, text} por cada página del PDF" do
      pages = described_class.call(pcs_path)

      expect(pages).to be_an(Array)
      expect(pages.size).to eq(3) # PCS son 3 págs
      expect(pages.first.keys).to match_array([:page, :text])
    end

    it "asigna page number 1-indexed (no 0-indexed)" do
      pages = described_class.call(pcs_path)
      expect(pages.first[:page]).to eq(1)
      expect(pages.last[:page]).to eq(3)
    end

    it "fuerza encoding UTF-8 (pdf-reader a veces devuelve ASCII-8BIT)" do
      pages = described_class.call(pcs_path)
      pages.each do |p|
        expect(p[:text].encoding).to eq(Encoding::UTF_8)
      end
    end

    it "colapsa whitespace múltiple sin perder saltos de línea estructurales" do
      pages = described_class.call(pcs_path)
      text = pages.first[:text]
      # No deben quedar runs de 3+ saltos de línea (normalize los colapsa a 2)
      expect(text).not_to match(/\n{3,}/)
    end

    it "preserva los códigos DTC tal cual" do
      pages = described_class.call(pcs_path)
      full_text = pages.map { |p| p[:text] }.join
      # PCS tiene varios códigos OBDII referenciados
      expect(full_text).to match(/P\d{4}/)
    end

    context "con un path que no existe" do
      it "raises (no silencia el error de filesystem)" do
        # pdf-reader 2.x lo envuelve en ArgumentError; pdf-reader < 2 era
        # Errno::ENOENT. Toleramos ambos — lo importante es que algo raisee.
        expect {
          described_class.call("/tmp/no_existe_definitivamente_#{Time.now.to_i}.pdf")
        }.to raise_error(StandardError)
      end
    end
  end
end
