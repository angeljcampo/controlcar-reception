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
          2. Analizá los síntomas reportados y, si hay fotos, integrá lo
             que ves visualmente (daños, luces de tablero encendidas,
             fugas, estado de componentes).
          3. Cuando hayas reunido suficiente información, llamá
             `respond_with_analysis` exactamente UNA vez con el análisis
             final estructurado. Esa llamada termina tu turno.

          CRITERIOS DE CALIDAD:
          - Sé específico con los componentes sospechosos: "bobina de
            encendido cilindro 1" en lugar de "el motor".
          - Ordená los próximos pasos del más barato/rápido al más
            invasivo. Empezá por escaneos diagnósticos antes de
            desarmar componentes.
          - Si los síntomas son ambiguos o tu confianza es baja (< 0.7),
            poné `requires_human_review: true`. Es mejor escalar al
            mecánico que adivinar mal.
          - Si las fotos no aportan información diagnóstica útil, no las
            menciones en el análisis.

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
        [{ role: "user", content: build_user_content(work_order) }]
      end

      private

      def build_user_content(work_order)
        parts = [{ type: "text", text: build_user_text(work_order) }]
        parts.concat(image_parts_for(work_order))
        parts
      end

      def build_user_text(work_order)
        vehicle = work_order.vehicle
        vehicle_desc = [vehicle.make, vehicle.model, vehicle.year].compact.join(" ").presence || "(sin datos del modelo)"

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

        encoded = Base64.strict_encode64(blob.download)
        {
          type:      "image_url",
          image_url: {
            url:    "data:#{blob.content_type};base64,#{encoded}",
            detail: "high"
          }
        }
      rescue => e
        Rails.logger.warn("[MechanicDiagnosticAgent] skipping photo #{photo.id}: #{e.message}")
        nil
      end
    end
  end
end
