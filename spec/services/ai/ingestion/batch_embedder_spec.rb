# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Ingestion::BatchEmbedder do
  before { ENV["OPENAI_API_KEY"] = "sk-test-fake-key" }

  describe ".call" do
    let(:texts) { [ "primer texto", "segundo texto", "tercer texto" ] }

    def stub_openai_embeddings(embeddings:, tokens: 30)
      stub_request(:post, "https://api.openai.com/v1/embeddings")
        .to_return(
          status: 200,
          body: {
            data: embeddings.each_with_index.map { |emb, i| { index: i, embedding: emb, object: "embedding" } },
            usage: { total_tokens: tokens },
            model: "text-embedding-3-small",
            object: "list"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    context "respuesta normal de OpenAI" do
      before do
        stub_openai_embeddings(
          embeddings: 3.times.map { Array.new(1536, 0.1) },
          tokens: 24
        )
      end

      it "devuelve un embedding por cada input, mismo orden" do
        result = described_class.call(texts)

        expect(result[:embeddings].size).to eq(3)
        expect(result[:embeddings].first.size).to eq(1536) # text-embedding-3-small dims
      end

      it "captura tokens reportados por OpenAI" do
        result = described_class.call(texts)
        expect(result[:total_tokens]).to eq(24)
      end

      it "calcula el costo en cents (rounded up, $0.02/1M tokens)" do
        result = described_class.call(texts)
        # 24 tokens × 0.02 / 1M × 100 = 0.000048 cents → ceil = 1
        expect(result[:total_cost_cents]).to eq(1)
      end
    end

    context "input vacío" do
      it "no llama OpenAI y devuelve zeros" do
        # WebMock raise si hubiese request
        result = described_class.call([])
        expect(result).to eq(embeddings: [], total_tokens: 0, total_cost_cents: 0)
      end
    end

    context "OpenAI devuelve diferente cantidad de embeddings que inputs" do
      before do
        # 3 inputs pero solo 2 embeddings de vuelta — invariante violada
        stub_openai_embeddings(embeddings: 2.times.map { Array.new(1536, 0.1) })
      end

      it "raises EmbeddingError con diagnóstico claro" do
        expect {
          described_class.call(texts)
        }.to raise_error(described_class::EmbeddingError, /2.*3/)
      end
    end

    context "OpenAI devuelve error en respuesta" do
      before do
        stub_request(:post, "https://api.openai.com/v1/embeddings")
          .to_return(
            status: 200,
            body: { error: { message: "Rate limit exceeded" } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises EmbeddingError con el mensaje de OpenAI" do
        expect {
          described_class.call(texts)
        }.to raise_error(described_class::EmbeddingError, /Rate limit/)
      end
    end

    context "sin OPENAI_API_KEY" do
      before { ENV["OPENAI_API_KEY"] = nil }

      it "raises MissingApiKey" do
        expect { described_class.call(texts) }.to raise_error(described_class::MissingApiKey)
      end
    end

    context "re-ordering: OpenAI puede devolver data en orden distinto" do
      before do
        # Devuelve los 3 pero con index reverso — el código debe re-ordenar
        stub_request(:post, "https://api.openai.com/v1/embeddings")
          .to_return(
            status: 200,
            body: {
              data: [
                { index: 2, embedding: Array.new(1536, 0.3), object: "embedding" },
                { index: 0, embedding: Array.new(1536, 0.1), object: "embedding" },
                { index: 1, embedding: Array.new(1536, 0.2), object: "embedding" }
              ],
              usage: { total_tokens: 30 }
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "re-ordena por :index para preservar correspondencia con inputs" do
        result = described_class.call(texts)

        expect(result[:embeddings][0].first).to eq(0.1) # texts[0] -> index 0
        expect(result[:embeddings][1].first).to eq(0.2)
        expect(result[:embeddings][2].first).to eq(0.3)
      end
    end
  end
end
