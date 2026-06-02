# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Tools::RespondWithAnalysis do
  describe ".tool_name" do
    it "es el identificador estable que usa OpenAI tool_calls" do
      expect(described_class.tool_name).to eq("respond_with_analysis")
    end
  end

  describe ".description" do
    it "instruye al LLM a llamarla SOLO al final, una vez" do
      expect(described_class.description).to include("SIEMPRE llamar")
      expect(described_class.description).to include("una sola vez")
    end

    it "menciona que el contenido textual debe estar en español" do
      expect(described_class.description).to match(/espa[ñn]ol/i)
    end
  end

  describe ".input_schema" do
    subject(:schema) { described_class.input_schema }

    it "carga desde SchemaTemplate (archivo JSON externo)" do
      # Asegura que el refactor a archivos siga vigente
      expect(Ai::SchemaTemplate).to receive(:load).with("respond_with_analysis").and_call_original
      schema
    end

    it "cumple OpenAI strict mode: todas las properties en required" do
      property_keys = schema[:properties].keys
      expect(schema[:required].map(&:to_sym)).to match_array(property_keys)
    end

    it "incluye sources con dtc_code (added in phase 3)" do
      source_schema = schema.dig(:properties, :sources, :items)
      expect(source_schema[:properties]).to have_key(:dtc_code)
      expect(source_schema[:required]).to include("dtc_code")
    end
  end

  describe ".to_openai" do
    it "formatea con strict: true (garantía de schema en API)" do
      payload = described_class.to_openai

      expect(payload[:type]).to eq("function")
      expect(payload[:function][:strict]).to be true
      expect(payload[:function][:name]).to eq("respond_with_analysis")
    end
  end

  describe "#call" do
    # call() es el echo no-op porque BaseAgent#run termina el loop al ver
    # esta tool sin invocarla — pero mantenemos el método por consistencia
    it "devuelve los args sin modificarlos (echo)" do
      tool = described_class.new(context: {})
      args = { category: "engine", priority: "high" }

      expect(tool.call(**args)).to eq(args)
    end
  end
end
