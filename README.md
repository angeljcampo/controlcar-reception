# Recepción Inteligente de Vehículos

**Mini-módulo para que talleres mecánicos registren Órdenes de Trabajo (OT) y obtengan un análisis automático del problema mediante un agente IA especializado en mecánica, con RAG sobre manuales técnicos reales.**

> Control Car Fullstack Challenge · Ruby on Rails 8.1 · Hotwire · PostgreSQL + pgvector · Sidekiq · OpenAI GPT-5

---

## 🚀 Probar la app sin instalar nada

**Demo en vivo:** **<https://controlcar-web.onrender.com>**

Si preferís evaluar el flujo directamente sin clonar, abrí ese link. La primera carga puede tardar 30-60s mientras Render despierta el container (plan free). La knowledge base se carga desde el botón **"Cargar manuales precargados"** en `/knowledge` la primera vez — ~10 min con traducción, ~1 min sin. Una vez seedeada, el RAG funciona en cualquier OT que crees.

Si querés bajar el repo y correrlo local, seguí el [Quick start](#quick-start) más abajo.

---

## Tabla de contenidos

1. [Contexto del challenge](#contexto-del-challenge)
2. [Qué hace el sistema](#qué-hace-el-sistema)
3. [Stack técnico](#stack-técnico)
4. [Quick start](#quick-start)
5. [Variables de entorno](#variables-de-entorno)
6. [Arquitectura de IA](#arquitectura-de-ia)
7. [Modelo de dominio](#modelo-de-dominio)
8. [Estructura del proyecto](#estructura-del-proyecto)
9. [Observabilidad](#observabilidad)
10. [Estado del proyecto](#estado-del-proyecto)
11. [Cómo evaluar este entregable](#cómo-evaluar-este-entregable)
12. [Documentación detallada](#documentación-detallada)
13. [Troubleshooting](#troubleshooting)
14. [Decisiones técnicas destacadas](#decisiones-técnicas-destacadas)

> Tests: `bundle exec rspec` → 171 specs, ~5s. Cobertura detallada en la sección [Tests](#tests).

---

## Contexto del challenge

Entrega para el **Desafío Fullstack de Control Car** (Control Group, Chile). El brief pide un módulo donde un taller pueda:

1. Registrar una OT con patente, cliente, kilometraje, motivo de ingreso, prioridad y fotos.
2. Recibir un **análisis IA estructurado** del motivo: categoría, posibles fallas, prioridad sugerida y próximos pasos.

El alcance del brief es acotado a propósito. La diferencia entre un entregable mínimo y uno excelente se juega en cuatro dimensiones donde se nota el criterio:

- **Arquitectura de IA extensible** — sumar una tool, un agente o un provider nuevo es agregar una clase + un registro, no reescribir.
- **Uso moderno de IA** — `tool_use` nativo con schemas, multimodal con fotos, structured output forzado por schema, observabilidad por corrida.
- **Pensamiento de producto** — historial por patente, confianza explícita + flag de revisión humana, citations a manuales (Fase 3), re-analizar.
- **Evolución pensada** — lo que quedó fuera del alcance está documentado en [docs/PLAN.md](docs/PLAN.md), no improvisado.

---

## Qué hace el sistema

```
1. El recepcionista crea una OT desde /work_orders/new
   (patente, cliente, kilometraje, motivo, fotos opcionales).
   La prioridad NO se le pide al usuario — la decide el LLM.
                  ↓
2. WorkOrders::Create resuelve o crea el Vehicle por patente,
   crea la WorkOrder y encola AnalyzeWorkOrderJob (Sidekiq).
                  ↓
3. El job ejecuta MechanicDiagnosticAgent — un loop adversarial:
   a. get_vehicle_history — historial del vehículo para detectar patrones
   b. search_knowledge_base — RAG híbrido (vector + tsvector) sobre
      manuales técnicos (DTC OBD-II Ford 2007, Denton ES, PCS).
      El LLM puede llamarla N veces refinando queries.
   c. respond_with_analysis — structured output forzado por JSON schema.
                  ↓
4. Cuando termina, Turbo Stream broadcast al show de la OT:
     - Categoría + prioridad (decisión del LLM)
     - Posibles fallas rankeadas
     - Próximos pasos numerados
     - Confidence calibrada (anchors + ejemplos en el system prompt)
     - Banner "Revisión humana" solo si la acción requiere experto
       (independiente del confidence numérico)
     - Fuentes citadas con código DTC + página + excerpt literal
     - Panel de retrieval observability: queries del LLM, scores,
       latencia por búsqueda
                  ↓
5. Botón "Re-analizar" encola un nuevo run. Cada intento queda
   registrado en /work_orders/:id/agent_runs.
```

---

## Stack técnico

| Capa | Tecnología | Notas |
|---|---|---|
| Lenguaje | Ruby 3.3+ | |
| Framework | Ruby on Rails 8.1 | |
| Frontend | Hotwire (Turbo + Stimulus) | photo upload con previews via Stimulus controller |
| Estilos | TailwindCSS + tema "Garage" custom | tokens en application.css scope `.wof` |
| Base de datos | PostgreSQL 14+ con `vector` (pgvector) | HNSW index para embeddings, GIN para tsvector |
| Background jobs | Sidekiq (dev) + `:async` adapter (prod Render free) | |
| Cache / Cable | Solid Cache + Redis (ActionCable broadcasts) | |
| Storage | Active Storage: Disk (dev) + S3 (prod) | fotos OT + PDFs de la KB |
| LLM | OpenAI GPT-5 vía `ruby-openai` | function calling con `strict: true` |
| Translator | OpenAI `gpt-4o-mini` (más barato/rápido) | preserva DTC codes + siglas literal |
| Embeddings | OpenAI `text-embedding-3-small` (1536d) | $0.02/1M tokens |
| Vector search | `neighbor` gem sobre pgvector | cosine distance, HNSW |
| Keyword search | Postgres tsvector + GIN | `setweight A` en breadcrumb |
| Retrieval fusion | **Reciprocal Rank Fusion** (Cormack et al. 2009) | K=60, sin score normalization |
| PDF parsing | `pdf-reader` gem | born-digital, no OCR (future work) |
| Tests | RSpec 7.1 + WebMock | 171 specs, ~5s run |
| Config | `figaro` (`config/application.yml`) | secrets fuera de git |
| Deploy | Render Blueprint (`render.yaml`) | Postgres + Redis + Web container |

### ¿Por qué este stack?

- **Rails 8.1 + Hotwire** — Turbo Streams permite que el análisis aparezca en vivo cuando termina el job, sin montar una SPA aparte. Menos JavaScript, más velocidad.
- **Sidekiq sobre Solid Queue** — Sidekiq tiene Web UI built-in en `/sidekiq` que da observabilidad de jobs gratis. Decisión consciente de cambiar el default de Rails 8 por familiaridad y por la UI.
- **pgvector en lugar de Pinecone/Weaviate** — Para cientos/miles de chunks de manuales de un taller, pgvector local tiene latencia <5ms y cero infra extra. La capa `neighbor` permite swappear el vector store en el futuro.
- **Function calling con `strict: true`** — El modelo no puede "olvidar" un campo o devolver JSON malformado. La API garantiza que el output cumple el JSON Schema. Es la diferencia entre IA-truco y IA-producto.

Decisiones ampliadas en [docs/PLAN.md](docs/PLAN.md) (§3 Stack + §10 Talking points).

---

## Quick start

### Requisitos previos

| Herramienta | Versión | Cómo |
|---|---|---|
| Ruby | 3.3+ | `rbenv install -s "$(cat .ruby-version)"` |
| PostgreSQL | 14+ con extensión `vector` | macOS: `brew install postgresql@14 pgvector` |
| Redis | cualquiera | macOS: `brew install redis && brew services start redis` |
| Node.js | 18+ | Para Tailwind |
| Foreman | — | Lo instala `bin/dev` si no está |

### Instalación

```bash
# 1. Clonar e instalar gems
git clone <repo-url> controlcar-reception
cd controlcar-reception
bundle install

# 2. Configurar secrets (figaro lee config/application.yml — está en .gitignore)
$EDITOR config/application.yml      # pegar OPENAI_API_KEY (ver sección abajo)

# 3. Base de datos: crear, habilitar pgvector, migrar, seedear
bin/rails db:create
bin/rails db:migrate                # habilita pgvector y crea tablas
SKIP_KB_TRANSLATE=1 bin/rails db:seed
#   → 3 OTs demo + 3 PDFs precargados en la KB (sin traducción al
#     español, rápido ~30s). Para ingest con traducción ES (mejor
#     recall semántico, ~10 min y ~$0.05 de OpenAI):
#         bin/rails db:seed
#   También podés saltarte la KB y disparar el ingest después
#   desde el botón "Cargar manuales precargados" en /knowledge:
#         SKIP_KB_SEED=1 bin/rails db:seed

# 4. Asegurar Redis corriendo
brew services start redis           # macOS
# o: redis-server

# 5. Levantar todo en paralelo (web + tailwind watcher + sidekiq worker)
bin/dev
```

Abre `http://localhost:3000`. La home es el listado de OTs.

> **Importante:** usar `bin/dev` (no `bin/rails server`). `bin/dev` levanta vía Foreman tres procesos definidos en `Procfile.dev`:
> - `web` → `bin/rails server`
> - `css` → `bin/rails tailwindcss:watch`
> - `worker` → `bundle exec sidekiq -C config/sidekiq.yml`
>
> Sin el worker no se ejecutan los análisis. Sin el watcher no se recompilan los estilos.

### Probar el flujo end-to-end

1. Entrar a `/work_orders` — verás 3 OTs demo del seed con análisis IA real.
2. Click en una OT → ver el análisis estructurado, con badges, anillo de confianza, fuentes citadas con código DTC y panel de búsquedas RAG.
3. Click en el icono de "Runs" → modal con el timeline de corridas del agente.
4. Click en **Re-analizar** → spinner, Turbo Stream actualiza la vista cuando el job termina.
5. Crear una OT nueva en `/work_orders/new` con un motivo realista (ej: "tirita en ralentí y se prende el check engine") y, opcionalmente, fotos.
6. Entrar a `/knowledge` para ver los 3 PDFs precargados con stats (chunks, páginas, costo de embeddings).
7. Inspeccionar la cola de Sidekiq en `/sidekiq`.

### Tests

```bash
bundle exec rspec
# 171 examples, 0 failures, ~5s
```

171 specs cubren orchestration (BaseAgent tool loop, jobs, request flow), math frágil (Reciprocal Rank Fusion, embedding costs), parsing (chunkers, schema loader), e idempotencia (KnowledgeBaseBootstrap). WebMock bloquea HTTP real — los specs nunca llaman a OpenAI por accidente.

Cobertura organizada por capa:

| Capa | Specs | Foco |
|---|---|---|
| Services AI/Ingestion | 40 | Chunkers, translator, embedder, extractor |
| Services AI/Tools | 28 | RRF math, schemas strict, vehicle history |
| Services AI/Agents | 10 | BaseAgent tool loop, MAX_ITERATIONS, agent_run injection |
| Services other | 18 | WorkOrders::Create, KnowledgeBaseBootstrap idempotente |
| Models + Helpers | 25 | Priority nullable, ai_total_tokens COALESCE, retrieval cascade |
| Jobs | 20 | Analyze + Ingest pipeline + discard_on RecordNotFound |
| Requests | 26 | CRUD + reanalyze + cancel + bootstrap |
| Loaders | 5 | SchemaTemplate `_meta` strip |

---

## Variables de entorno

`figaro` carga las variables desde `config/application.yml` (gitignoreado). Crear/editar el archivo con:

```yaml
# config/application.yml — NO commitear
OPENAI_API_KEY: sk-proj-...     # requerido para que el agente funcione
```

Otras variables del entorno Rails que pueden ser necesarias en producción:

| Variable | Cuándo | Descripción |
|---|---|---|
| `OPENAI_API_KEY` | Siempre | Clave de OpenAI (LLM + embeddings) |
| `DATABASE_URL` | Producción | URL completa de Postgres |
| `REDIS_URL` | Producción | URL de Redis para Sidekiq (default: `redis://localhost:6379/0`) |
| `RAILS_MASTER_KEY` | Producción | Necesaria si se usan `credentials.yml.enc` |
| `RAILS_ENV` | Producción | `production` |

---

## Arquitectura de IA

El corazón del entregable. Está pensado para que **sumar capacidades sea agregar archivos, no reescribir**.

### Capas

```
app/services/ai/
├── agents/
│   ├── base_agent.rb                    # tool loop, retries, observabilidad
│   └── mechanic_diagnostic_agent.rb     # system prompt + tools concretas
├── tools/
│   ├── base_tool.rb                     # interfaz: name, description, schema, call
│   ├── tool_registry.rb                 # registro central
│   ├── get_vehicle_history.rb           # historial por patente
│   └── respond_with_analysis.rb         # tool de output forzado por schema
├── providers/
│   ├── base_provider.rb                 # interfaz mínima
│   └── openai_provider.rb               # única implementación hoy
├── responses/
│   └── llm_response.rb                  # response object normalizado
└── cost_calculator.rb                   # tokens → USD por modelo
```

### El truco clave: structured output forzado

En vez de parsear JSON de texto libre (frágil), el agente **siempre** termina llamando la tool `respond_with_analysis`. Con `strict: true` en la definición de la tool, OpenAI **garantiza** a nivel API que la respuesta cumple el JSON Schema:

- Sin campos faltantes
- Sin tipos incorrectos
- Sin "casi JSON pero con un trailing comma"

Esto convierte la salida de la IA en un **contrato explícito**, no en una promesa.

Schema de `respond_with_analysis` (resumido):

```ruby
{
  category: enum(engine|brakes|electrical|...),
  possible_failures: [{component, probability, reasoning}],
  priority: enum(low|medium|high|critical),
  priority_reason: string,
  next_steps: [{action, required_tool?, order}],
  sources: [{document_title, page, relevant_excerpt}],   # citations (Fase 3)
  confidence: 0..1,
  requires_human_review: bool,
  observations: string?
}
```

### Multimodal

Las fotos adjuntas a la OT se pasan al modelo como parte del mensaje multimodal. El agente puede mencionar lo que ve en las imágenes para reforzar el diagnóstico.

### Loop del agente

`Ai::Agents::BaseAgent` ejecuta hasta `MAX_ITERATIONS` rondas:

1. Llama al provider con `system_prompt`, historial de mensajes y schemas de todas las tools registradas.
2. Si el modelo pide ejecutar tools → las ejecuta vía `ToolRegistry`, agrega los resultados al historial, vuelve al paso 1.
3. Si el modelo invoca `respond_with_analysis` → ese es el "final answer", se persiste en `AiAnalysis` y termina.
4. Cada iteración se loggea en el `AgentRun` (tokens, tool calls, raw log para debugging).

---

## Modelo de dominio

```
Vehicle (1) ─── (N) WorkOrder (1) ─── (1) AiAnalysis
                       │
                       ├─ (N) AgentRun ─── (N) RetrievalRun   ← observabilidad RAG
                       └─ photos (Active Storage, múltiples)

KnowledgeDocument (1) ─── (N) KnowledgeChunk
                          ├─ embedding: vector(1536), HNSW cosine
                          ├─ content_tsv: tsvector (generated, GIN index)
                          ├─ breadcrumb: text (boosted en ts_rank)
                          └─ metadata: jsonb (dtc_code, original_content_en, ...)
```

### Tablas implementadas

| Tabla | Rol |
|---|---|
| `vehicles` | Patente única normalizada (uppercase). Reutilizable entre OTs. |
| `work_orders` | Una OT por ingreso. Status: `draft → analyzing → analyzed`. Priority **nullable** (autoridad del LLM). |
| `ai_analyses` | Snapshot estructurado del análisis. 1:1 con WorkOrder. Incluye `sources[]` con dtc_code. |
| `agent_runs` | Una fila por intento de análisis. Tokens, costo, latencia, raw log con tool calls. |
| `retrieval_runs` | Snapshot de cada query del LLM a search_knowledge_base. Query, top_k, results con scores, threshold_passed, latency, embedding_tokens. **Talking point de observabilidad**. |
| `knowledge_documents` | PDFs ingestados. Enum `chunking_strategy` (structured_dtc / token_window). Status pipeline. |
| `knowledge_chunks` | Embeddings 1536d (HNSW) + tsvector generado (con setweight A en breadcrumb) para hybrid retrieval. |

### Multi-tenancy

**No implementado** — el alcance es un solo taller, sin auth. Documentado como evolución en [docs/architecture.md](docs/architecture.md).

---

## Estructura del proyecto

```
controlcar-reception/
├── app/
│   ├── controllers/
│   │   ├── work_orders_controller.rb            index, new, create, show, reanalyze, cancel
│   │   ├── knowledge_documents_controller.rb    index, create, destroy, bootstrap (Fase 3)
│   │   └── agent_runs_controller.rb             index (lazy Turbo Frame)
│   ├── models/
│   │   ├── vehicle.rb                           patente normalizada uppercase
│   │   ├── work_order.rb                        status enum + broadcast, priority nullable
│   │   ├── ai_analysis.rb                       snapshot estructurado con sources[]
│   │   ├── agent_run.rb                         observabilidad LLM, has_many retrieval_runs
│   │   ├── retrieval_run.rb                     snapshot por query RAG (Fase 3)
│   │   ├── knowledge_document.rb                enum chunking_strategy
│   │   └── knowledge_chunk.rb                   vector(1536) + tsvector + breadcrumb + metadata
│   ├── services/
│   │   ├── ai/
│   │   │   ├── agents/                          BaseAgent + MechanicDiagnosticAgent
│   │   │   ├── tools/                           SearchKnowledgeBase, GetVehicleHistory,
│   │   │   │                                    RespondWithAnalysis, ToolRegistry
│   │   │   ├── providers/                       OpenAIProvider
│   │   │   ├── ingestion/                       PdfExtractor, 2 Chunkers, Translator, Embedder
│   │   │   ├── prompt_template.rb               loader de prompts desde app/prompts/
│   │   │   ├── schema_template.rb               loader de JSON schemas desde config/schemas/
│   │   │   └── cost_calculator.rb
│   │   ├── work_orders/create.rb
│   │   └── knowledge_base_bootstrap.rb          carga PDFs precargados (UI + db:seed)
│   ├── prompts/                                 ← prompts del LLM en archivos editables
│   │   ├── agents/mechanic_diagnostic.md        ~80 líneas con calibración + ejemplos
│   │   └── ingestion/spanish_translator.md
│   ├── jobs/
│   │   ├── analyze_work_order_job.rb            Sidekiq, queue :ai
│   │   └── ingest_pdf_job.rb                    pipeline RAG, auto-fallback
│   ├── views/
│   │   ├── work_orders/                         + _retrieval_runs.html.erb (panel observabilidad)
│   │   └── knowledge_documents/                 index + _form + _row con Turbo Stream
│   └── javascript/controllers/                  Stimulus (photo upload, modals)
├── config/
│   ├── routes.rb                                + /knowledge + /knowledge/bootstrap
│   ├── schemas/                                 ← JSON Schemas portables
│   │   └── respond_with_analysis.json
│   ├── sidekiq.yml
│   └── database.yml                             Postgres + extensión vector
├── db/
│   ├── migrate/                                 vector ext, fases 1-3, priority nullable
│   ├── schema.rb
│   ├── seeds.rb                                 3 OTs demo + bootstrap KB (síncrono)
│   └── seed_pdfs/                               3 PDFs precargados en el repo
├── spec/                                        171 specs, ~5s run
├── docs/
│   ├── PLAN.md                                  plan original del challenge
│   └── architecture.md                          decisiones Fase 3 + future work
├── render.yaml                                  Blueprint deploy (Postgres + Redis + Web)
├── Procfile.dev                                 web + css + worker
└── bin/dev
```

### Rutas principales

| Método | Path | Acción |
|---|---|---|
| GET | `/` | Listado de OTs (root) |
| GET | `/work_orders/new` | Form de nueva OT (sin campo priority — LLM autoridad) |
| POST | `/work_orders` | Crea OT + encola análisis |
| GET | `/work_orders/:id` | Detalle con análisis + sources + panel retrieval |
| POST | `/work_orders/:id/reanalyze` | Encola nuevo análisis |
| POST | `/work_orders/:id/cancel` | Cancela el análisis en curso |
| GET | `/work_orders/:id/agent_runs` | Timeline de corridas (Turbo Frame) |
| GET | `/knowledge` | Admin de la KB: stats, lista de PDFs, upload |
| POST | `/knowledge` | Subir PDF manual (form con selector de chunking_strategy) |
| POST | `/knowledge/bootstrap` | Cargar los 3 PDFs precargados del repo (deploy sin shell) |
| DELETE | `/knowledge/:id` | Eliminar doc + sus chunks (cascade) |
| — | `/sidekiq` | Sidekiq Web UI (solo dev — en prod los jobs van async in-proc) |

---

## Observabilidad

Cada corrida del agente persiste un `AgentRun` con:

- `agent_name`, `model` (`gpt-5`)
- `status` (`running` / `succeeded` / `failed`)
- `input_tokens`, `output_tokens`
- `cost_cents` (calculado por `Ai::CostCalculator`)
- `latency_ms`
- `error_message` (si falla)
- `raw_log` (jsonb) — mensajes y tool calls completos para debugging

Visible en la UI: cada OT muestra los stats de su análisis actual + modal con timeline de todos los runs. La cola de Sidekiq con jobs, retries y dead set vive en `/sidekiq`.

---

## Estado del proyecto

```
Fase 1   [████████████████████]  100%   Foundation (modelos, form, Sidekiq, deploy-ready)
Fase 2   [████████████████████]  100%   AI core (agent + tools + provider + observabilidad)
Fase 3   [████████████████████]  100%   RAG (hybrid retrieval, ingest pipeline, citations, observability)
Fase 4   [████████████████████]  100%   Tests RSpec (171 specs) + deploy a Render
```

### Implementado

**Fase 1-2 — Foundation + AI core**

- Form de OT con todos los campos del brief + upload múltiple de fotos (con preview thumbnails y remove individual via Stimulus controller)
- Vehicle reutilizable por patente normalizada
- `MechanicDiagnosticAgent` con tool loop y observabilidad por corrida
- Tools: `GetVehicleHistory` + `RespondWithAnalysis` (structured output forzado)
- Llamada multimodal (texto + fotos)
- `AnalyzeWorkOrderJob` (Sidekiq, queue `:ai`)
- Turbo Stream broadcast del análisis cuando termina el job + polling fallback si Cable se cae
- UI con badges, anillo de confianza, banner de revisión humana, stats de la corrida
- Panel de Agent Runs como modal nativo `<dialog>` con timeline
- Botón "Re-analizar" con transición animada
- Seeds con 3 OTs demo realistas

**Fase 3 — RAG (Retrieval-Augmented Generation)**

- 3 manuales técnicos seedeados en la KB: catálogo DTC OBD-II Ford 2007 (~330 chunks), Denton "Diagnóstico Avanzado" en español nativo (31 chunks), PCS Transmission Codes (4 chunks)
- 2 estrategias de chunking según el documento: `structured_dtc` (1 chunk = 1 código P0xxx) y `token_window` (~800 tokens con overlap, paragraph-aware) — el sistema **auto-falla** a token_window cuando structured_dtc no detecta formato
- Ingest pipeline completo: `PdfExtractor` → `Chunker` → `SpanishTranslator` (opcional, preserva DTC codes + siglas literal) → `BatchEmbedder` → `KnowledgeChunk.insert_all`
- Hybrid retrieval con **Reciprocal Rank Fusion** (Cormack et al., 2009): combina vector search (pgvector cosine) + keyword search (tsvector con setweight A en breadcrumb para boostear códigos DTC exactos). Sin score normalization.
- `SearchKnowledgeBase` tool registrada — el agente puede llamarla N veces con queries distintas hasta acumular evidencia
- Schema del análisis incluye `sources[]` con `dtc_code` (badge prominente en UI), `document_title`, `page`, `relevant_excerpt` literal
- **Threshold-aware behavior**: si todos los matches tienen distancia > 0.65, el LLM baja confidence + considera `requires_human_review: true` y no cita fuentes débiles
- Calibración del system prompt con escala explícita 0-1 + 4 anchors + ejemplos few-shot. `confidence` y `requires_human_review` son independientes (un caso obvio como "tanque en 0" da confidence 0.92 + no review aunque la solución sea trivial; "frenos chillan" da confidence 0.78 + review por seguridad)
- `RetrievalRun` model: snapshot de cada query del LLM (query text, top_k, results con scores, threshold_passed, latency, embedding_tokens). UI plegable en `/work_orders/:id` muestra el "árbol de razonamiento" del LLM — no es black box.
- `/knowledge` admin con stats agregadas (docs, chunks, páginas, costo embeddings), upload manual y botón **"Cargar manuales precargados"** para bootstrap desde la UI (necesario en producción donde no hay shell)
- Prompts y schemas extraídos a archivos separados: `app/prompts/agents/mechanic_diagnostic.md`, `config/schemas/respond_with_analysis.json`. Loaders con cache + auto-reload en dev (producto/QA pueden editar prompts sin tocar Ruby)

**Fase 4 — Tests + Deploy**

- 171 specs en RSpec con WebMock (ningún test llama OpenAI real). Cobertura selectiva sobre piezas frágiles: math del RRF, regex de chunkers, idempotencia de bootstrap, threshold logic, tool loop del agente.
- Deploy a Render con `render.yaml` (Postgres + Redis + Web), Active Storage en S3, ActionCable via Redis para broadcasts cross-thread.

### Future work documentado

- Vision fallback para PDFs escaneados (detección de páginas con bajo recuento de texto + render a PNG + GPT-5 multimodal)
- Auth + multi-tenancy (Devise + scoping por taller, ahora es single-tenant sin login)
- Re-ingest con traducción on-demand desde la UI (botón "Traducir al español" por documento)
- Dashboard de observabilidad agregada (gráficos de costo/día, latencia p95, tasa de reanálisis)
- Tests con golden set de motivos → expected categories/sources (regression suite para el RAG)

Roadmap detallado en [docs/PLAN.md](docs/PLAN.md) y [docs/architecture.md](docs/architecture.md).

---

## Cómo evaluar este entregable

**Camino corto (recomendado):**

1. Entrar a <https://controlcar-web.onrender.com>. Esperar 30-60s la primera vez (Render free dormita el container).
2. Ir a `/knowledge`. Si está vacía, click en **"Cargar manuales precargados"** (con traducción ES tarda ~10 min y mejora retrieval; sin traducción ~1 min). La lista se actualiza sola cuando termina.
3. Crear una OT en `/work_orders/new` con un motivo realista. Tres casos sugeridos para ver el rango de comportamiento del sistema:
   - *Caso obvio:* "Mi auto no avanza y el tablero marca gasolina en 0" → confidence ~0.92, sin banner de revisión humana, categoría `fuel`.
   - *Caso con DTC explícito:* "Tirita en ralentí y el escáner arroja P0300" → confidence ~0.78, fuente citada con badge P0300 + página del manual Ford.
   - *Caso humanizado ambiguo:* "Pierde fuerza al subir cuestas, tiembla en ralentí, huele raro a bencina" → confidence ~0.66, banner de revisión humana, múltiples fuentes citadas (misfire + EVAP + sensor O2).
4. Abrir el panel **"Búsquedas en knowledge base"** (plegable, al final de la página). Ver las queries que armó el LLM, scores por chunk, threshold passed/weak.

**Camino largo (clonar + correr local):** seguir [Quick start](#quick-start).

**Si querés revisar código** en orden de impacto:

1. `app/services/ai/agents/base_agent.rb` — el tool loop con MAX_ITERATIONS + agent_run injection
2. `app/prompts/agents/mechanic_diagnostic.md` — el system prompt completo con calibración + ejemplos
3. `app/services/ai/tools/search_knowledge_base.rb` — hybrid retrieval con Reciprocal Rank Fusion
4. `config/schemas/respond_with_analysis.json` — JSON schema portable + strict mode
5. `app/services/ai/ingestion/structured_dtc_chunker.rb` — regex chunking por código DTC
6. `app/jobs/ingest_pdf_job.rb` — pipeline RAG con auto-fallback
7. `app/views/work_orders/_retrieval_runs.html.erb` — observability del RAG (no es black box)
8. `spec/` — 171 specs, run con `bundle exec rspec`

**Leer también:** [docs/architecture.md](docs/architecture.md) para las decisiones técnicas de Fase 3 + future work.

---

## Documentación detallada

| Archivo | Descripción |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | Plan original del challenge — estrategia, stack, fases, talking points |
| [docs/architecture.md](docs/architecture.md) | Decisiones técnicas de Fase 3 (RAG): hybrid retrieval, chunking strategies, calibración LLM, observability, future work |

---

## Troubleshooting

**`PG::ConnectionBad` al correr migraciones**
Postgres no está corriendo. macOS: `brew services start postgresql@14`.

**`PG::UndefinedFile: ERROR: could not open extension control file ... "vector"`**
Falta la extensión pgvector. macOS: `brew install pgvector` y volver a correr `bin/rails db:migrate`.

**`Redis::CannotConnectError`**
Sidekiq no encuentra Redis. `brew services start redis` o `redis-server` en otra terminal.

**El análisis nunca termina (queda en "analizando…")**
El worker de Sidekiq no está corriendo. Verificar que `bin/dev` levantó las 3 líneas del `Procfile.dev`, o iniciar manualmente con `bundle exec sidekiq -C config/sidekiq.yml`. Revisar también `/sidekiq` por jobs en dead set.

**`Faraday::UnauthorizedError` u "Invalid API key"**
Falta o está mal el `OPENAI_API_KEY` en `config/application.yml`. Recordá que `figaro` lee de ahí.

**Los estilos no se actualizan al guardar**
Estás corriendo `bin/rails server` en lugar de `bin/dev`. Sólo `bin/dev` levanta el watcher de Tailwind.

**Quiero resetear toda la DB**
```bash
bin/rails db:drop db:create db:migrate db:seed
```

**`db:seed` tarda mucho / consume tokens de OpenAI**
Por default `db:seed` ingesta los 3 PDFs precargados **con traducción al español** (~10 min, ~$0.05). Para skipear:
```bash
SKIP_KB_TRANSLATE=1 bin/rails db:seed   # ingesta sin traducir (~30s, gratis)
SKIP_KB_SEED=1 bin/rails db:seed         # solo OTs demo, KB vacía
```
Una vez levantada la app, podés cargar la KB después desde el botón **"Cargar manuales precargados"** en `/knowledge`.

**En Render: la app responde lento la primera vez**
Plan free duerme los containers tras 15 min de inactividad. Primer request despierta el container (~30-60s). Las siguientes son normales.

**En Render: la KB está vacía**
El `db:seed` automático del entrypoint solo carga las OTs demo (rápido). Los 3 PDFs precargados se ingestan **desde el botón "Cargar manuales precargados"** en `/knowledge` — esto evita timeouts del boot. Hay que clickearlo una vez tras el primer deploy.

**Tests fallando por `WebMock::NetConnectNotAllowedError`**
El spec está llamando OpenAI sin stubear. Agregar `stub_request(:post, "https://api.openai.com/...")` antes de la acción. WebMock bloquea HTTP real intencionalmente para no quemar tokens.

---

## Decisiones técnicas destacadas

### ¿Por qué structured output forzado vía tool en lugar de "JSON mode"?

`strict: true` en la definición de la tool valida el schema **a nivel API de OpenAI**, no en cliente. El modelo no puede devolver un campo faltante ni un tipo incorrecto. Es contrato explícito, no parsing defensivo.

### ¿Por qué hybrid retrieval (vector + tsvector con RRF) en lugar de solo vector?

Vector embeddings fallan en identificadores exactos: "P0301" no se "parece" semánticamente a "P0302". Pero un mecánico que busca "P0301" no quiere matches "similares" — quiere ese código. La capa de tsvector (Postgres full-text) cubre keyword exacto, y **Reciprocal Rank Fusion** (Cormack et al., 2009) combina ambos rankings sin necesidad de normalización de scores. Es el patrón estándar de la industria para retrieval técnico — está en mejor performance que vector-only en casi todos los benchmarks de QA con identificadores.

### ¿Por qué 2 estrategias de chunking (structured_dtc + token_window)?

Los manuales OEM tipo "Ford 2007 PCED" tienen formato tabular `P0010 - Title\n Description:` — un regex line-based los parte en chunks de 1 código cada uno (recall altísimo). Los libros narrativos como Denton no tienen esa estructura — ahí ventanas de tokens con overlap (paragraph-aware) preservan mejor el contexto. Hardcodear una sola estrategia te dejaría chunks sub-óptimos en la mitad de los documentos. El sistema **auto-falla** a token_window cuando structured_dtc no detecta formato, así un upload con la estrategia "mala" no rompe — se recupera y la UI muestra cuál usó.

### ¿Por qué prompts y schemas viven en archivos separados (`app/prompts/`, `config/schemas/`)?

Los prompts inline como heredocs mezclan "datos del agente" con "lógica de control". El system prompt del MechanicDiagnosticAgent tiene ~80 líneas con calibración de confidence + ejemplos few-shot — no es código, es **texto que producto/QA debería poder iterar sin tocar Ruby**. Mismo argumento para el schema de `respond_with_analysis`: es JSON estándar, portable a frontend y otros lenguajes. El loader `Ai::PromptTemplate` soporta ERB para interpolación, y `Ai::SchemaTemplate` strippea keys con prefix `_` automáticamente (convención para meta-info embebida en JSON puro que no debe llegar al modelo).

### ¿Por qué confidence y requires_human_review están desacopladas?

Una primera versión las acopló (regla "< 0.7 → human review"). El LLM terminó auto-censurando la confidence — daba 0.68 para casos obvios donde técnicamente "sabía" que era 0.92, porque no quería triggear "demasiada seguridad". El refactor del prompt con anchors explícitos + ejemplos few-shot las desacopla: "Tanque en 0" da confidence 0.92 + human_review false (cargar nafta es trivial). "Frenos chillan" da confidence 0.78 + human_review true (es de seguridad). Calibración inteligente, no defensiva.

### ¿Por qué priority es nullable (autoridad exclusiva del LLM)?

Antes la columna tenía default "medium" en DB + controller. La UI mostraba "Media Prioridad" antes que el LLM termine, confundiendo al usuario sobre quién decidió eso. Ahora `priority` arranca null y la UI **no renderiza el badge** durante `:analyzing` — aparece recién cuando el LLM lo setea. Es un patrón importante para sistemas AI-driven: separar autoridades de datos. Si un campo es "owned by AI", no debe tener default human-set.

### ¿Por qué Sidekiq y no Solid Queue (default de Rails 8)?

Familiaridad + Web UI built-in en `/sidekiq` que da observabilidad de cola, retries y dead set gratis. Solid Queue sería más simple en infra (sin Redis), pero con plazo corto fui con la herramienta que mejor conozco para minimizar fricción. **En producción (Render free)** los jobs corren in-proceso vía `:async` adapter porque el plan no soporta workers separados — Sidekiq queda activo solo en dev. Documentado en `render.yaml`.

### ¿Por qué pgvector y no Pinecone?

Para el volumen esperado (cientos a miles de chunks de manuales de un taller), pgvector local tiene latencia <5ms, cero infra extra y joins triviales con el resto del schema. La gem `neighbor` permite swappear el vector store en el futuro si crece el volumen.

### ¿Por qué OpenAI GPT-5 y no Anthropic Claude?

Técnicamente equivalentes para este caso de uso — ambos cubren function calling estricto, multimodal y structured output. Primó disponibilidad de credenciales y `prompt caching` automático en prefijos repetidos. La abstracción `Ai::Providers::BaseProvider` deja la decisión reversible: sumar un AnthropicProvider es agregar una clase, no reescribir el agente.

### ¿Por qué la abstracción `Ai::Providers::BaseProvider` si hay una sola implementación?

Sumar un segundo provider (Anthropic, Gemini) es agregar una clase, no reescribir el agente. El costo de la abstracción es una interfaz de 3 métodos; el beneficio es que la decisión de provider deja de ser irreversible. Mismo argumento para `ToolRegistry`: sumar tools es agregar una clase + una línea.

---

**Autor:** Angel Campo · **Challenge:** Control Car (Control Group, Chile) · **Plan completo:** [docs/PLAN.md](docs/PLAN.md)
