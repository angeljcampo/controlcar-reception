module Ai
  module Providers
    # Concrete OpenAI implementation of BaseProvider using the ruby-openai
    # gem. Targets GPT-5 with function calling and strict structured outputs.
    #
    # Configuration: reads OPENAI_API_KEY from the environment.
    #   .env (local dev):   OPENAI_API_KEY=sk-...
    #   Render (prod):      configure in the service's env vars.
    class OpenAIProvider < BaseProvider
      MODEL = "gpt-5".freeze

      # GPT-5 (and o-family reasoning models) reject the legacy max_tokens
      # parameter; max_completion_tokens replaces it and is accepted by all
      # current chat models.
      #
      # 16384 instead of 4096 because reasoning models burn a large slice of
      # the completion budget on internal reasoning_tokens BEFORE emitting
      # the final structured output. At 4096 we hit the cap and got
      # truncated responses with empty tool_uses (LLM "ended" mid-thought).
      DEFAULT_MAX_COMPLETION_TOKENS = 16384

      class MissingApiKey < StandardError; end
      class ApiError < StandardError; end

      def initialize(api_key: ENV["OPENAI_API_KEY"], model: MODEL)
        raise MissingApiKey, "OPENAI_API_KEY is not set" if api_key.blank?

        @client = OpenAI::Client.new(access_token: api_key)
        @model  = model
      end

      def model
        @model
      end

      def call(system:, messages:, tools:)
        api_response = @client.chat(
          parameters: {
            model:                  @model,
            messages:               [ { role: "system", content: system }, *messages ],
            tools:                  tools,
            tool_choice:            "auto",
            max_completion_tokens:  DEFAULT_MAX_COMPLETION_TOKENS
          }
        )

        # Defensive: some integration shapes return a 200 with an error key.
        raise ApiError, api_response["error"]["message"] if api_response["error"]

        build_response(api_response)
      rescue Faraday::Error => e
        # ruby-openai raises Faraday::Error subclasses on 4xx/5xx. The default
        # message is just "status 4xx", which buries the actual API problem
        # (wrong param, model not allowed, etc.). Pull the JSON body out so
        # the AgentRun row records a useful error.
        raise ApiError, format_faraday_error(e)
      end

      # OpenAI's wire format for sending tool results back:
      #   1. Assistant message that records the tool_calls it made.
      #   2. One "tool" message per call carrying the result string.
      def follow_up_messages(response, tool_results)
        [
          assistant_tool_call_message(response),
          *tool_results.map { |r| tool_result_message(r[:id], r[:result]) }
        ]
      end

      private

      def assistant_tool_call_message(response)
        {
          role:       "assistant",
          content:    response.text,
          tool_calls: response.tool_uses.map do |tu|
            {
              id:       tu[:id],
              type:     "function",
              function: {
                name:      tu[:name],
                # Arguments must be sent back as a JSON-encoded string,
                # mirroring what the model originally produced.
                arguments: tu[:arguments].to_json
              }
            }
          end
        }
      end

      def tool_result_message(tool_call_id, result)
        {
          role:         "tool",
          tool_call_id: tool_call_id,
          content:      result.to_json
        }
      end

      def build_response(api_response)
        choice  = api_response.dig("choices", 0) || {}
        message = choice["message"] || {}
        usage   = api_response["usage"] || {}

        Ai::Responses::LlmResponse.new(
          text:        message["content"],
          tool_uses:   normalize_tool_calls(message["tool_calls"]),
          usage:       {
            prompt_tokens:     usage["prompt_tokens"].to_i,
            completion_tokens: usage["completion_tokens"].to_i
          },
          stop_reason: stop_reason_for(choice["finish_reason"])
        )
      end

      def normalize_tool_calls(tool_calls)
        Array(tool_calls).map do |tc|
          {
            id:        tc["id"],
            name:      tc.dig("function", "name"),
            arguments: parse_arguments(tc.dig("function", "arguments"))
          }
        end
      end

      # The model returns arguments as a JSON-encoded string. With strict
      # tools, this parses cleanly; if it doesn't we surface the raw text
      # so the agent can decide what to do.
      def parse_arguments(json_string)
        return {} if json_string.blank?

        JSON.parse(json_string).deep_symbolize_keys
      rescue JSON::ParserError
        { _raw: json_string }
      end

      def stop_reason_for(finish_reason)
        case finish_reason
        when "tool_calls" then :tool_use
        when "stop"       then :end_turn
        when "length"     then :max_tokens
        else                   finish_reason&.to_sym
        end
      end

      # Pulls the actual OpenAI error message out of a Faraday error response
      # body. Falls back to the raw body if the JSON shape isn't what we expect.
      def format_faraday_error(faraday_error)
        response = faraday_error.respond_to?(:response) ? faraday_error.response : nil
        status   = response&.dig(:status)
        body     = response&.dig(:body)
        api_msg  = body.is_a?(Hash) ? body.dig("error", "message") : nil

        if api_msg
          "OpenAI #{status}: #{api_msg}"
        elsif body
          "OpenAI #{status}: #{body.inspect[0, 300]}"
        else
          faraday_error.message
        end
      end
    end
  end
end
