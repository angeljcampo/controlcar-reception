# frozen_string_literal: true

# Traduce chunks técnicos de inglés a español usando gpt-4o-mini.
#
# Por qué traducir al ingestar (no al runtime):
#   - El motivo de ingreso llega en chileno coloquial ("tirita", "patina")
#   - Cross-lingual embeddings de OpenAI son OK pero "shuddering" vs "tirita"
#     no es match perfecto. Traducir al ingestar mejora recall semántico.
#   - El output del agente cita el chunk → si el chunk está en español la
#     cita es legible para el recepcionista.
#   - Cost: ~$0.04 para los ~330 chunks de DTC_Codes (una sola vez al seed).
#
# Preserva literal:
#   - Códigos DTC: P0010, U0001, B0001, C0001
#   - Códigos J1939: 522731, etc.
#   - Siglas técnicas: PCM, TCM, VCT, OBDII, DTC, PCS, RPM, TPS, MPH
#   - Unidades y rangos: 4.9V, 25%, 200 RPM, 132°C
#
# Guarda original en metadata.original_content_en para auditoría.
module Ai
  module Ingestion
    class SpanishTranslator
      MODEL              = "gpt-4o-mini"
      BATCH_SIZE         = 10
      TIMEOUT_S          = 120
      MAX_BATCH_RETRIES  = 3
      BACKOFF_S          = 5

      class MissingApiKey < StandardError; end
      class TranslationError < StandardError; end

      SYSTEM_PROMPT = <<~PROMPT.freeze
        Eres un traductor técnico automotriz. Te paso un array JSON de chunks técnicos en inglés. Para cada uno, devuelve la traducción al español neutro técnico (apto para Chile/Latam).

        REGLAS ABSOLUTAS (NO romper bajo ningún concepto):
        1. Preserva LITERAL los códigos diagnósticos: P0010, P0301, U0001, B0001, C0001, etc.
        2. Preserva LITERAL códigos J1939 (números de 6 dígitos como 522731).
        3. Preserva LITERAL siglas técnicas: PCM, TCM, VCT, ECM, OBDII, OBD-II, DTC, PCS, RPM, TPS, MPH, MAF, IAT, HO2S, VPWR, KOEO, KOER, TCC, SSA, SSB.
        4. Mantén números, unidades y rangos exactos: 4.9 Volts → 4.9 Volts; 200 RPM → 200 RPM; 132°C → 132°C.
        5. Traduce SOLO la prosa explicativa. No expliques, no agregues, no comentes.
        6. Conserva la estructura: si hay "Description:", "Possible Causes:", etc., tradúcelos a "Descripción:", "Posibles causas:", etc.
        7. Traduce también el breadcrumb.

        OUTPUT: JSON con la misma cantidad de entries que el input, mismo orden, esquema:
        {
          "translations": [
            { "index": 0, "content": "...", "breadcrumb": "..." },
            { "index": 1, "content": "...", "breadcrumb": "..." }
          ]
        }
      PROMPT

      def self.call(chunks)
        new(chunks).call
      end

      def initialize(chunks)
        @chunks = chunks
      end

      def call
        return [] if @chunks.empty?

        raise MissingApiKey if ENV["OPENAI_API_KEY"].blank?

        client = OpenAI::Client.new(
          access_token: ENV.fetch("OPENAI_API_KEY"),
          request_timeout: TIMEOUT_S
        )

        @chunks.each_slice(BATCH_SIZE).flat_map.with_index do |batch, batch_idx|
          Rails.logger.info("[SpanishTranslator] batch #{batch_idx + 1} (#{batch.size} chunks)")
          translate_batch_with_retries(client, batch, batch_idx)
        end
      end

      private

      # Retry interno por batch — un timeout transitorio NO debe matar
      # las traducciones ya pagadas anteriormente. Exponential backoff.
      def translate_batch_with_retries(client, batch, batch_idx)
        attempts = 0
        begin
          attempts += 1
          translate_batch(client, batch)
        rescue Faraday::TimeoutError, Net::ReadTimeout, Faraday::ConnectionFailed => e
          if attempts < MAX_BATCH_RETRIES
            wait = BACKOFF_S * attempts
            Rails.logger.warn(
              "[SpanishTranslator] batch #{batch_idx + 1} timeout (intento #{attempts}/#{MAX_BATCH_RETRIES}): " \
              "#{e.class}: #{e.message}. Reintentando en #{wait}s..."
            )
            sleep wait
            retry
          else
            raise TranslationError,
                  "Batch #{batch_idx + 1} falló tras #{MAX_BATCH_RETRIES} intentos: #{e.class}: #{e.message}"
          end
        end
      end

      def translate_batch(client, batch)
        user_payload = batch.each_with_index.map do |c, i|
          { index: i, content: c[:content], breadcrumb: c[:breadcrumb] }
        end

        response = client.chat(
          parameters: {
            model:           MODEL,
            messages:        [
              { role: "system", content: SYSTEM_PROMPT },
              { role: "user",   content: JSON.generate(chunks: user_payload) }
            ],
            response_format: { type: "json_object" },
            temperature:     0
          }
        )

        raw          = response.dig("choices", 0, "message", "content")
        translations = JSON.parse(raw).fetch("translations")

        if translations.size != batch.size
          raise TranslationError,
                "Translator devolvió #{translations.size} traducciones para #{batch.size} chunks"
        end

        merge_back(batch, translations)
      rescue JSON::ParserError => e
        raise TranslationError, "JSON inválido en respuesta: #{e.message}"
      end

      # Une las traducciones a los chunks originales preservando metadata
      # y guardando el original para auditoría.
      def merge_back(batch, translations)
        # Asume orden preservado (el system prompt lo pide y temperature: 0
        # ayuda a respetarlo). Re-ordena por :index por las dudas.
        ordered = translations.sort_by { |t| t["index"] }

        batch.zip(ordered).map do |original, translated|
          original.merge(
            content:    translated.fetch("content"),
            breadcrumb: translated.fetch("breadcrumb"),
            metadata:   original[:metadata].merge(
              original_content_en:    original[:content],
              original_breadcrumb_en: original[:breadcrumb]
            )
          )
        end
      end
    end
  end
end
