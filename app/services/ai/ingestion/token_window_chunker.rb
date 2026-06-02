# frozen_string_literal: true

# Chunker para prose narrativa (manuales, casos, descripciones).
#
# Estrategia: ventanas de ~800 tokens con overlap de ~150.
# Como NO usamos tiktoken (sería otra dependencia), aproximamos por chars:
# español promedio ~4 chars/token → 800 tokens ≈ 3200 chars.
#
# Respeta párrafos: nunca parte un párrafo al medio. Si un párrafo solo
# supera el target, se mete entero en un chunk.
#
# Each chunk has:
#   - content: párrafos unidos
#   - breadcrumb: "{title} › Página {N}" (página donde empieza el chunk)
#   - page: int (página de inicio)
#   - metadata: { strategy: "token_window" }
module Ai
  module Ingestion
    class TokenWindowChunker
      # ~4 chars/token en español promedio.
      TARGET_CHARS  = 3_200   # ≈ 800 tokens
      OVERLAP_CHARS = 600     # ≈ 150 tokens

      def self.call(pages, document_title:)
        new(pages, document_title:).call
      end

      def initialize(pages, document_title:)
        @pages          = pages
        @document_title = document_title
      end

      def call
        paragraphs = build_paragraphs
        return [] if paragraphs.empty?

        build_chunks(paragraphs)
      end

      private

      # [{text:, page:}] — un entry por párrafo, sabiendo de qué página vino.
      def build_paragraphs
        @pages.flat_map do |page|
          page[:text].split(/\n{2,}/).filter_map do |para|
            stripped = para.strip
            next if stripped.empty?

            { text: stripped, page: page[:page] }
          end
        end
      end

      def build_chunks(paragraphs)
        chunks  = []
        buffer  = []
        size    = 0
        start_p = paragraphs.first[:page]

        paragraphs.each do |para|
          # Si agregar este párrafo excede el target Y ya tenemos contenido,
          # cerrar chunk y arrancar uno nuevo con overlap.
          if !buffer.empty? && size + para[:text].size > TARGET_CHARS
            chunks << finalize(buffer, start_p)

            # Overlap: agarra últimos párrafos del buffer mientras quepan
            overlap = []
            overlap_size = 0
            buffer.reverse_each do |p|
              break if overlap_size + p[:text].size > OVERLAP_CHARS

              overlap.unshift(p)
              overlap_size += p[:text].size
            end

            buffer  = overlap
            size    = overlap_size
            start_p = buffer.first&.dig(:page) || para[:page]
          end

          buffer << para
          size   += para[:text].size
        end

        chunks << finalize(buffer, start_p) unless buffer.empty?
        chunks
      end

      def finalize(paragraphs, start_page)
        content = paragraphs.map { |p| p[:text] }.join("\n\n")
        {
          content:    content,
          breadcrumb: "#{@document_title} › Página #{start_page}",
          page:       start_page,
          metadata:   { strategy: "token_window" }
        }
      end
    end
  end
end
