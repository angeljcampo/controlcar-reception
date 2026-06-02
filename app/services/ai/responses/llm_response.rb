module Ai
  module Responses
    # Provider-agnostic representation of a single LLM response.
    #
    # Fields:
    # - text [String, nil]    free-form assistant text (nil when finished via tool_use)
    # - tool_uses [Array<Hash>] each element: { id:, name:, arguments: }
    #     - id: provider-assigned tool-call id, needed when sending the result back
    #     - name: which tool the model asked to invoke
    #     - arguments: parsed Hash with symbol keys
    # - usage [Hash]          { prompt_tokens:, completion_tokens: }
    # - stop_reason [Symbol]  :tool_use | :end_turn | :max_tokens
    #
    # Concrete providers (OpenAIProvider, future AnthropicProvider) are
    # responsible for mapping their native response shape to this struct.
    LlmResponse = Data.define(:text, :tool_uses, :usage, :stop_reason) do
      def total_tokens
        usage[:prompt_tokens].to_i + usage[:completion_tokens].to_i
      end

      def has_tool_call?(tool_name)
        tool_uses.any? { |tu| tu[:name] == tool_name }
      end

      def tool_use_args(tool_name)
        tool_uses.find { |tu| tu[:name] == tool_name }&.dig(:arguments)
      end
    end
  end
end
