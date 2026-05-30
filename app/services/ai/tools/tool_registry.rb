module Ai
  module Tools
    # Single source of truth for which tools the agent can invoke.
    # Adding a tool = appending its class to TOOLS in a code change.
    #
    # Each tool class must inherit from Ai::Tools::BaseTool.
    module ToolRegistry
      # Tools are added in subsequent commits:
      #   - RespondWithAnalysis (Commit 3) — forced structured final output
      #   - GetVehicleHistory   (Commit 4) — historical context per patente
      TOOLS = [].freeze

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
