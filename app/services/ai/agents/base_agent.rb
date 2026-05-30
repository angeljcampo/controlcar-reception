module Ai
  module Agents
    # Generic LLM agent with a tool-use loop.
    #
    # Subclasses override:
    #   - #system_prompt    — the model's persona/role
    #   - #initial_messages — what to send on the first turn
    #
    # The loop:
    #   1. Send (system, messages, tools) to the provider.
    #   2. If the response calls the FINAL tool (default: respond_with_analysis),
    #      grab its arguments and return them — that's the structured output.
    #   3. Otherwise, execute the tool calls, append the results, loop.
    #   4. Cap at MAX_ITERATIONS to prevent runaway loops.
    #
    # Every run persists an AgentRun row with tokens, cost, latency, and the
    # final status so /agent_runs is auditable end-to-end.
    class BaseAgent
      MAX_ITERATIONS = 5

      class MaxIterationsExceeded < StandardError; end
      class UnknownTool < StandardError; end
      class NoFinalOutput < StandardError; end

      # @param provider [Ai::Providers::BaseProvider]
      # @param context [Hash] passed through to each tool instance
      def initialize(provider:, context: {})
        @provider = provider
        @context  = context
      end

      # @return [Hash] the arguments the model passed to the final tool
      #   (i.e. the structured output the caller cares about).
      def run
        started_at = Time.current
        agent_run  = create_agent_run
        messages   = Array.new(initial_messages)

        MAX_ITERATIONS.times do
          response = @provider.call(
            system:   system_prompt,
            messages: messages,
            tools:    Ai::Tools::ToolRegistry.schemas
          )
          track_usage(agent_run, response)

          # The model called the final tool? Return its args — we're done.
          if response.has_tool_call?(final_tool_name)
            mark_succeeded(agent_run, started_at)
            return response.tool_use_args(final_tool_name)
          end

          # No tool calls at all? The model gave up without producing
          # structured output. Treat as failure.
          if response.tool_uses.empty?
            raise NoFinalOutput, "agent ended without calling #{final_tool_name}"
          end

          # Execute every non-final tool, then loop.
          tool_results = execute_tools(response.tool_uses)
          messages.concat(@provider.follow_up_messages(response, tool_results))
        end

        raise MaxIterationsExceeded, "max #{MAX_ITERATIONS} iterations"
      rescue => e
        mark_failed(agent_run, started_at, e.message)
        raise
      end

      protected

      # In Spanish, expert-mechanic tone, etc. Subclass responsibility.
      def system_prompt
        raise NotImplementedError, "#{self.class} must define #system_prompt"
      end

      # First message(s) of the conversation. Subclass builds them from
      # context (e.g. work order reason + photos for multimodal).
      def initial_messages
        raise NotImplementedError, "#{self.class} must define #initial_messages"
      end

      # The tool whose invocation terminates the loop with structured output.
      # Overridable if a subclass wants a different final-tool name.
      def final_tool_name
        "respond_with_analysis"
      end

      private

      def create_agent_run
        AgentRun.create!(
          work_order:     @context[:work_order],
          agent_name:     self.class.name,
          ai_model:       @provider.model,
          status:         "running",
          input_tokens:   0,
          output_tokens:  0,
          cost_cents:     0,
          raw_log:        []
        )
      end

      def track_usage(agent_run, response)
        usage = response.usage || {}
        new_input  = agent_run.input_tokens  + usage[:prompt_tokens].to_i
        new_output = agent_run.output_tokens + usage[:completion_tokens].to_i

        agent_run.update!(
          input_tokens:  new_input,
          output_tokens: new_output,
          cost_cents:    Ai::CostCalculator.cents_for(
            model:          @provider.model,
            input_tokens:   new_input,
            output_tokens:  new_output
          ) || agent_run.cost_cents
        )
      end

      def execute_tools(tool_uses)
        tool_uses
          .reject { |tu| tu[:name] == final_tool_name }
          .map { |tu| execute_one_tool(tu) }
      end

      def execute_one_tool(tool_use)
        tool_class = Ai::Tools::ToolRegistry.find(tool_use[:name])
        raise UnknownTool, "unknown tool: #{tool_use[:name]}" if tool_class.nil?

        args = (tool_use[:arguments] || {}).symbolize_keys
        result = tool_class.new(context: @context).call(**args)
        { id: tool_use[:id], result: result }
      end

      def mark_succeeded(agent_run, started_at)
        agent_run.update!(
          status:     "succeeded",
          latency_ms: ms_since(started_at)
        )
      end

      def mark_failed(agent_run, started_at, error_message)
        return if agent_run.failed?

        agent_run.update!(
          status:        "failed",
          latency_ms:    ms_since(started_at),
          error_message: error_message
        )
      end

      def ms_since(started_at)
        ((Time.current - started_at) * 1000).round
      end
    end
  end
end
