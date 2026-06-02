# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkOrder do
  let(:vehicle) { Vehicle.create!(patente: "TEST01") }
  let(:wo) { vehicle.work_orders.create!(customer_name: "Test", reason: "x", mileage: 1000) }

  describe "validations" do
    it "requiere customer_name" do
      wo = vehicle.work_orders.build(customer_name: nil, reason: "x")
      expect(wo).not_to be_valid
    end

    it "requiere reason" do
      wo = vehicle.work_orders.build(customer_name: "x", reason: nil)
      expect(wo).not_to be_valid
    end

    it "permite mileage nil" do
      wo = vehicle.work_orders.build(customer_name: "x", reason: "x", mileage: nil)
      expect(wo).to be_valid
    end

    it "rechaza mileage negativo" do
      wo = vehicle.work_orders.build(customer_name: "x", reason: "x", mileage: -1)
      expect(wo).not_to be_valid
    end

    it "permite priority nil (LLM autoridad — Fase 3)" do
      wo = vehicle.work_orders.build(customer_name: "x", reason: "x", priority: nil)
      expect(wo).to be_valid
    end
  end

  describe "#priority_label" do
    it "devuelve label en español según locale" do
      wo.update!(priority: "high")
      expect(wo.priority_label).to be_present
      # Si no hay traducción, cae a humanize → 'High'
    end

    it "no rompe cuando priority es nil" do
      wo.update!(priority: nil)
      expect { wo.priority_label }.not_to raise_error
    end
  end

  describe "#cancellable?" do
    it "es true cuando status != cancelled" do
      wo.update!(status: "analyzed")
      expect(wo.cancellable?).to be true
    end

    it "es false cuando ya está cancelled" do
      wo.update!(status: "cancelled")
      expect(wo.cancellable?).to be false
    end
  end

  describe "#ai_total_tokens" do
    it "es 0 sin agent_runs" do
      expect(wo.ai_total_tokens).to eq(0)
    end

    it "suma input + output tokens de todos los agent_runs" do
      wo.agent_runs.create!(agent_name: "X", input_tokens: 100, output_tokens: 50)
      wo.agent_runs.create!(agent_name: "X", input_tokens: 200, output_tokens: 75)

      expect(wo.ai_total_tokens).to eq(425)
    end

    it "tolera NULLs en tokens (COALESCE)" do
      wo.agent_runs.create!(agent_name: "X", input_tokens: nil, output_tokens: 50)
      expect(wo.ai_total_tokens).to eq(50)
    end
  end

  describe "#ai_total_cost_cents" do
    it "suma cost_cents de todos los agent_runs" do
      wo.agent_runs.create!(agent_name: "X", cost_cents: 5)
      wo.agent_runs.create!(agent_name: "X", cost_cents: 13)

      expect(wo.ai_total_cost_cents).to eq(18)
    end
  end

  describe "#latest_agent_run" do
    it "devuelve el agent_run más reciente por created_at" do
      old = wo.agent_runs.create!(agent_name: "X", created_at: 1.day.ago)
      recent = wo.agent_runs.create!(agent_name: "X")

      expect(wo.latest_agent_run).to eq(recent)
    end

    it "es nil si no hay agent_runs" do
      expect(wo.latest_agent_run).to be_nil
    end
  end

  describe "asociaciones — retrieval_runs through agent_runs" do
    it "expone retrieval_runs vía has_many through" do
      run = wo.agent_runs.create!(agent_name: "X")
      rr  = run.retrieval_runs.create!(query: "test", top_k: 5)

      expect(wo.retrieval_runs).to include(rr)
    end

    it "borra retrieval_runs en cascada (vía agent_runs dependent: :destroy)" do
      run = wo.agent_runs.create!(agent_name: "X")
      run.retrieval_runs.create!(query: "test", top_k: 5)

      expect { wo.destroy }.to change(RetrievalRun, :count).by(-1)
    end
  end
end
