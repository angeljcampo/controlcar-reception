# frozen_string_literal: true

require "rails_helper"

RSpec.describe RetrievalRun do
  let(:wo) {
    v = Vehicle.create!(patente: "X")
    v.work_orders.create!(customer_name: "x", reason: "x", mileage: 0)
  }
  let(:agent_run) { wo.agent_runs.create!(agent_name: "MechanicDiagnosticAgent") }

  describe "validations" do
    it "requiere query y top_k" do
      rr = RetrievalRun.new(agent_run: agent_run)
      expect(rr).not_to be_valid
      expect(rr.errors[:query]).to be_present
      expect(rr.errors[:top_k]).to be_present
    end

    it "requiere agent_run" do
      rr = RetrievalRun.new(query: "x", top_k: 5)
      expect(rr).not_to be_valid
    end
  end

  describe "asociaciones" do
    it "expone work_order vía has_one through agent_run" do
      rr = agent_run.retrieval_runs.create!(query: "x", top_k: 5)
      expect(rr.work_order).to eq(wo)
    end
  end

  describe "#matches" do
    it "devuelve results ordenados por fused_rank ascendente" do
      rr = agent_run.retrieval_runs.create!(query: "x", top_k: 3, results: [
        { "chunk_id" => 1, "fused_rank" => 2, "fused_score" => 0.01 },
        { "chunk_id" => 2, "fused_rank" => 0, "fused_score" => 0.03 },
        { "chunk_id" => 3, "fused_rank" => 1, "fused_score" => 0.02 }
      ])

      ranks = rr.matches.map { |r| r["fused_rank"] }
      expect(ranks).to eq([ 0, 1, 2 ])
    end

    it "tolera results vacío" do
      rr = agent_run.retrieval_runs.create!(query: "x", top_k: 3, results: [])
      expect(rr.matches).to eq([])
    end
  end

  describe "defaults" do
    it "tiene defaults sensatos para conteo y flag" do
      rr = agent_run.retrieval_runs.create!(query: "x", top_k: 5)
      expect(rr.total_matches).to eq(0)
      expect(rr.strong_matches_count).to eq(0)
      expect(rr.threshold_passed).to be false
      expect(rr.latency_ms).to eq(0)
    end
  end
end
