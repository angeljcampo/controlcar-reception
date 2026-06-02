# frozen_string_literal: true

# Carga los PDFs precargados (db/seed_pdfs/) en la knowledge base.
#
# Usado por dos caminos distintos:
#   1. db/seeds.rb (dev local, síncrono): `bin/rails db:seed`
#   2. KnowledgeDocumentsController#bootstrap (producción sin shell):
#      el user clickea un botón en /knowledge cuando la KB está vacía
#      → encolamos los IngestPdfJob como `perform_later` para que el
#      request HTTP responda al instante.
#
# Idempotente:
#   - Si un doc ya está :ready, lo skipea.
#   - Si está :failed o :pending, lo recrea (recreamos chunks vía
#     IngestPdfJob#persist_chunks que hace delete_all primero).
#
# Catálogo de PDFs en CATALOG. Para agregar uno nuevo:
#   1. Drop el .pdf en db/seed_pdfs/
#   2. Sumar entrada acá con title + chunking_strategy + needs_translation
#   3. Commit + deploy → el botón en /knowledge va a procesarlo
class KnowledgeBaseBootstrap
  CATALOG = [
    {
      filename:          "DTC_Codes.pdf",
      title:             "Códigos DTC OBD-II (Ford 2007 PCED)",
      chunking_strategy: :structured_dtc,
      needs_translation: true  # inglés
    },
    {
      filename:          "PCS_Diagnostic_Codes.pdf",
      title:             "PCS Diagnostic Codes (Transmisión)",
      chunking_strategy: :token_window,
      needs_translation: true  # inglés
    },
    {
      filename:          "Denton_Diagnostico_Automotriz.pdf",
      title:             "Diagnóstico Avanzado de Fallas Automotrices (Tom Denton, 3ra ed)",
      chunking_strategy: :token_window,
      needs_translation: false # ya en español
    }
  ].freeze

  Result = Struct.new(:queued, :skipped, :missing, keyword_init: true)

  def self.call(...)
    new(...).call
  end

  # @param translate [Boolean] global switch — si false, ningún doc se
  #   traduce (más rápido). Si true, los docs con needs_translation: true
  #   se traducen al español al ingestar.
  # @param mode [Symbol] :async (default) → IngestPdfJob.perform_later
  #                     :sync           → IngestPdfJob.perform_now (bloquea)
  def initialize(translate: true, mode: :async)
    @translate = translate
    @mode      = mode
  end

  def call
    queued, skipped, missing = [], [], []

    CATALOG.each do |entry|
      path = seed_dir.join(entry[:filename])
      unless path.exist?
        missing << entry[:filename]
        next
      end

      doc = KnowledgeDocument.find_or_initialize_by(title: entry[:title])

      if doc.persisted? && doc.ready?
        skipped << entry[:title]
        next
      end

      doc.chunking_strategy = entry[:chunking_strategy]
      doc.status            = "pending"
      doc.error_message     = nil
      doc.save!

      unless doc.file.attached?
        doc.file.attach(
          io:           File.open(path),
          filename:     entry[:filename],
          content_type: "application/pdf"
        )
      end

      effective_translate = @translate && entry[:needs_translation]
      enqueue(doc, translate: effective_translate)
      queued << entry[:title]
    end

    Result.new(queued: queued, skipped: skipped, missing: missing)
  end

  private

  def enqueue(doc, translate:)
    case @mode
    when :async
      IngestPdfJob.perform_later(doc.id, translate: translate)
    when :sync
      IngestPdfJob.perform_now(doc.id, translate: translate)
    else
      raise ArgumentError, "mode debe ser :async o :sync (recibí #{@mode.inspect})"
    end
  end

  def seed_dir
    Rails.root.join("db/seed_pdfs")
  end
end
