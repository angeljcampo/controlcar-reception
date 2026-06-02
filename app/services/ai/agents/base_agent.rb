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
    # Every run persists an AgentRun row with tokens, cost, latency, and a
    # raw_log of every LLM response + tool call so /agent_runs is auditable
    # end-to-end (no opaque "the model decided something" gaps).
    class BaseAgent
      MAX_ITERATIONS = 5

      class MaxIterationsExceeded < StandardError; end
      class UnknownTool < StandardError; end
      class NoFinalOutput < StandardError; end
      # Raised when the LLM hit the completion-token cap mid-response: it
      # didn't emit any tool calls because it ran out of budget (a lot of
      # which reasoning models spend on internal reasoning_tokens). Treated
      # as a transient retryable failure by AnalyzeWorkOrderJob.
      class TruncatedResponse < StandardError; end

      # @param provider [Ai::Providers::BaseProvider]
      # @param context [Hash] passed through to each tool instance
      def initialize(provider:, context: {})
        @provider = provider
        @context  = context
        @log      = []
      end

      # @return [Hash] the arguments the model passed to the final tool
      #   (i.e. the structured output the caller cares about).
      def run
        started_at = Time.current
        agent_run  = create_agent_run
        messages   = Array.new(initial_messages)

        MAX_ITERATIONS.times do |i|
          iteration = i + 1
          response = @provider.call(
            system:   system_prompt,
            messages: messages,
            tools:    Ai::Tools::ToolRegistry.schemas
          )
          track_usage(agent_run, response)
          log_llm_response(iteration, response)

          # The model called the final tool? Log its args, persist the run,
          # and return — we're done.
          if response.has_tool_call?(final_tool_name)
            final_args = response.tool_use_args(final_tool_name)
            log_final_output(final_args)
            mark_succeeded(agent_run, started_at)
            return final_args
          end

          # No tool calls at all? Two distinct failure modes:
          #
          # 1. stop_reason: :max_tokens → the model was CUT OFF before it
          #    could emit any tool call. Common with reasoning models that
          #    burn budget on internal reasoning. Retryable with a higher
          #    cap or a fresh attempt.
          # 2. anything else (:end_turn, etc.) → the model genuinely chose
          #    not to call any tool. Non-retryable; the prompt/tool setup
          #    needs to change.
          if response.tool_uses.empty?
            if response.stop_reason == :max_tokens
              used = response.usage&.dig(:completion_tokens).to_i
              raise TruncatedResponse,
                    "LLM response truncated at max_completion_tokens (#{used} completion tokens consumed, mostly reasoning). Bump DEFAULT_MAX_COMPLETION_TOKENS in OpenAIProvider or retry."
            else
              raise NoFinalOutput, "agent ended without calling #{final_tool_name} (stop_reason: #{response.stop_reason})"
            end
          end

          # Execute every non-final tool, then loop.
          tool_results = execute_tools(response.tool_uses, iteration)
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

      def execute_tools(tool_uses, iteration)
        tool_uses
          .reject { |tu| tu[:name] == final_tool_name }
          .map { |tu| execute_one_tool(tu, iteration) }
      end

      def execute_one_tool(tool_use, iteration)
        tool_class = Ai::Tools::ToolRegistry.find(tool_use[:name])
        raise UnknownTool, "unknown tool: #{tool_use[:name]}" if tool_class.nil?

        args = (tool_use[:arguments] || {}).symbolize_keys
        result = tool_class.new(context: @context).call(**args)
        log_tool_call(iteration, tool_use, result)
        { id: tool_use[:id], result: result }
      rescue => e
        log_tool_call(iteration, tool_use, nil, error: e.message)
        raise
      end

      # ── Log builders ───────────────────────────────────────────────
      # Each entry is a self-describing Hash that the agent_runs view
      # renders chronologically as a timeline.

      def log_llm_response(iteration, response)
        @log << {
          type:        "llm_response",
          iteration:   iteration,
          text:        response.text,
          tool_uses:   response.tool_uses.map { |tu| { id: tu[:id], name: tu[:name], arguments: tu[:arguments] } },
          stop_reason: response.stop_reason,
          usage:       response.usage,
          at:          Time.current.iso8601
        }
      end

      def log_tool_call(iteration, tool_use, result, error: nil)
        @log << {
          type:      "tool_call",
          iteration: iteration,
          name:      tool_use[:name],
          arguments: tool_use[:arguments],
          result:    result,
          error:     error,
          at:        Time.current.iso8601
        }
      end

      def log_final_output(args)
        @log << {
          type: "final_output",
          args: args,
          at:   Time.current.iso8601
        }
      end

      def mark_succeeded(agent_run, started_at)
        agent_run.update!(
          status:     "succeeded",
          latency_ms: ms_since(started_at),
          raw_log:    @log
        )
      end

      def mark_failed(agent_run, started_at, error_message)
        return if agent_run.failed?

        agent_run.update!(
          status:        "failed",
          latency_ms:    ms_since(started_at),
          error_message: error_message,
          raw_log:       @log
        )
      end

      def ms_since(started_at)
        ((Time.current - started_at) * 1000).round
      end
    end
  end
end
