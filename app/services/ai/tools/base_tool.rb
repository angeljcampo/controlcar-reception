module Ai
  module Tools
    # Contract for every tool the agent can call.
    #
    # Class-level (identity): tool_name, description, input_schema, to_openai.
    # Instance-level (execution): #call(**args) runs the tool with @context.
    #
    # Subclasses must override .tool_name, .description, .input_schema, and #call.
    class BaseTool
      class << self
        # Stable identifier used by the model in tool_calls.
        # Use snake_case, e.g. "respond_with_analysis".
        def tool_name
          raise NotImplementedError, "#{name} must define .tool_name"
        end

        # Plain-language description shown to the model. Be specific about
        # WHEN to call this tool — that's where most accuracy gains come from.
        def description
          raise NotImplementedError, "#{name} must define .description"
        end

        # JSON Schema of the arguments object the model must produce.
        # Use strict types and enums; vague schemas produce vague calls.
        def input_schema
          raise NotImplementedError, "#{name} must define .input_schema"
        end

        # Convert this tool to OpenAI's function-calling shape with strict
        # schema enforcement enabled. With strict: true, OpenAI guarantees
        # the arguments object conforms to input_schema at the API boundary.
        def to_openai
          {
            type: "function",
            function: {
              name: tool_name,
              description: description,
              parameters: input_schema,
              strict: true
            }
          }
        end
      end

      # @param context [Hash] runtime context shared with the tool
      #   (e.g. { work_order: <WorkOrder>, current_user: <User> })
      def initialize(context: {})
        @context = context
      end

      # Execute the tool. Subclasses receive the parsed arguments as kwargs.
      #
      # @return [Hash, Array, String, Numeric, Boolean, nil]
      #   Returned value is JSON-serialized and sent back to the model.
      def call(**args)
        raise NotImplementedError, "#{self.class} must implement #call"
      end

      protected

      attr_reader :context
    end
  end
end
