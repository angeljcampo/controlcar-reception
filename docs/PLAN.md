# Plan — Recepción Inteligente de Vehículos
## Control Car Fullstack Challenge

**Fecha:** 2026-05-29
**Deadline:** 2026-06-04 18:00
**Candidato:** Angel Campo
**Empresa:** Control Car (Control Group, Chile)

---

## 1. Contexto del desafío

Construir un mini-módulo para que talleres mecánicos registren Órdenes de Trabajo (OT) y obtengan un análisis automático del problema mediante un agente IA especializado en mecánica.

### Requerimientos mínimos del brief
- **Form de OT** con: patente, nombre cliente, kilometraje, motivo de ingreso, prioridad, fotos adjuntas
- **Análisis IA** del motivo de ingreso que devuelva: categoría, posibles fallas, prioridad sugerida, próximos pasos

### Criterios de evaluación (textual del brief)
- Capacidad de análisis
- Criterio técnico
- Estructura mental
- Pensamiento orientado a producto
- Capacidad de resolver problemas reales
- Uso inteligente de IA
- Simplicidad y claridad de la solución

> *"No buscamos una solución perfecta ni terminada a nivel producción."*

---

## 2. Estrategia general

Cumplir el brief mínimo es de alcance acotado. La diferencia entre un entregable promedio y uno excelente está en cuatro dimensiones donde se nota el criterio:

1. **Arquitectura de IA extensible** — agente + tools + providers desacoplados. Sumar una tool o un agente nuevo es agregar una clase + un registro, no reescribir.
2. **Uso moderno de IA** — tool_use nativo con schemas, multimodal con fotos, structured output forzado, observabilidad de cada corrida.
3. **Producto real** — historial por patente, confianza explícita, flag de revisión humana, citations al usar conocimiento externo.
4. **Documentación de evolución pensada** — lo que quedó fuera de scope está pensado y escrito en `docs/architecture.md`. Demuestra que el candidato razonó más allá del MVP.

---

## 3. Stack técnico

| Capa | Elección | Razón |
|---|---|---|
| Backend + frontend | Rails 8 + Hotwire + Tailwind | Stack productivo, dominio del candidato, listada en preferidos del brief |
| DB | PostgreSQL + extensión pgvector | RAG con búsqueda semántica sin servicios externos |
| Job queue | Sidekiq + Redis | Maduro, Web UI built-in en `/sidekiq` (observabilidad gratis), concurrency por queue, familiaridad del candidato |
| Storage | Active Storage + local dev / Render volume | Fotos OT + PDFs |
| LLM | OpenAI GPT-5 | Function calling con `strict: true`, structured outputs garantizados, multimodal nativo, prompt caching automático |
| Embeddings | OpenAI `text-embedding-3-small` (1536d) | $0.02/M tokens, rápido, mismo proveedor que LLM |
| Deploy | Render (web + Postgres + worker) | Setup simple Rails 8 + Postgres |

### Gemfile clave
```ruby
gem "ruby-openai"             # cliente oficial (LLM + embeddings)
gem "pdf-reader"              # extracción texto PDFs
gem "neighbor"                # pgvector adapter
gem "image_processing"        # variants de Active Storage
gem "tailwindcss-rails"
gem "sidekiq"                 # background jobs (requiere Redis)
```

---

## 4. Modelo de dominio

### Tablas

```ruby
Vehicle
  - patente: string (unique, normalized uppercase)
  - make, model, year (opcional, llenable manualmente)
  - timestamps

WorkOrder
  - vehicle_id (belongs_to)
  - customer_name: string
  - mileage: integer
  - reason: text                              # "motivo de ingreso"
  - priority: enum %i[low medium high critical]  # input del usuario
  - status: enum %i[draft analyzing analyzed in_review]
  - has_many_attached :photos
  - has_one :ai_analysis
  - has_many :agent_runs
  - timestamps

AiAnalysis                                    # snapshot estructurado actual
  - work_order_id
  - category: string                          # ej: "engine", "brakes"
  - possible_failures: jsonb
  - suggested_priority: string                # output IA, distinto del input
  - priority_reason: text
  - next_steps: jsonb
  - sources: jsonb                            # citations de PDFs
  - confidence: decimal(3,2)
  - requires_human_review: boolean
  - timestamps

# Convención: schema en inglés, contenido user-facing generado por la IA
# en español (system prompt instruye al modelo). UI traduce labels vía I18n.

AgentRun                                 # observabilidad
  - work_order_id
  - agent_name, model: string
  - status: enum %i[running succeeded failed]
  - input_tokens, output_tokens: integer
  - cost_cents: integer
  - latency_ms: integer
  - error_message: text
  - raw_log: jsonb                       # mensajes y tool calls completos
  - timestamps

KnowledgeDocument                        # PDFs subidos
  - title: string
  - has_one_attached :file
  - status: enum %i[pending processing ready failed]
  - total_chunks, total_pages: integer
  - embedding_tokens: integer            # auditoría de uso de embeddings
  - embedding_cost_cents: integer
  - error_message: text
  - has_many :knowledge_chunks, dependent: :destroy
  - timestamps

KnowledgeChunk
  - knowledge_document_id
  - content: text
  - page_number, chunk_index: integer
  - tokens_count: integer
  - embedding: vector(1536)
  - timestamps
  - INDEX ivfflat (embedding vector_cosine_ops)
```

### Multi-tenancy
**No** se implementa. Es un solo taller. Sin auth. Documentado como evolución.

---

## 5. Arquitectura de IA

### Estructura de carpetas

```
app/services/ai/
├── agents/
│   ├── base_agent.rb                    # tool loop, retries, logging
│   └── mechanic_diagnostic_agent.rb     # concreto: prompt + tools
├── tools/
│   ├── base_tool.rb                     # interfaz: name, description, schema, call
│   ├── tool_registry.rb                 # registro central
│   ├── get_vehicle_history_tool.rb
│   ├── search_knowledge_base_tool.rb
│   └── respond_with_analysis_tool.rb    # forced final output
├── providers/
│   ├── base_provider.rb                 # interfaz mínima
│   └── openai_provider.rb               # única implementación
├── ingestion/
│   ├── pdf_extractor.rb                 # PDF → array {text, page}
│   ├── chunker.rb                       # texto → chunks 800 tokens + overlap 150
│   └── batch_embedder.rb                # array de strings → array de embeddings
└── embeddings.rb                        # wrapper OpenAI embedding API
```

### BaseTool — el contrato

```ruby
class Ai::Tools::BaseTool
  class << self
    def tool_name = raise NotImplementedError
    def description = raise NotImplementedError
    def input_schema = raise NotImplementedError

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

  def initialize(context:)
    @context = context  # incluye work_order, current_user, etc.
  end

  def call(**args) = raise NotImplementedError
end
```

### ToolRegistry — dispatch central

```ruby
class Ai::Tools::ToolRegistry
  TOOLS = [
    Ai::Tools::GetVehicleHistory,
    Ai::Tools::SearchKnowledgeBase,
    Ai::Tools::RespondWithAnalysis
  ].freeze

  def self.schemas = TOOLS.map(&:to_openai)
  def self.find(name) = TOOLS.find { |t| t.tool_name == name }
end
```

Sumar tools en el futuro = una línea. Single Responsibility cumplido.

### BaseAgent — el loop

```ruby
class Ai::Agents::BaseAgent
  MAX_ITERATIONS = 5

  def initialize(provider:, system_prompt:, context:)
    @provider, @system_prompt, @context = provider, system_prompt, context
    @run = AgentRun.create!(work_order: context[:work_order],
                            agent_name: self.class.name,
                            model: provider.model,
                            status: :running)
  end

  def run(initial_message)
    messages = [{ role: "user", content: initial_message }]

    MAX_ITERATIONS.times do
      response = @provider.call(
        system: @system_prompt,
        messages: messages,
        tools: Ai::Tools::ToolRegistry.schemas
      )
      log_step(response)

      return finalize(response) if final_answer?(response)

      tool_results = execute_tools(response.tool_uses)
      messages << { role: "assistant", content: response.content }
      messages << { role: "user", content: tool_results }
    end

    raise "Max iterations exceeded"
  ensure
    @run.update!(status: @run.status == "running" ? :failed : @run.status)
  end
end
```

### Structured output forzado — el truco clave

En vez de "parsear JSON de texto libre", el modelo SIEMPRE termina llamando la tool `respond_with_analysis`. Con `strict: true` en la definición de la tool, OpenAI **garantiza** que la respuesta cumple el JSON Schema — sin campos faltantes, sin tipos incorrectos, sin parsing frágil.

```ruby
class Ai::Tools::RespondWithAnalysis < Ai::Tools::BaseTool
  def self.tool_name = "respond_with_analysis"
  def self.description = "Devuelve el análisis final estructurado. SIEMPRE llamar al final."
  def self.input_schema
    {
      type: "object",
      properties: {
        category: {
          type: "string",
          enum: %w[engine transmission brakes suspension electrical
                   cooling fuel exhaust tires body
                   diagnosis_needed other]
        },
        possible_failures: {
          type: "array",
          items: {
            type: "object",
            properties: {
              component: { type: "string" },
              probability: { type: "string", enum: %w[high medium low] },
              reasoning: { type: "string", description: "En español, para el usuario final" }
            },
            required: %w[component probability reasoning]
          }
        },
        priority: { type: "string", enum: %w[low medium high critical] },
        priority_reason: { type: "string", description: "En español" },
        next_steps: {
          type: "array",
          items: {
            type: "object",
            properties: {
              action: { type: "string", description: "En español" },
              required_tool: { type: "string", description: "En español" },
              order: { type: "integer", minimum: 1 }
            },
            required: %w[action order]
          }
        },
        sources: {
          type: "array",
          description: "Citar SOLO chunks que influyeron en el análisis.",
          items: {
            type: "object",
            properties: {
              document_title: { type: "string" },
              page: { type: "integer" },
              relevant_excerpt: { type: "string" }
            }
          }
        },
        confidence: { type: "number", minimum: 0, maximum: 1 },
        requires_human_review: { type: "boolean" },
        observations: { type: "string", description: "En español, opcional" }
      },
      required: %w[category possible_failures priority next_steps confidence requires_human_review]
    }
  end

  def call(**args)
    args  # la "ejecución" es devolver el output validado por schema
  end
end
```

### Tools concretas

**`GetVehicleHistory`** — recibe patente, devuelve OTs anteriores con sus análisis. Contexto real del taller para vehículos recurrentes.

**`SearchKnowledgeBase`** — recibe query en lenguaje natural, hace búsqueda vectorial en `KnowledgeChunk`. Top 5 chunks con título + página.

**`RespondWithAnalysis`** — descripto arriba.

### Provider

```ruby
class Ai::Providers::OpenAIProvider < Ai::Providers::BaseProvider
  MODEL = "gpt-5"

  def call(system:, messages:, tools:)
    response = client.chat.completions.create(
      parameters: {
        model: MODEL,
        messages: [{ role: "system", content: system }, *messages],
        tools: tools,
        tool_choice: "auto"
      }
    )
    parse_response(response)
  end

  def model = MODEL
end
```

Una sola implementación. La abstracción `BaseProvider` existe para que sumar Anthropic/Gemini/otro sea agregar una clase, no reescribir.

---

## 6. RAG con PDFs

### Pipeline de ingest

```
Usuario sube PDF en /knowledge
    ↓
KnowledgeDocument.create(status: :pending)
ActiveStorage attach
    ↓
IngestPdfJob.perform_later
    ↓
1. status → :processing
2. PdfExtractor: PDF → [{text, page}]
3. Chunker: 800 tokens con overlap 150, respetando párrafos
4. BatchEmbedder: batch de 100 strings → 100 embeddings
5. KnowledgeChunk.insert_all en transacción
6. status → :ready (o :failed si algo falló)
7. Persiste embedding_tokens y embedding_cost_cents
    ↓
Turbo Stream actualiza la UI
```

### Asunciones de scope
- PDFs born-digital con texto extraíble
- Se asume PDF "ideal" — no hay validaciones de tamaño/tipo/contenido en esta fase
- **No** hay vision fallback para escaneos/diagramas (documentado como future work)
- Documentos y chunks se pueden eliminar desde la UI (cascade vía `dependent: :destroy`)

### Tool de búsqueda

```ruby
class Ai::Tools::SearchKnowledgeBase < Ai::Tools::BaseTool
  def self.tool_name = "search_knowledge_base"
  def self.description = "Busca en los manuales subidos al taller. Devuelve chunks relevantes con cita."

  def self.input_schema
    {
      type: "object",
      properties: {
        query: { type: "string" },
        top_k: { type: "integer", minimum: 1, maximum: 10, default: 5 }
      },
      required: ["query"]
    }
  end

  def call(query:, top_k: 5)
    embedding = Ai::Embeddings.generate(query)
    KnowledgeChunk
      .joins(:knowledge_document)
      .where(knowledge_documents: { status: "ready" })
      .nearest_neighbors(:embedding, embedding, distance: "cosine")
      .limit(top_k)
      .map { |c| { content: c.content, source: c.knowledge_document.title, page: c.page_number } }
  end
end
```

`neighbor` gem aporta `.nearest_neighbors` sobre la columna `vector` con índice ivfflat.

### Citations en el output
El schema de `respond_with_analysis` incluye `sources`. Si el agente usó chunks de PDFs, los cita con `document_title` + `page` + `relevant_excerpt`. La UI muestra las citations como cards clickeables al PDF.

---

## 7. UX

### Páginas
- `/` → lista de OTs (cards con patente, cliente, status, prioridad, fecha)
- `/work_orders/new` → form de OT
- `/work_orders/:id` → detalle con análisis estructurado
- `/knowledge` → lista PDFs + upload + botón eliminar por documento
- `/agent_runs` → tabla de observabilidad (tokens, latencia, cost por corrida)
- `/sidekiq` → Sidekiq Web UI (status de jobs, retries, dead set)

### Flujo principal
1. Usuario crea OT con motivo + fotos
2. Submit → `WorkOrder.create(status: :analyzing)` + `AnalyzeWorkOrderJob.perform_later`
3. Redirect a `/work_orders/:id` con spinner "Analizando..."
4. Job ejecuta `MechanicDiagnosticAgent` (texto + fotos + tools)
5. Al terminar: Turbo Stream broadcast → renderiza el resultado estructurado
6. Resultado muestra:
   - Categoría (badge)
   - Lista de posibles fallas con probabilidad
   - Prioridad sugerida (badge, comparada con la input del usuario)
   - Próximos pasos numerados
   - Citations a PDFs (si las hubo)
   - Confianza (barra de progreso o porcentaje)
   - Banner "Revisión humana sugerida" si `confianza < 0.7`
   - Footer con latencia, tokens, costo, modelo
7. Botón "Re-analizar"

### Visual
- Tailwind utility classes, sin componentes custom complejos
- Paleta neutra (zinc/slate) + acento azul para botones primarios
- Badges de color por prioridad: verde/amarillo/naranja/rojo
- Cards con sombra sutil

---

## 8. Plan de implementación

El trabajo se organiza en fases incrementales. Cada fase deja la aplicación en un estado funcional y deployable.

### Fase 1 — Foundation

- [ ] Repo GitHub `controlcar-reception`
- [ ] `rails new controlcar-reception -d postgresql -c tailwind --skip-test`
- [ ] Gemfile con dependencias declaradas en §3
- [ ] Setup pgvector extension + `enable_extension :vector`
- [ ] Migrations: Vehicle, WorkOrder, AgentRun, KnowledgeDocument, KnowledgeChunk
- [ ] Modelos con asociaciones + enums
- [ ] Active Storage (`bin/rails active_storage:install`)
- [ ] Sidekiq setup:
  - [ ] Redis local (`brew install redis` + `brew services start redis`)
  - [ ] `config/sidekiq.yml` con concurrency y queues
  - [ ] `Procfile` con procesos `web` y `worker`
  - [ ] Mount Sidekiq Web UI en `/sidekiq` (routes.rb)
- [ ] Routes públicas (sin auth)
- [ ] `WorkOrdersController` con `new`, `create`, `show`, `index`
- [ ] Form con todos los campos + photo upload múltiple
- [ ] Vistas básicas con Tailwind
- [ ] Seed mínimo (2-3 OTs de ejemplo)
- [ ] Deploy inicial a Render
- [ ] Commit inicial + push

### Fase 2 — AI core

- [ ] `app/services/ai/` scaffold
- [ ] `BaseProvider` + `OpenAIProvider`
- [ ] `BaseTool` + `ToolRegistry`
- [ ] `BaseAgent` con tool loop + max iterations + logging
- [ ] Tool: `GetVehicleHistory`
- [ ] Tool: `RespondWithAnalysis`
- [ ] `MechanicDiagnosticAgent` con system prompt
- [ ] `AnalyzeWorkOrderJob` (Sidekiq, queue: `:ai`)
- [ ] Llamada multimodal (fotos + texto)
- [ ] `AgentRun` snapshot al final (tokens, latencia, cost)
- [ ] Vista del resultado estructurado con badges, listas, confianza
- [ ] Turbo Stream broadcast al completarse
- [ ] Botón "Re-analizar"

### Fase 3 — RAG con PDFs

- [ ] `KnowledgeDocument` + Active Storage attached (sin validaciones, asume PDFs ideales)
- [ ] `has_many :knowledge_chunks, dependent: :destroy` para borrado en cascada
- [ ] `Ai::Ingestion::PdfExtractor` (pdf-reader, page-by-page)
- [ ] `Ai::Ingestion::Chunker` (800 tokens, overlap 150, split por párrafo cuando posible)
- [ ] `Ai::Embeddings` (OpenAI text-embedding-3-small)
- [ ] `Ai::Ingestion::BatchEmbedder` (batch de 100)
- [ ] `IngestPdfJob` orquestando todo + status updates
- [ ] Controller + vistas de `/knowledge` (lista, upload, delete con confirmación)
- [ ] Endpoint DELETE que purga el archivo de Active Storage y borra el documento (chunks caen por cascade)
- [ ] Status badges con Turbo Stream
- [ ] Tool: `SearchKnowledgeBase`
- [ ] Registrar en `ToolRegistry`
- [ ] Actualizar `respond_with_analysis` schema con `sources`
- [ ] UI de citations en el resultado de la OT
- [ ] Test manual con 2-3 PDFs reales (NHTSA, manuales públicos)

### Fase 4 — Cierre

- [ ] Tests críticos:
  - [ ] `MechanicDiagnosticAgent` loop con tool calls mockeadas
  - [ ] `SearchKnowledgeBase` retorna chunks ordenados por similitud
  - [ ] `RespondWithAnalysis` valida schema correctamente
- [ ] README completo:
  - [ ] Descripción
  - [ ] Stack
  - [ ] Setup local (envs, comandos)
  - [ ] Variables de entorno requeridas
  - [ ] Decisiones técnicas destacadas
  - [ ] Link a la URL deployed
- [ ] `docs/architecture.md`:
  - [ ] Decisiones de arquitectura
  - [ ] Sección "Próximos pasos pensados" (ver §9)
- [ ] Video demo de 90 segundos:
  - [ ] Crear OT
  - [ ] Ver análisis
  - [ ] Subir PDF
  - [ ] Crear otra OT y ver citations
  - [ ] Mostrar observabilidad
- [ ] Deploy final + verificación
- [ ] Push final + email de entrega

### Priorización de scope

Si por alguna razón hay que reducir alcance, el orden de prioridad de menor a mayor importancia es:

| Pieza | Por qué se puede sacrificar primero |
|---|---|
| Deploy en Render | El brief acepta entrega local con instrucciones claras |
| Multimodal (fotos al agente) | El análisis sigue siendo útil solo con texto |
| Citations en UI | La tool sigue buscando y el agente sigue usando contenido |
| UI de upload de PDFs | Se pueden seedear PDFs por código |
| `GetVehicleHistory` tool | Las otras dos tools alcanzan para demostrar el patrón |

El núcleo no sacrificable: form de OT + framework de agentes y tools + análisis estructurado + tool `respond_with_analysis` con schema forzado.

---

## 9. Fuera de scope (documentado en `docs/architecture.md`)

Estas piezas están pensadas y diseñadas pero no implementadas en el alcance actual:

### Vision fallback para PDFs escaneados
- Detección de páginas con poco texto
- Render de página a PNG con `pdftoppm`
- Batch de 5 páginas por call al modelo vision (GPT-5 multimodal)
- Concurrency cap por job
- Mantener idempotencia por página

### Streaming token-a-token
- Server-Sent Events o ActionCable
- Tool calls intercaladas con streaming de texto
- UX de "el agente está pensando..." con texto apareciendo en vivo

### Vector store swappable
- Interfaz `Ai::VectorStores::Base`
- Implementaciones: pgvector (actual) + Pinecone/Qdrant para escala
- Decisión de migración: > 100k vectores o multi-tenant masivo

### Multi-provider LLM
- Interfaz `Ai::Providers::BaseProvider` ya existe
- Sumar `AnthropicProvider` o `GeminiProvider` es una clase

### Más tools del agente
- `LookupDtcCode` — tabla de códigos OBD-II
- `EstimateRepairTime` — basado en historial del taller
- `SuggestSimilarOTs` — fuzzy match de motivos parecidos

### Autenticación y multi-tenancy
- Devise + scoping por taller
- Roles (recepcionista, mecánico, admin)

### Observabilidad ampliada
- Dashboard con gráficos de costo por día, latencia p95, tasa de reanálisis
- Alertas por degradación

---

## 10. Talking points para la entrevista

### "¿Por qué Rails y no Angular/Go?"
> Dominio del stack, productividad alta con Hotwire para Turbo Streams sin SPA. Tailwind por velocidad de UI. El brief listaba Rails como opción preferida.

### "¿Por qué Sidekiq y no Solid Queue?"
> Familiaridad. Sidekiq es maduro, con Web UI built-in que suma observabilidad gratis. Solid Queue (Rails 8 default) sería más simple en infra al no requerir Redis, pero con plazo corto fui con la herramienta que mejor conozco para minimizar fricción.

### "¿Por qué OpenAI GPT-5?"
> Function calling con `strict: true` garantiza output que cumple el JSON Schema a nivel API (sin parsing frágil). Multimodal nativo (procesa fotos del vehículo). Prompt caching automático en prefijos repetidos. Mismo proveedor para LLM y embeddings simplifica credenciales. La decisión entre OpenAI y Anthropic Claude es casi indiferente técnicamente para este caso — ambos cubren los requisitos; primó disponibilidad de credenciales.

### "¿Por qué structured output forzado vía tool?"
> Robustez. El modelo no puede "olvidarse" de devolver un campo o devolver un JSON malformado — la API valida el schema. Es la diferencia entre IA-truco (parsing frágil) e IA-producto (contrato explícito).

### "¿Por qué no Pinecone para vector search?"
> Para ~500 chunks de demo, pgvector local es estrictamente mejor: latencia <5ms (vs 80-150ms de red), cero infra extra, joins con el resto del schema. Pinecone justifica más allá de ~100k vectores o multi-region. Migrar es swappear una clase gracias a la abstracción del vector store.

### "¿Qué harías con más tiempo?"
> Implementaría vision fallback para PDFs escaneados (planeado en architecture.md), streaming token-a-token con Turbo, dashboard de observabilidad con gráficos, auth multi-taller con Devise, y más tools como lookup de códigos DTC y estimación de tiempo de reparación.

### "¿Cómo lo usaste a Claude Code durante el desarrollo?"
> Para iterar el diseño del plan, generar boilerplate (migrations, vistas, tests), debugging guiado, y revisar la arquitectura. Las decisiones de producto y arquitectura las tomé yo; Claude Code aceleró la implementación.

---

## 11. Mapeo a criterios de evaluación

| Criterio del brief | Cómo se demuestra |
|---|---|
| **Capacidad de análisis** | Lectura del brief + scope expandido inteligente (historial, multimodal, confianza, observabilidad) |
| **Criterio técnico** | Arquitectura desacoplada (agent/tool/provider), structured outputs nativos, pgvector en vez de servicio externo para 500 chunks |
| **Estructura mental** | Modelo de dominio normalizado, separación service/agent/tool/provider/ingestion, observabilidad en su propio modelo |
| **Pensamiento de producto** | Historial por patente, confianza explícita + revisión humana, citations, re-analizar, multimodal con fotos reales |
| **Resolver problemas reales** | El análisis se basa en data subida por el taller, no en seed inventado. Citations dan trazabilidad. |
| **Uso inteligente de IA** | Function calling con `strict: true`, multimodal, prompt caching, structured output garantizado por schema, observabilidad de cada corrida |
| **Simplicidad y claridad** | Un único README claro, una sola página principal, sin auth ni multi-tenant, sin features inventadas |

---

## 12. Variables de entorno requeridas

```bash
# .env.example
OPENAI_API_KEY=               # LLM + embeddings
DATABASE_URL=postgres://...
REDIS_URL=redis://localhost:6379/0   # Sidekiq
ACTIVE_STORAGE_SERVICE=local  # o "amazon" en prod
RAILS_MASTER_KEY=
```

---

## 13. Checklist de entrega final

- [ ] Repo público en GitHub con commits limpios
- [ ] URL de la app deployed funcionando
- [ ] README con setup local + URL deployed
- [ ] `docs/architecture.md` con decisiones + future work
- [ ] Video demo de 90s (YouTube unlisted o Loom)
- [ ] Email al equipo de Control Car con: link repo, link app, link video
- [ ] CC a sebastian@controlgroup.cl
