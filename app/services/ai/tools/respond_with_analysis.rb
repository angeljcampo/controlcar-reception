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
      CATEGORIES = %w[
        engine transmission brakes suspension electrical
        cooling fuel exhaust tires body diagnosis_needed other
      ].freeze

      PROBABILITIES = %w[high medium low].freeze
      PRIORITIES    = WorkOrder::PRIORITIES

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

        def input_schema
          {
            type: "object",
            additionalProperties: false,
            required: %w[
              category possible_failures priority priority_reason
              next_steps sources confidence requires_human_review observations
            ],
            properties: {
              category: {
                type: "string",
                enum: CATEGORIES,
                description: "Sistema mecánico principalmente afectado."
              },
              possible_failures: {
                type: "array",
                description: "Lista priorizada de fallas candidatas, mayor a menor probabilidad.",
                items: possible_failure_schema
              },
              priority: {
                type: "string",
                enum: PRIORITIES,
                description: "Prioridad sugerida según severidad y riesgo."
              },
              priority_reason: {
                type: "string",
                description: "Justificación breve (1-2 oraciones) de la prioridad sugerida. En español."
              },
              next_steps: {
                type: "array",
                description: "Pasos diagnósticos ordenados, del más barato/rápido al más invasivo.",
                items: next_step_schema
              },
              sources: {
                type: "array",
                description: "Citas a chunks del knowledge base. Vacío si no se usó RAG.",
                items: source_schema
              },
              confidence: {
                type: "number",
                description: "Confianza global en el análisis, de 0.0 (incertidumbre total) a 1.0 (alta certeza)."
              },
              requires_human_review: {
                type: "boolean",
                description: "true si la confianza es baja o los síntomas son ambiguos y conviene que un mecánico revise antes de actuar."
              },
              observations: {
                type: %w[string null],
                description: "Notas adicionales opcionales. null si no hay nada que agregar."
              }
            }
          }
        end

        private

        def possible_failure_schema
          {
            type: "object",
            additionalProperties: false,
            required: %w[component probability reasoning],
            properties: {
              component: {
                type: "string",
                description: "Componente específico que podría estar fallando (ej: 'bobina de encendido cilindro 1')."
              },
              probability: {
                type: "string",
                enum: PROBABILITIES,
                description: "Probabilidad relativa de que esta sea la causa real."
              },
              reasoning: {
                type: "string",
                description: "Por qué este componente es sospechoso, dado los síntomas. En español."
              }
            }
          }
        end

        def next_step_schema
          {
            type: "object",
            additionalProperties: false,
            required: %w[order action required_tool],
            properties: {
              order: {
                type: "integer",
                description: "Orden de ejecución, empezando en 1."
              },
              action: {
                type: "string",
                description: "Acción concreta a realizar. En español, instructivo."
              },
              required_tool: {
                type: %w[string null],
                description: "Herramienta o instrumento necesario (ej: 'escáner OBD-II', 'multímetro'). null si no aplica."
              }
            }
          }
        end

        def source_schema
          {
            type: "object",
            additionalProperties: false,
            required: %w[document_title page relevant_excerpt],
            properties: {
              document_title: { type: "string" },
              page:           { type: "integer" },
              relevant_excerpt: {
                type: "string",
                description: "Fragmento exacto del documento que apoyó esta parte del análisis."
              }
            }
          }
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
