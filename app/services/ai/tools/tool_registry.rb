module Ai
  module Tools
    # Single source of truth for which tools the agent can invoke.
    # Adding a tool = appending its class to TOOLS in a code change.
    #
    # Each tool class must inherit from Ai::Tools::BaseTool.
    module ToolRegistry
      # Tools that the agent can call. Order is significant only for clarity
      # in the OpenAI tools array (the model can pick any of them).
      TOOLS = [
        Ai::Tools::GetVehicleHistory,
        Ai::Tools::SearchKnowledgeBase,
        Ai::Tools::RespondWithAnalysis
      ].freeze

      class << self
        # Schemas in the OpenAI native format (for now).
        # When we add a second provider, we'll branch here.
        def schemas
          TOOLS.map(&:to_openai)
        end

        def find(tool_name)
          TOOLS.find { |t| t.tool_name == tool_name }
        end

        def all
          TOOLS
        end
      end
    end
  end
end
