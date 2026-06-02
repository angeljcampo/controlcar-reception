# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyzeWorkOrderJob do
  let(:vehicle) { Vehicle.create!(patente: "TEST01") }
  let(:wo) {
    vehicle.work_orders.create!(
      customer_name: "Cliente",
      mileage:       50_000,
      reason:        "Tirita en ralentí",
      status:        "draft"
    )
  }

  # Agent fake — devuelve un Hash que matchea respond_with_analysis schema
  let(:analysis_args) {
    {
      category:              "engine",
      possible_failures:     [{ "component" => "bobina", "probability" => "high", "reasoning" => "x" }],
      priority:              "high",
      priority_reason:       "Riesgo de daño",
      next_steps:            [],
      sources:               [],
      confidence:            0.8,
      requires_human_review: false,
      observations:          nil
    }
  }

  let(:fake_agent) { double("agent", run: analysis_args) }

  before do
    allow(Ai::Agents::MechanicDiagnosticAgent).to receive(:new).and_return(fake_agent)
    # OpenAIProvider init no debe explotar si la apikey está, stub el constructor
    allow(Ai::Providers::OpenAIProvider).to receive(:new).and_return(double("provider"))
    ENV["OPENAI_API_KEY"] = "sk-test"
  end

  describe "happy path" do
    it "flippea WO a :analyzing al iniciar, después :analyzed al finalizar" do
      described_class.perform_now(wo.id)

      expect(wo.reload.status).to eq("analyzed")
    end

    it "crea/upserta el AiAnalysis con los args del agente" do
      described_class.perform_now(wo.id)

      analysis = wo.reload.ai_analysis
      expect(analysis).to be_present
      expect(analysis.category).to eq("engine")
      expect(analysis.confidence).to eq(0.8)
      expect(analysis.suggested_priority).to eq("high")
    end

    it "sincroniza el priority de la WO con la decisión del LLM (autoridad)" do
      expect(wo.priority).to be_nil # nullable, no default — Fase 3

      described_class.perform_now(wo.id)

      expect(wo.reload.priority).to eq("high")
    end
  end

  describe "WO cancelada antes de que arranque el job" do
    before { wo.update!(status: "cancelled") }

    it "no corre el agente (early return)" do
      expect(fake_agent).not_to receive(:run)
      described_class.perform_now(wo.id)
    end

    it "no toca el status (queda cancelled)" do
      described_class.perform_now(wo.id)
      expect(wo.reload.status).to eq("cancelled")
    end
  end

  describe "WO cancelada MIENTRAS el agente corre" do
    it "no persiste el análisis (respeta cancelación tardía)" do
      # Simulamos cancelación mid-run: agent#run cambia status antes de devolver
      allow(fake_agent).to receive(:run) do
        wo.update!(status: "cancelled")
        analysis_args
      end

      described_class.perform_now(wo.id)

      expect(wo.reload.ai_analysis).to be_nil
      expect(wo.status).to eq("cancelled")
    end
  end

  describe "agente falla" do
    before do
      allow(fake_agent).to receive(:run).and_raise(StandardError, "boom")
    end

    it "deja la WO en :draft (UI permite reintentar)" do
      expect { described_class.perform_now(wo.id) }.to raise_error(StandardError)
      expect(wo.reload.status).to eq("draft")
    end

    it "no crea ai_analysis (transacción rollback)" do
      expect { described_class.perform_now(wo.id) }.to raise_error(StandardError)
      expect(wo.reload.ai_analysis).to be_nil
    end
  end

  describe "discard_on RecordNotFound (Fase 3 fix)" do
    it "descarta el job en lugar de reintentar cuando la WO se borró" do
      expect {
        described_class.perform_now(999_999) # id inexistente
      }.not_to raise_error
    end
  end
end
