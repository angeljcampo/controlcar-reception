# frozen_string_literal: true

# Extracts text from a PDF, one entry per page.
#
# Scope: PDFs born-digital con texto extraíble. NO hace OCR de escaneos
# (documentado como future work en docs/architecture.md).
#
# Usage:
#   Ai::Ingestion::PdfExtractor.call(path_or_io)
#   # => [{ page: 1, text: "..." }, { page: 2, text: "..." }, ...]
#
# Active Storage:
#   doc.file.blob.open do |io|
#     pages = Ai::Ingestion::PdfExtractor.call(io)
#   end
module Ai
  module Ingestion
    class PdfExtractor
      class ExtractionError < StandardError; end

      def self.call(io_or_path)
        new(io_or_path).call
      end

      def initialize(io_or_path)
        @io_or_path = io_or_path
      end

      def call
        reader = PDF::Reader.new(@io_or_path)
        reader.pages.each_with_index.map do |page, i|
          { page: i + 1, text: normalize(page.text.to_s) }
        end
      rescue PDF::Reader::MalformedPDFError,
             PDF::Reader::UnsupportedFeatureError => e
        raise ExtractionError, "PDF extraction failed: #{e.message}"
      end

      private

      # Normaliza whitespace y encoding:
      #   - Fuerza UTF-8 (pdf-reader a veces devuelve ASCII-8BIT/binary)
      #   - Colapsa runs de espacios/tabs (PDF extractors a veces meten
      #     múltiples espacios entre columnas de tabla)
      #   - Preserva saltos de línea (los necesita el Chunker para detectar
      #     headings y filas de tabla DTC)
      #   - Elimina bytes inválidos para que Postgres no se queje
      def normalize(text)
        text
          .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
          .gsub(/[ \t]+/, " ")
          .gsub(/ *\n/, "\n")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end
    end
  end
end
