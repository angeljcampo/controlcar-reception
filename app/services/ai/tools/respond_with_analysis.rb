module Ai
  module Tools
    # Forced final-output tool. The MechanicDiagnosticAgent's system prompt
    # instructs the model to ALWAYS call this tool exactly once at the end.
    # Combined with strict: true on the schema, this turns the model's
    # response into a guaranteed-shape Hash that the job can persist
    # directly into the AiAnalysis row — no fragile prompt-and-parse.
    #
    # BaseAgent#run short-circuits on this tool: when the model calls it,
    # the agent grabs the arguments and returns them without invoking the
    # tool's #call. The #call implementation is kept as a no-op echo so
    # the tool contract is still satisfied.
    class RespondWithAnalysis < BaseTool
      class << self
        def tool_name
          "respond_with_analysis"
        end

        def description
          <<~TXT.strip
            Devuelve el análisis final del problema en formato estructurado.
            SIEMPRE llamar esta tool al final, una sola vez, después de haber
            usado las otras tools que necesites para investigar. No combinar
            con otras tools en la misma respuesta.

            El contenido textual (reasoning, priority_reason, next_steps.action,
            observations) DEBE estar en español neutro, dirigido al mecánico
            o recepcionista del taller. Los valores enumerados (category,
            priority, probability) usan keys en inglés definidas en el schema.
          TXT
        end

        # Schema cargado desde `config/schemas/respond_with_analysis.json`.
        # Ver el JSON para el shape completo + ejemplos. Los enums (category,
        # priority, probability) están hardcoded en el JSON — si cambian en
        # los modelos Ruby, actualizar también el JSON.
        def input_schema
          Ai::SchemaTemplate.load("respond_with_analysis")
        end
      end

      # Echo the args. BaseAgent#run terminates on this tool without invoking
      # #call, but we keep a sane implementation in case anyone introspects.
      def call(**args)
        args
      end
    end
  end
end
