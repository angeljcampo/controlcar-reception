# frozen_string_literal: true

# Carga schemas JSON desde `config/schemas/` y los devuelve como Hash
# con symbol keys (formato que OpenAI espera en function calling).
#
# Por qué archivos separados:
#   - Los schemas son tipos de datos puros — viven mejor en JSON estándar
#     que en un Hash Ruby. Portables a frontend / otros lenguajes / docs.
#   - El schema de respond_with_analysis tiene ~120 líneas anidadas;
#     embebido en Ruby es ilegible. En JSON dedicado es navegable.
#   - Frontend que valida formularios podría reusar el mismo JSON Schema.
#
# Convenciones:
#   - Schemas en `config/schemas/<name>.json`
#   - Se referencian por nombre: `"respond_with_analysis"`
#   - JSON puro, sin ERB. Los enum values (priority, category, etc.) se
#     hardcodean — si cambian en el modelo, el schema debe actualizarse
#     explícitamente. Es una elección: portabilidad > DRY automático.
#
# Performance:
#   - Cache en memoria + symbolize_keys profundo. Re-lee en dev, warm en prod.
#
# Uso:
#   Ai::SchemaTemplate.load("respond_with_analysis")
#   # => { type: "object", properties: { ... }, required: [...] }
module Ai
  class SchemaTemplate
    class NotFound < StandardError; end
    class InvalidJson < StandardError; end

    SCHEMAS_DIR = Rails.root.join("config/schemas").freeze

    @cache = {}
    @mutex = Mutex.new

    class << self
      def load(name)
        path = SCHEMAS_DIR.join("#{name}.json")
        raise NotFound, "Schema '#{name}' no encontrado en #{path}" unless File.exist?(path)

        if Rails.env.development? || Rails.env.test?
          parse(File.read(path), name)
        else
          @mutex.synchronize do
            @cache[path] ||= parse(File.read(path), name).freeze
          end
        end
      end

      def reload!
        @mutex.synchronize { @cache.clear }
      end

      private

      def parse(raw, name)
        parsed = JSON.parse(raw, symbolize_names: true)
        strip_meta(parsed)
      rescue JSON::ParserError => e
        raise InvalidJson, "Schema '#{name}' tiene JSON inválido: #{e.message}"
      end

      # Remueve keys que empiezan con `_` recursivamente. Convención:
      # `_meta`, `_comment`, `_notes` son docs para humanos que viven
      # dentro del JSON (JSON puro no soporta // comments). El consumidor
      # del schema (OpenAI) no debe verlas.
      def strip_meta(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), acc|
            next if k.to_s.start_with?("_")

            acc[k] = strip_meta(v)
          end
        when Array
          value.map { |v| strip_meta(v) }
        else
          value
        end
      end
    end
  end
end
