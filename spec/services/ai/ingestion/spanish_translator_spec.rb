# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Ingestion::SpanishTranslator do
  let(:chunks) do
    [
      {
        content:    "P0010 - Intake Camshaft Position Actuator Circuit/Open (Bank 1)",
        breadcrumb: "DTC Manual › P0010 — Intake Camshaft",
        metadata:   { dtc_code: "P0010" }
      },
      {
        content:    "P0011 - Intake Camshaft Position Timing - Over-Advanced",
        breadcrumb: "DTC Manual › P0011",
        metadata:   { dtc_code: "P0011" }
      }
    ]
  end

  before { ENV["OPENAI_API_KEY"] = "sk-test-fake-key" }

  describe ".call" do
    context "respuesta válida de OpenAI" do
      let(:openai_response) do
        {
          choices: [
            {
              message: {
                content: {
                  translations: [
                    { index: 0,
                      content: "P0010 - Circuito/Apertura del Actuador de Posición del Árbol de Levas (Banco 1)",
                      breadcrumb: "Manual DTC › P0010 — Árbol de Levas de Admisión" },
                    { index: 1,
                      content: "P0011 - Temporización - Sobreavanzada",
                      breadcrumb: "Manual DTC › P0011" }
                  ]
                }.to_json
              }
            }
          ]
        }
      end

      before do
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body:   openai_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "devuelve un chunk traducido por cada chunk input, mismo orden" do
        result = described_class.call(chunks)

        expect(result.size).to eq(2)
        expect(result.first[:content]).to include("Árbol de Levas")
        expect(result.last[:content]).to include("Sobreavanzada")
      end

      it "preserva el código DTC en breadcrumb traducido" do
        result = described_class.call(chunks)

        expect(result[0][:breadcrumb]).to include("P0010")
        expect(result[1][:breadcrumb]).to include("P0011")
      end

      it "guarda el original en metadata.original_content_en para audit" do
        result = described_class.call(chunks)

        expect(result[0][:metadata][:original_content_en]).to eq(chunks[0][:content])
        expect(result[0][:metadata][:original_breadcrumb_en]).to eq(chunks[0][:breadcrumb])
      end

      it "preserva metadata existente (dtc_code, etc.) sin pisar" do
        result = described_class.call(chunks)
        expect(result[0][:metadata][:dtc_code]).to eq("P0010")
      end
    end

    context "input vacío" do
      it "devuelve array vacío sin llamar a OpenAI" do
        result = described_class.call([])
        expect(result).to eq([])
        # WebMock raise si llega un request inesperado
      end
    end

    context "sin OPENAI_API_KEY" do
      before { ENV["OPENAI_API_KEY"] = nil }

      it "raises MissingApiKey" do
        expect {
          described_class.call(chunks)
        }.to raise_error(described_class::MissingApiKey)
      end
    end

    context "respuesta con mismatch de cantidad (defensa contra LLM defectuoso)" do
      before do
        # OpenAI devuelve 1 sola traducción cuando le pedimos 2
        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_return(
            status: 200,
            body:   {
              choices: [{ message: {
                content: { translations: [
                  { index: 0, content: "solo una", breadcrumb: "x" }
                ] }.to_json
              } }]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises TranslationError con info clara" do
        expect {
          described_class.call(chunks)
        }.to raise_error(described_class::TranslationError, /1 traducciones para 2 chunks/)
      end
    end

    context "timeout transitorio (retry interno)" do
      it "reintenta hasta MAX_BATCH_RETRIES con backoff antes de fallar" do
        # Mock sleep para que el spec corra rápido (no esperar 5s × 3 = 15s real)
        allow(described_class).to receive(:new).and_wrap_original do |orig, *args|
          instance = orig.call(*args)
          allow(instance).to receive(:sleep)
          instance
        end

        stub_request(:post, "https://api.openai.com/v1/chat/completions")
          .to_raise(Net::ReadTimeout)

        expect {
          described_class.call(chunks)
        }.to raise_error(described_class::TranslationError, /tras 3 intentos/)
      end
    end
  end

  describe ".system_prompt" do
    it "carga desde PromptTemplate (archivo separado, no inline)" do
      prompt = described_class.system_prompt
      expect(prompt).to include("traductor")
      expect(prompt).to include("P0010") # menciona el ejemplo en el .md
    end
  end
end
