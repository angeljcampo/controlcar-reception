# frozen_string_literal: true

# Administración de la knowledge base: subir PDFs, ver status del ingest,
# eliminar documentos.
#
# El ingest es ASÍNCRONO (via Sidekiq) acá — distinto de seeds donde es
# síncrono para que `db:seed` deje todo listo. En la UI, Turbo Stream
# actualiza el row del documento cuando el job termina.
class KnowledgeDocumentsController < ApplicationController
  before_action :load_document, only: %i[destroy]

  def index
    @documents     = KnowledgeDocument.order(created_at: :desc)
    @new_document  = KnowledgeDocument.new(chunking_strategy: "structured_dtc")

    # Stats agregadas para el header de la página.
    @total_chunks         = KnowledgeChunk.count
    @total_pages          = KnowledgeDocument.sum(:total_pages)
    @total_embedding_cost = KnowledgeDocument.sum(:embedding_cost_cents)
  end

  def create
    @document = KnowledgeDocument.new(create_params.except(:file))

    unless params.dig(:knowledge_document, :file).present?
      @document.errors.add(:file, "es obligatorio")
      return render_create_error
    end

    @document.status = "pending"
    if @document.save
      @document.file.attach(create_params[:file])
      IngestPdfJob.perform_later(@document.id, translate: translate?)

      respond_to do |format|
        format.turbo_stream do
          # Prepend la row nueva + reset del form.
          render turbo_stream: [
            turbo_stream.prepend(
              "knowledge_documents_list",
              partial: "knowledge_documents/row",
              locals:  { document: @document }
            ),
            turbo_stream.replace(
              "knowledge_documents_form",
              partial: "knowledge_documents/form",
              locals:  { document: KnowledgeDocument.new(chunking_strategy: "structured_dtc") }
            )
          ]
        end
        format.html { redirect_to knowledge_documents_path, notice: "PDF en cola para procesamiento." }
      end
    else
      render_create_error
    end
  end

  def destroy
    @document.destroy
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.remove(ActionView::RecordIdentifier.dom_id(@document))
      end
      format.html { redirect_to knowledge_documents_path, notice: "Documento eliminado." }
    end
  end

  private

  def load_document
    @document = KnowledgeDocument.find(params[:id])
  end

  def create_params
    params.require(:knowledge_document).permit(:title, :chunking_strategy, :file)
  end

  def translate?
    # Checkbox del form. Si no llega, default a true en UI (mismo default
    # que seeds). Permite skipear traducción para iterar rápido.
    value = params.dig(:knowledge_document, :translate)
    value.in?([ "1", "true", true, 1, nil ])
  end

  def render_create_error
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "knowledge_documents_form",
          partial: "knowledge_documents/form",
          locals:  { document: @document }
        ), status: :unprocessable_entity
      end
      format.html { render :index, status: :unprocessable_entity }
    end
  end
end
