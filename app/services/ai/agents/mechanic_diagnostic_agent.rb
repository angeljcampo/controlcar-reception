module Ai
  module Agents
    # Concrete agent that diagnoses a vehicle work order. It receives a
    # WorkOrder (and its attached photos) via @context, runs the tool loop
    # exposed by BaseAgent, and returns the structured analysis Hash from
    # the final respond_with_analysis call.
    #
    # Multimodal: photos attached to the work order are encoded as base64
    # data URIs and sent as image_url parts on the initial user message.
    # OpenAI vision interprets each image alongside the textual symptoms.
    class MechanicDiagnosticAgent < BaseAgent
      MAX_PHOTO_BYTES = 20.megabytes

      # OpenAI's Vision API rejects anything outside this set with a 400
      # ("You uploaded an unsupported image..."). Everything else (HEIC
      # from iPhones, AVIF from modern web tools, TIFF, BMP, SVG…) gets
      # transcoded to JPEG via Active Storage before we send it.
      OPENAI_SUPPORTED_MIMES = %w[image/png image/jpeg image/gif image/webp].freeze

      protected

      # El prompt vive en `app/prompts/agents/mechanic_diagnostic.md`.
      # Separado del código para que producto/QA puedan iterarlo sin tocar
      # Ruby. Auto-reload en dev, cache warm en prod.
      def system_prompt
        Ai::PromptTemplate.load("agents/mechanic_diagnostic")
      end

      def initial_messages
        work_order = @context.fetch(:work_order)
        [ { role: "user", content: build_user_content(work_order) } ]
      end

      private

      def build_user_content(work_order)
        parts = [ { type: "text", text: build_user_text(work_order) } ]
        parts.concat(image_parts_for(work_order))
        parts
      end

      def build_user_text(work_order)
        vehicle = work_order.vehicle
        vehicle_desc = [ vehicle.make, vehicle.model, vehicle.year ].compact.join(" ").presence || "(sin datos del modelo)"

        text = +<<~TXT
          Análisis solicitado para esta orden de trabajo:

          Patente: #{vehicle.patente}
          Vehículo: #{vehicle_desc}
          Kilometraje: #{work_order.mileage ? "#{work_order.mileage} km" : "no especificado"}
          Prioridad ingresada por el cliente: #{work_order.priority_label} (#{work_order.priority})

          Motivo de ingreso (descripción del cliente):
          #{work_order.reason}
        TXT

        if work_order.photos.attached?
          text << "\nAdjunto #{work_order.photos.count} foto(s) del vehículo para que las analices visualmente.\n"
        end

        text << "\nCuando estés listo, emití el análisis llamando respond_with_analysis."
        text
      end

      def image_parts_for(work_order)
        return [] unless work_order.photos.attached?

        work_order.photos.filter_map { |photo| image_part_for(photo) }
      end

      def image_part_for(photo)
        blob = photo.blob
        return nil unless blob.content_type&.start_with?("image/")
        return nil if blob.byte_size > MAX_PHOTO_BYTES

        bytes, mime = encode_for_openai(photo, blob)
        return nil if bytes.nil?

        encoded = Base64.strict_encode64(bytes)
        {
          type:      "image_url",
          image_url: {
            url:    "data:#{mime};base64,#{encoded}",
            detail: "high"
          }
        }
      rescue => e
        Rails.logger.warn("[MechanicDiagnosticAgent] skipping photo #{photo.id}: #{e.message}")
        nil
      end

      # Returns [bytes, mime_type] OpenAI will accept, or [nil, nil] if the
      # photo can't be made compatible. Supported formats pass through;
      # anything else (heic/avif/tiff/bmp/…) is transcoded to JPEG using
      # Active Storage's variant pipeline (libvips/ImageMagick).
      #
      # If neither libvips nor ImageMagick is installed, the transform
      # raises LoadError (which is a ScriptError, NOT a StandardError, so
      # a bare `rescue` misses it). We catch it explicitly so the agent
      # degrades gracefully to a text-only analysis instead of crashing.
      def encode_for_openai(photo, blob)
        return [ blob.download, blob.content_type ] if OPENAI_SUPPORTED_MIMES.include?(blob.content_type)

        Rails.logger.info("[MechanicDiagnosticAgent] transcoding photo #{photo.id} (#{blob.content_type}) to JPEG")
        variant = photo.variant(format: :jpg, resize_to_limit: [ 2048, 2048 ], saver: { quality: 85 }).processed
        [ variant.download, "image/jpeg" ]
      rescue StandardError, LoadError => e
        Rails.logger.warn("[MechanicDiagnosticAgent] could not transcode photo #{photo.id} (#{blob.content_type}): #{e.message}")
        [ nil, nil ]
      end
    end
  end
end
