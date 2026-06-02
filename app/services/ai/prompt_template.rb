# frozen_string_literal: true

# Carga prompt templates desde `app/prompts/` y los renderiza vía ERB
# si tienen `locals:` para interpolar variables.
#
# Por qué archivos separados:
#   - Producto / QA / mecánicos expertos pueden editar prompts sin tocar Ruby.
#   - Diff de Git separa "tono del agente" de "lógica de control".
#   - Versionable independiente (un día querés A/B testear prompts → kit listo).
#   - El system prompt del agente tiene ~80 líneas; embeberlo en un heredoc
#     viola la regla "código y datos en archivos separados".
#
# Convenciones:
#   - Templates viven en `app/prompts/<namespace>/<name>.md.erb`
#   - Se referencian por nombre relativo: `"agents/mechanic_diagnostic"`
#   - Si no necesita interpolación, podés usar `.md` (no `.erb`) — el loader
#     intenta `.md.erb` primero y cae a `.md` después.
#
# Performance:
#   - Cache en memoria por path, invalidado en development (auto-reload al
#     editar). En production carga 1 vez y queda warm.
#
# Uso:
#   Ai::PromptTemplate.load("agents/mechanic_diagnostic")
#   Ai::PromptTemplate.load("ingestion/spanish_translator", locals: { batch_size: 10 })
module Ai
  class PromptTemplate
    class NotFound < StandardError; end

    PROMPTS_DIR = Rails.root.join("app/prompts").freeze

    @cache = {}
    @mutex = Mutex.new

    class << self
      attr_reader :cache

      def load(name, locals: {})
        path = resolve_path(name)
        raw  = read_with_cache(path)

        return raw if locals.empty?

        ERB.new(raw, trim_mode: "-").result_with_hash(locals)
      end

      # Bypassa el cache (útil para tests / scripts que editan prompts).
      def reload!
        @mutex.synchronize { @cache.clear }
      end

      private

      def resolve_path(name)
        candidates = [
          PROMPTS_DIR.join("#{name}.md.erb"),
          PROMPTS_DIR.join("#{name}.md"),
          PROMPTS_DIR.join("#{name}.txt.erb"),
          PROMPTS_DIR.join("#{name}.txt")
        ]

        found = candidates.find { |p| File.exist?(p) }
        raise NotFound, "Prompt template '#{name}' no encontrado. Buscado en: #{candidates.join(', ')}" if found.nil?

        found
      end

      # En dev re-lee el archivo cada vez (auto-reload al editar el prompt).
      # En prod cachea — el filesystem read es ~50µs pero suma cuando el
      # agente corre cientos de veces por minuto.
      def read_with_cache(path)
        if Rails.env.development? || Rails.env.test?
          File.read(path)
        else
          @mutex.synchronize do
            @cache[path] ||= File.read(path)
          end
        end
      end
    end
  end
end
