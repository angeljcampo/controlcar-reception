module Ai
  module Tools
    # Investigation tool: look up previous work orders for the same vehicle
    # so the agent can spot patterns (recurring failure, recently replaced
    # part, etc.). Excludes the WorkOrder currently being analyzed.
    #
    # Receives the patente as input (uppercase normalized). Returns a
    # structured Hash that's JSON-serialized into the tool-result message
    # the model reads on the next turn.
    class GetVehicleHistory < BaseTool
      class << self
        def tool_name
          "get_vehicle_history"
        end

        def description
          <<~TXT.strip
            Devuelve las órdenes de trabajo anteriores del mismo vehículo
            (por patente), excluyendo la orden actual. Útil para detectar
            patrones: si el mismo síntoma ya apareció antes, si se
            reemplazó una pieza recientemente, o si hay reparaciones
            relacionadas.

            Si el vehículo no tiene historial, devuelve previous_work_orders
            como array vacío. Si la patente no existe en la base, found es
            false. Llamar esta tool al menos una vez antes de emitir el
            análisis final, salvo que esté claro que es la primera visita.
          TXT
        end

        def input_schema
          {
            type: "object",
            additionalProperties: false,
            required: [ "patente" ],
            properties: {
              patente: {
                type: "string",
                description: "Patente del vehículo. Acepta mayúsculas/minúsculas; se normaliza internamente."
              }
            }
          }
        end
      end

      def call(patente:)
        normalized = normalize_patente(patente)
        vehicle    = Vehicle.find_by("UPPER(patente) = ?", normalized)

        return not_found_response(patente) if vehicle.nil?

        {
          found:    true,
          patente:  vehicle.patente,
          make:     vehicle.make,
          model:    vehicle.model,
          year:     vehicle.year,
          previous_work_orders: serialize_history(vehicle)
        }
      end

      private

      def serialize_history(vehicle)
        vehicle.history_excluding(context[:work_order])
               .includes(:ai_analysis)
               .map { |wo| serialize_work_order(wo) }
      end

      def serialize_work_order(work_order)
        {
          id:             work_order.id,
          created_at:     work_order.created_at.iso8601,
          mileage:        work_order.mileage,
          reason:         work_order.reason,
          priority_input: work_order.priority,
          status:         work_order.status,
          ai_analysis:    serialize_analysis(work_order.ai_analysis)
        }
      end

      def serialize_analysis(analysis)
        return nil if analysis.nil?

        {
          category:           analysis.category,
          suggested_priority: analysis.suggested_priority,
          possible_failures:  analysis.possible_failures,
          confidence:         analysis.confidence&.to_f,
          observations:       analysis.observations
        }
      end

      def not_found_response(raw_patente)
        {
          found:   false,
          patente: raw_patente,
          message: "No se encontró ningún vehículo con esa patente."
        }
      end

      def normalize_patente(raw)
        raw.to_s.upcase.gsub(/\s+/, "")
      end
    end
  end
end
