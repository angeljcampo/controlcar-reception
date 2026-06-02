# frozen_string_literal: true

require "rails_helper"

# Tests focused en la math del Reciprocal Rank Fusion + threshold logic.
# El vector_search lo stubeamos a nivel de método porque pgvector + dataset
# pequeño no aporta señal interesante — lo que importa es la fusión.
RSpec.describe Ai::Tools::SearchKnowledgeBase do
  subject(:tool) { described_class.new(context: {}) }

  describe "RRF score math (#reciprocal_rank_fusion)" do
    # Doubles que simulan chunks de la BD sin tocar AR. Usamos ids únicos
    # para que la fusión los identifique correctamente.
    let(:chunk_a) { double("chunk", id: 1, breadcrumb: "Doc A", content: "...", page_number: 1, knowledge_document: double(title: "Doc A"), metadata: {}) }
    let(:chunk_b) { double("chunk", id: 2, breadcrumb: "Doc B", content: "...", page_number: 1, knowledge_document: double(title: "Doc B"), metadata: {}) }
    let(:chunk_c) { double("chunk", id: 3, breadcrumb: "Doc C", content: "...", page_number: 1, knowledge_document: double(title: "Doc C"), metadata: {}) }

    it "el chunk #1 en ambos rankings recibe el score más alto" do
      vec = [
        { chunk: chunk_a, vector_rank: 0, vector_distance: 0.3 },
        { chunk: chunk_b, vector_rank: 1, vector_distance: 0.4 }
      ]
      kw = [
        { chunk: chunk_a, keyword_rank: 0 },
        { chunk: chunk_c, keyword_rank: 1 }
      ]

      fused = tool.send(:reciprocal_rank_fusion, vec, kw, top_k: 3)

      # chunk_a aparece en ambos → score = 1/61 + 1/61 ≈ 0.0328
      # chunk_b aparece solo vector → score = 1/62 ≈ 0.0161
      # chunk_c aparece solo keyword → score = 1/62 ≈ 0.0161
      first = fused.first
      expect(first[:chunk].id).to eq(1)
      expect(first[:fused_score]).to be > 0.03
    end

    it "ordena descendente por fused_score" do
      vec = (1..5).map.with_index { |i, idx| { chunk: double(id: i, breadcrumb: "B#{i}", content: "x", page_number: 1, knowledge_document: double(title: "D"), metadata: {}), vector_rank: idx, vector_distance: 0.5 } }
      kw  = []

      fused = tool.send(:reciprocal_rank_fusion, vec, kw, top_k: 5)
      scores = fused.map { |f| f[:fused_score] }

      expect(scores).to eq(scores.sort.reverse)
    end

    it "respeta top_k aunque haya más candidatos" do
      vec = (1..10).map.with_index { |i, idx| { chunk: double(id: i, breadcrumb: "B#{i}", content: "x", page_number: 1, knowledge_document: double(title: "D"), metadata: {}), vector_rank: idx, vector_distance: 0.5 } }
      kw  = []

      fused = tool.send(:reciprocal_rank_fusion, vec, kw, top_k: 3)
      expect(fused.size).to eq(3)
    end

    it "preserva vector_distance y vector_rank en el resultado fusionado" do
      vec = [ { chunk: chunk_a, vector_rank: 2, vector_distance: 0.42 } ]
      kw  = []

      fused = tool.send(:reciprocal_rank_fusion, vec, kw, top_k: 1)
      expect(fused.first[:vector_distance]).to eq(0.42)
      expect(fused.first[:vector_rank]).to eq(2)
    end
  end

  describe "threshold logic (#call)" do
    let(:query) { "test query" }

    before do
      # Stub el embedder para no llamar OpenAI
      allow(Ai::Ingestion::BatchEmbedder).to receive(:call)
        .and_return({ embeddings: [ Array.new(1536, 0.0) ], total_tokens: 5 })

      # Stub el keyword search a vacío para enfocarnos en vector + threshold
      allow(tool).to receive(:keyword_search).and_return([])
    end

    context "cuando hay al menos 1 match con vector_distance < STRONG_MATCH_THRESHOLD" do
      it "threshold_passed es true" do
        chunk = double("chunk", id: 1, breadcrumb: "x", content: "x", page_number: 1, knowledge_document: double(title: "D"), metadata: {}, neighbor_distance: 0.4)
        # 0.4 < 0.65 → strong
        allow(tool).to receive(:vector_search_with_metrics)
          .and_return([ [ { chunk: chunk, vector_rank: 0, vector_distance: 0.4 } ], 5 ])

        result = tool.call(query: query, top_k: 5)

        expect(result[:threshold_passed]).to be true
        expect(result[:strong_matches_count]).to eq(1)
      end
    end

    context "cuando todos los matches tienen vector_distance >= threshold" do
      it "threshold_passed es false (LLM debe bajar confidence)" do
        chunk = double("chunk", id: 1, breadcrumb: "x", content: "x", page_number: 1, knowledge_document: double(title: "D"), metadata: {}, neighbor_distance: 0.7)
        # 0.7 >= 0.65 → weak
        allow(tool).to receive(:vector_search_with_metrics)
          .and_return([ [ { chunk: chunk, vector_rank: 0, vector_distance: 0.7 } ], 5 ])

        result = tool.call(query: query, top_k: 5)

        expect(result[:threshold_passed]).to be false
        expect(result[:strong_matches_count]).to eq(0)
      end
    end

    context "con query vacía" do
      it "devuelve empty_result sin llamar a embedder ni AR" do
        expect(Ai::Ingestion::BatchEmbedder).not_to receive(:call)

        result = tool.call(query: "", top_k: 5)

        expect(result[:matches]).to eq([])
        expect(result[:threshold_passed]).to be false
      end
    end
  end

  describe "schema del input_schema (strict mode de OpenAI)" do
    it "incluye TODAS las properties en required (OpenAI strict: true exige eso)" do
      schema = described_class.input_schema

      property_keys = schema[:properties].keys
      expect(schema[:required].map(&:to_sym)).to match_array(property_keys)
    end
  end
end
