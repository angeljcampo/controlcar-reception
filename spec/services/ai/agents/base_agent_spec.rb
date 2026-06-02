# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::Agents::BaseAgent do
  # Subclase mínima para testear el loop. BaseAgent es abstracto.
  # Le damos `name` explícito porque `self.class.name` en anonymous class
  # es nil → AgentRun#agent_name presence validation falla.
  # `initial_messages` devuelve content como array de parts multimodal
  # porque BaseAgent#summarize_content asume ese formato (de prod).
  let(:agent_class) do
    Class.new(described_class) do
      def self.name = "TestAgent"
      def system_prompt = "You are a test agent."
      def initial_messages
        [{ role: "user", content: [{ type: "text", text: "test prompt" }] }]
      end
    end
  end

  # Fake provider que devuelve respuestas controladas. Implementa
  # solo lo que BaseAgent#run usa.
  let(:provider) do
    Class.new do
      attr_accessor :responses_queue, :model, :follow_ups_emitted

      def initialize
        @responses_queue = []
        @model = "test-model"
        @follow_ups_emitted = 0
      end

      def call(system:, messages:, tools:)
        @responses_queue.shift or raise "No more queued responses"
      end

      def follow_up_messages(_response, _tool_results)
        @follow_ups_emitted += 1
        [{ role: "tool", content: "ack" }]
      end
    end.new
  end

  let(:wo) {
    v = Vehicle.create!(patente: "X")
    v.work_orders.create!(customer_name: "x", reason: "x", mileage: 0)
  }

  let(:context) { { work_order: wo } }
  let(:agent) { agent_class.new(provider: provider, context: context) }

  # Helper para construir respuestas fake del provider
  def fake_response(text: "", tool_uses: [], stop_reason: :end_turn, usage: {})
    double(
      "LlmResponse",
      text: text,
      tool_uses: tool_uses,
      stop_reason: stop_reason,
      usage: usage,
      has_tool_call?: tool_uses.any? { |tu| tu[:name] == "respond_with_analysis" },
      tool_use_args: tool_uses.find { |tu| tu[:name] == "respond_with_analysis" }&.dig(:arguments) || {}
    )
  end

  describe "#run" do
    context "happy path: LLM llama directamente respond_with_analysis" do
      before do
        provider.responses_queue << fake_response(
          tool_uses: [{ id: "1", name: "respond_with_analysis", arguments: { category: "engine" } }],
          usage: { prompt_tokens: 100, completion_tokens: 50 }
        )
      end

      it "devuelve los args de la final tool" do
        result = agent.run
        expect(result).to eq({ category: "engine" })
      end

      it "crea AgentRun en :running y lo deja :succeeded al final" do
        expect { agent.run }.to change(AgentRun, :count).by(1)

        run = AgentRun.last
        expect(run.status).to eq("succeeded")
        expect(run.work_order).to eq(wo)
        expect(run.input_tokens).to eq(100)
        expect(run.output_tokens).to eq(50)
      end

      it "registra latency_ms" do
        agent.run
        expect(AgentRun.last.latency_ms).to be_a(Integer).and be > 0
      end
    end

    context "tool loop: LLM llama otra tool, después la final" do
      let(:get_history_tool) {
        double("ToolClass", new: double("instance", call: { found: true }))
      }

      before do
        # Stub registry para usar nuestra tool fake
        allow(Ai::Tools::ToolRegistry).to receive(:find).with("get_vehicle_history").and_return(get_history_tool)
        allow(Ai::Tools::ToolRegistry).to receive(:schemas).and_return([])

        # 1ra respuesta: llama get_vehicle_history
        provider.responses_queue << fake_response(
          tool_uses: [{ id: "1", name: "get_vehicle_history", arguments: { patente: "X" } }],
          usage: { prompt_tokens: 100, completion_tokens: 30 }
        )
        # 2da respuesta: llama final tool
        provider.responses_queue << fake_response(
          tool_uses: [{ id: "2", name: "respond_with_analysis", arguments: { category: "engine" } }],
          usage: { prompt_tokens: 150, completion_tokens: 40 }
        )
      end

      it "ejecuta las tools intermedias antes de finalizar" do
        agent.run
        expect(provider.follow_ups_emitted).to eq(1)
      end

      it "acumula tokens de TODAS las iteraciones del loop" do
        agent.run
        run = AgentRun.last
        expect(run.input_tokens).to eq(250) # 100 + 150
        expect(run.output_tokens).to eq(70)  # 30 + 40
      end
    end

    context "LLM se queda sin tokens (stop_reason: max_tokens)" do
      before do
        provider.responses_queue << fake_response(
          tool_uses: [], stop_reason: :max_tokens, usage: { completion_tokens: 4096 }
        )
      end

      it "raises TruncatedResponse (retryable)" do
        expect { agent.run }.to raise_error(described_class::TruncatedResponse, /truncated/i)
      end

      it "marca AgentRun como :failed con error_message" do
        expect { agent.run }.to raise_error(described_class::TruncatedResponse)
        expect(AgentRun.last.status).to eq("failed")
        expect(AgentRun.last.error_message).to be_present
      end
    end

    context "LLM termina sin llamar la final tool ni otra" do
      before do
        provider.responses_queue << fake_response(
          tool_uses: [], stop_reason: :end_turn
        )
      end

      it "raises NoFinalOutput (non-retryable — prompt issue)" do
        expect { agent.run }.to raise_error(described_class::NoFinalOutput)
      end
    end

    context "loop infinito: llega al MAX_ITERATIONS cap" do
      before do
        # Devuelve siempre un tool call que NO es la final → loop infinito
        allow(Ai::Tools::ToolRegistry).to receive(:find).and_return(
          double(new: double(call: {}))
        )
        allow(Ai::Tools::ToolRegistry).to receive(:schemas).and_return([])

        # MAX_ITERATIONS = 5 — encolamos 5 respuestas non-final
        5.times do |i|
          provider.responses_queue << fake_response(
            tool_uses: [{ id: i.to_s, name: "get_vehicle_history", arguments: {} }]
          )
        end
      end

      it "raises MaxIterationsExceeded" do
        expect { agent.run }.to raise_error(described_class::MaxIterationsExceeded)
      end
    end

    context "inyección de agent_run al context de tools (Fase 3)" do
      it "los tools reciben agent_run para persistir RetrievalRun" do
        tool_double = double("instance", call: {})
        tool_class  = double("ToolClass")

        allow(Ai::Tools::ToolRegistry).to receive(:find).with("search_knowledge_base").and_return(tool_class)
        allow(Ai::Tools::ToolRegistry).to receive(:schemas).and_return([])

        # Verificamos que cuando se construye la tool, el context incluya :agent_run
        expect(tool_class).to receive(:new) do |context:|
          expect(context).to have_key(:agent_run)
          expect(context[:agent_run]).to be_a(AgentRun)
          tool_double
        end

        provider.responses_queue << fake_response(
          tool_uses: [{ id: "1", name: "search_knowledge_base", arguments: { query: "x" } }]
        )
        provider.responses_queue << fake_response(
          tool_uses: [{ id: "2", name: "respond_with_analysis", arguments: { category: "x" } }]
        )

        agent.run
      end
    end
  end
end
