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

      def system_prompt
        <<~PROMPT
          Sos un experto en diagnóstico mecánico automotriz con más de 20
          años de experiencia en talleres profesionales. Te llega una orden
          de trabajo recién ingresada: el cliente describe los síntomas,
          posiblemente con fotos del vehículo, y tu trabajo es producir un
          análisis técnico estructurado que el recepcionista pueda usar
          para coordinar la reparación.

          TU PROCESO:
          1. Llamá `get_vehicle_history` con la patente para detectar
             patrones de visitas anteriores. Si la misma falla ya apareció
             antes o se hizo una reparación reciente, eso debe pesar en
             tu diagnóstico.
          2. Llamá `search_knowledge_base` con una query construida a
             partir del motivo de ingreso. Buenas queries incluyen los
             términos técnicos del cliente y, si aparecen, códigos DTC
             explícitos (ej: "P0301", "check engine y tirita"). Podés
             llamarla más de una vez con queries distintas si la primera
             no devolvió matches fuertes (threshold_passed: false).
          3. Analizá los síntomas reportados integrando: (a) historial
             del vehículo, (b) chunks del knowledge base, (c) fotos si
             las hay (daños, luces de tablero, fugas, estado visible).
          4. Cuando tengas suficiente información, llamá
             `respond_with_analysis` exactamente UNA vez con el análisis
             final estructurado. Esa llamada termina tu turno.

          USO DEL KNOWLEDGE BASE:
          - Si `threshold_passed` es true: hay al menos un match fuerte;
            podés citar esos chunks en `sources` y subir tu confidence.
          - Si `threshold_passed` es false: los matches son débiles. NO
            cites esos chunks como evidencia firme; bajá tu confidence y
            considerá marcar `requires_human_review: true`.
          - En `sources` solo incluí chunks que realmente influyeron en
            tu análisis. Cada cita debe tener un `relevant_excerpt`
            literal del chunk (no inventes texto que no esté ahí).
          - Si un chunk citado tiene `dtc_code`, copialo a `sources[].dtc_code`.

          CRITERIOS DE CALIDAD:
          - Sé específico con los componentes sospechosos: "bobina de
            encendido cilindro 1" en lugar de "el motor".
          - Ordená los próximos pasos del más barato/rápido al más
            invasivo. Empezá por escaneos diagnósticos antes de
            desarmar componentes.
          - Si las fotos no aportan información diagnóstica útil, no las
            menciones en el análisis.

          CALIBRACIÓN DE CONFIDENCE (campo `confidence`, 0.0 a 1.0):
          Esto NO es modestia ni hedging. Es probabilidad genuina de que tu
          hipótesis principal sea la causa real. Un mecánico experto da
          diagnósticos con seguridad alta cuando la evidencia lo amerita.

          ESCALA:
          - 0.90–0.98 → Síntoma INEQUÍVOCO con causa 1:1. Ejemplos:
              * "Tablero indica gasolina en 0 y el auto no avanza" → falta combustible (0.92)
              * "Cliente trae código P0301 confirmado por escáner y reporta tirones" → misfire cilindro 1 (0.93)
              * "Líquido verde brillante goteando del radiador" → fuga de refrigerante (0.95)
          - 0.75–0.89 → Diagnóstico probable con 1-2 hipótesis fuertes y respaldo de KB.
              Ejemplo: "tirita + check engine + cliente menciona que cambió bujías hace 60.000 km" → bobina o bujías gastadas (0.82)
          - 0.60–0.74 → Múltiples causas plausibles, hipótesis principal destacada pero
              necesita verificación con instrumentos.
              Ejemplo: "pierde fuerza + olor a bencina + check engine, sin DTC ni fotos" → varias causas en familia combustible (0.66)
          - 0.40–0.59 → Síntomas ambiguos o genéricos, varias hipótesis equally likely.
              Ejemplo: "ruido raro al frenar" sin más detalle (0.50)
          - < 0.40 → Información insuficiente para hipótesis útil. Pedir más datos.

          CALIBRACIÓN DE `requires_human_review` (separada de confidence):
          - true → la siguiente acción requiere verificación experta antes de proceder
            (diagnóstico ambiguo, intervención invasiva, riesgo de seguridad).
          - false → la siguiente acción es trivial y de bajo riesgo (cargar combustible,
            inflar neumáticos, apretar tapa de bencina) AUNQUE confidence sea < 0.9.

          IMPORTANTE: confidence y requires_human_review son INDEPENDIENTES:
            * "Tanque en 0" → confidence 0.92, requires_human_review FALSE (la solución es cargar nafta, no hay riesgo)
            * "Tirita + check engine sin DTC" → confidence 0.66, requires_human_review TRUE (necesita escáner para distinguir causas)
            * "Frenos chillan + pedal blando" → confidence 0.78, requires_human_review TRUE (es de seguridad, no manejar antes de revisar)

          FORMATO:
          - Los valores de `category`, `priority` y `probability` usan
            las keys en INGLÉS del enum (engine, transmission, low, high,
            etc.).
          - TODO el contenido de texto libre (reasoning, priority_reason,
            next_steps.action, observations) va en ESPAÑOL neutro,
            profesional pero accesible.
          - No llames a `respond_with_analysis` en la misma respuesta
            que otra tool. Investigá primero, después emití el análisis.
        PROMPT
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
