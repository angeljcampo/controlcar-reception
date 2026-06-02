# frozen_string_literal: true

# Chunker estructurado para manuales DTC con formato "header + descripción".
#
# Filosofía: 1 chunk = 1 código diagnóstico completo. Mejor para retrieval
# que ventanas de 800 tokens porque cada chunk es una unidad lógica
# (causa + síntoma + diagnóstico), y los keywords como P0301 quedan en
# el breadcrumb (donde el tsvector tiene peso 'A').
#
# Soporta el formato Ford-style:
#
#   P0010 - Intake Camshaft Position Actuator Circuit/Open (Bank 1)
#   Description: The powertrain control module...
#   Possible Causes: ...
#   Diagnostic Aids: ...
#
# NO soporta tablas multi-columna jumbled en plain text (formato PCS).
# Para esos, usar TokenWindowChunker — los DTC codes siguen siendo
# searchables vía keyword match en el tsvector aunque el chunking sea
# por ventanas de tokens.
module Ai
  module Ingestion
    class StructuredDtcChunker
      class DetectionError < StandardError; end

      # Match líneas tipo "P0010 - Title" o "U0001 - Title"
      # Acepta guion ASCII o en-dash (algunos PDFs usan –).
      HEADER_RE = /^\s*([UPBC]\d{4})\s*[-–]\s*(.+?)\s*$/

      # Umbral mínimo de matches para considerar que el formato matcheó.
      MIN_MATCHES = 10

      def self.call(pages, document_title:)
        new(pages, document_title:).call
      end

      def initialize(pages, document_title:)
        @pages          = pages
        @document_title = document_title
      end

      def call
        chunks = extract
        if chunks.size < MIN_MATCHES
          raise DetectionError,
                "Formato DTC no detectado en '#{@document_title}' " \
                "(solo #{chunks.size} matches; mínimo #{MIN_MATCHES}). " \
                "Probá con chunking_strategy: :token_window."
        end
        chunks
      end

      private

      def flat_lines
        @flat_lines ||= @pages.flat_map do |p|
          p[:text].split("\n").map { |line| { line: line, page: p[:page] } }
        end
      end

      def extract
        starts = []
        flat_lines.each_with_index do |entry, i|
          m = entry[:line].match(HEADER_RE)
          next unless m

          starts << {
            idx:   i,
            code:  m[1].strip,
            title: m[2].strip,
            page:  entry[:page]
          }
        end

        starts.each_with_index.map do |s, i|
          next_idx = starts[i + 1]&.[](:idx) || flat_lines.size
          body     = flat_lines[s[:idx]...next_idx].map { |e| e[:line] }

          {
            content:    body.join("\n").strip,
            breadcrumb: "#{@document_title} › #{s[:code]} — #{s[:title]}",
            page:       s[:page],
            metadata:   { dtc_code: s[:code] }
          }
        end
      end
    end
  end
end
