module Ai
  module Providers
    # Abstract LLM provider. Concrete subclasses (OpenAIProvider, future
    # AnthropicProvider/GeminiProvider) implement the three methods below.
    #
    # The agent loop in Ai::Agents::BaseAgent talks to provider only through
    # this interface, so swapping providers is one class change away.
    class BaseProvider
      # Send a turn to the LLM.
      #
      # @param system [String] system prompt
      # @param messages [Array<Hash>] message history in the provider's
      #   native format (e.g. OpenAI's role/content/tool_calls shape)
      # @param tools [Array<Hash>] tool schemas in the provider's native format
      # @return [Ai::Responses::LlmResponse]
      def call(system:, messages:, tools:)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      # The model identifier (e.g. "gpt-5") this provider is configured for.
      # Used by AgentRun for observability and CostCalculator for pricing.
      def model
        raise NotImplementedError, "#{self.class} must implement #model"
      end

      # After the model called tools, build the follow-up messages to append
      # to the conversation: the assistant message that records the tool
      # calls, plus one tool-result message per call.
      #
      # This lives on the provider because the on-wire format is provider-
      # specific (OpenAI uses role: "tool" + tool_call_id; Anthropic uses
      # role: "user" + content blocks of type "tool_result"; etc.).
      #
      # @param response [Ai::Responses::LlmResponse] the response containing tool_uses
      # @param tool_results [Array<Hash>] each: { id:, result: } — id matches
      #   the tool_use id, result is whatever the tool's #call returned
      # @return [Array<Hash>] messages to append
      def follow_up_messages(response, tool_results)
        raise NotImplementedError, "#{self.class} must implement #follow_up_messages"
      end
    end
  end
end
