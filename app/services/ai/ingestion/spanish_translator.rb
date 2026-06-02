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

      # Prompt en `app/prompts/ingestion/spanish_translator.md`. Lo cargamos
      # vía PromptTemplate para que ediciones del prompt no requieran tocar
      # Ruby ni reload del servidor.
      def self.system_prompt
        Ai::PromptTemplate.load("ingestion/spanish_translator")
      end

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
              { role: "system", content: self.class.system_prompt },
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
