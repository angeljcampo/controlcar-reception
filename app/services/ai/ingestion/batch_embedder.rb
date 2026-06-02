# frozen_string_literal: true

# Embebe un array de strings usando OpenAI text-embedding-3-small.
#
# Modelo: text-embedding-3-small
#   - 1536 dims (matches KnowledgeChunk.embedding column)
#   - $0.02 / 1M tokens — el más barato de OpenAI
#   - Soporta español/inglés multilingüe out-of-the-box
#
# Batch: hasta 2048 strings por call (OpenAI permite eso); usamos 100 para
# mantener payloads chicos y latencia previsible. Costo igual al final.
#
# Output:
#   {
#     embeddings:       [[1536 floats], [1536 floats], ...],   # mismo orden que input
#     total_tokens:     <int>,
#     total_cost_cents: <int>
#   }
module Ai
  module Ingestion
    class BatchEmbedder
      MODEL                = "text-embedding-3-small".freeze
      DIMENSIONS           = 1536
      BATCH_SIZE           = 100
      COST_PER_M_TOKENS_USD = 0.02   # $0.02 / 1M tokens (input only; embeddings no tienen output)
      TIMEOUT_S            = 60

      class MissingApiKey < StandardError; end
      class EmbeddingError < StandardError; end

      def self.call(texts)
        new(texts).call
      end

      def initialize(texts)
        @texts = texts
      end

      def call
        return empty_result if @texts.empty?

        raise MissingApiKey if ENV["OPENAI_API_KEY"].blank?

        client = OpenAI::Client.new(
          access_token:    ENV.fetch("OPENAI_API_KEY"),
          request_timeout: TIMEOUT_S
        )

        all_embeddings = []
        total_tokens   = 0

        @texts.each_slice(BATCH_SIZE).with_index do |batch, batch_idx|
          Rails.logger.info("[BatchEmbedder] batch #{batch_idx + 1} (#{batch.size} texts)")
          embeddings, tokens = embed_batch(client, batch)
          all_embeddings.concat(embeddings)
          total_tokens += tokens
        end

        {
          embeddings:       all_embeddings,
          total_tokens:     total_tokens,
          total_cost_cents: cost_cents(total_tokens)
        }
      end

      private

      def embed_batch(client, batch)
        response = client.embeddings(
          parameters: {
            model: MODEL,
            input: batch
          }
        )

        if response["error"]
          raise EmbeddingError, response.dig("error", "message") || "OpenAI error"
        end

        # OpenAI devuelve data ordenada por :index del input.
        # Lo re-ordenamos por las dudas y extraemos los embeddings.
        sorted     = response.fetch("data").sort_by { |d| d.fetch("index") }
        embeddings = sorted.map { |d| d.fetch("embedding") }
        tokens     = response.dig("usage", "total_tokens").to_i

        if embeddings.size != batch.size
          raise EmbeddingError,
                "Embeddings devueltos (#{embeddings.size}) ≠ inputs (#{batch.size})"
        end

        [embeddings, tokens]
      end

      def cost_cents(tokens)
        # tokens × ($0.02 / 1M) × 100¢/USD
        ((tokens / 1_000_000.0) * COST_PER_M_TOKENS_USD * 100).ceil
      end

      def empty_result
        { embeddings: [], total_tokens: 0, total_cost_cents: 0 }
      end
    end
  end
end
