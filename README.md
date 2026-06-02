# Recepción Inteligente de Vehículos

**Mini-módulo para que talleres mecánicos registren Órdenes de Trabajo (OT) y obtengan un análisis automático del problema mediante un agente IA especializado en mecánica.**

> Control Car Fullstack Challenge · Ruby on Rails 8.1 · Hotwire · PostgreSQL + pgvector · Sidekiq · OpenAI GPT-5

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
   (patente, cliente, kilometraje, motivo, prioridad, fotos)
                  ↓
2. WorkOrders::Create resuelve o crea el Vehicle por patente,
   crea la WorkOrder y encola AnalyzeWorkOrderJob (Sidekiq)
                  ↓
3. El job ejecuta MechanicDiagnosticAgent — un loop con tools
   que consulta historial del vehículo, busca en la base de
   conocimiento (Fase 3) y SIEMPRE termina llamando la tool
   `respond_with_analysis` con structured output forzado por schema
                  ↓
4. Cuando termina, hace Turbo Stream broadcast al show de la OT.
   El usuario ve el análisis aparecer en tiempo real:
     - Categoría con icono
     - Lista de posibles fallas con probabilidad
     - Prioridad sugerida (comparada con la del usuario)
     - Próximos pasos numerados
     - Confianza (anillo visual + porcentaje)
     - Banner "Revisión humana sugerida" si confianza < 0.7
     - Stats de la corrida: latencia, tokens in/out, costo, modelo
                  ↓
5. Botón "Re-analizar" encola un nuevo run cuando quiera.
   Cada intento queda registrado en /work_orders/:id/agent_runs
   (modal con timeline de runs, tokens y costos).
```

---

## Stack técnico

| Capa | Tecnología | Versión |
|---|---|---|
| Lenguaje | Ruby | 3.3+ |
| Framework | Ruby on Rails | 8.1 |
| Frontend | Hotwire (Turbo + Stimulus) | — |
| Estilos | TailwindCSS | tailwindcss-rails |
| Base de datos | PostgreSQL + extensión `vector` (pgvector) | 14+ |
| Background jobs | Sidekiq | requiere Redis |
| Cache / Cable | Solid Cache + Solid Cable | DB-backed |
| WebSockets | Action Cable (Solid Cable adapter) | broadcast del análisis |
| Storage | Active Storage (local dev) | fotos de OT + PDFs |
| LLM | OpenAI GPT-5 vía `ruby-openai` | function calling con `strict: true` |
| Embeddings | OpenAI `text-embedding-3-small` (1536d) | para Fase 3 (RAG) |
| Vector search | `neighbor` gem sobre pgvector | índice ivfflat cosine |
| Config | `figaro` (`config/application.yml`) | secrets fuera de git |
| Deploy | Kamal-ready (Dockerfile incluido) | — |

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
bin/rails db:seed                   # 3 OTs demo

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
2. Click en una OT → ver el análisis estructurado, con badges, anillo de confianza y stats.
3. Click en el icono de "Runs" → modal con el timeline de corridas del agente.
4. Click en **Re-analizar** → spinner, Turbo Stream actualiza la vista cuando el job termina.
5. Crear una OT nueva en `/work_orders/new` con un motivo realista y, opcionalmente, fotos del vehículo.
6. Inspeccionar la cola de Sidekiq en `/sidekiq`.

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
                       ├─ (N) AgentRun         ← observabilidad
                       └─ photos (Active Storage, múltiples)

KnowledgeDocument (1) ─── (N) KnowledgeChunk   ← RAG (Fase 3)
                          embedding: vector(1536), ivfflat cosine
```

### Tablas implementadas

| Tabla | Rol |
|---|---|
| `vehicles` | Patente única normalizada (uppercase). Reutilizable entre OTs. |
| `work_orders` | Una OT por ingreso. Status: `draft → analyzing → analyzed`. |
| `ai_analyses` | Snapshot estructurado del análisis. 1:1 con WorkOrder. |
| `agent_runs` | Una fila por intento de análisis. Tokens, costo, latencia, raw log. |
| `knowledge_documents` | PDFs (modelo y migración listos, UI en Fase 3). |
| `knowledge_chunks` | Chunks vectorizados con `embedding vector(1536)` + índice ivfflat. |

### Multi-tenancy

**No implementado** — el alcance es un solo taller, sin auth. Documentado como evolución en [docs/PLAN.md](docs/PLAN.md) §9.

---

## Estructura del proyecto

```
controlcar-reception/
├── app/
│   ├── controllers/
│   │   ├── work_orders_controller.rb       index, new, create, show, reanalyze
│   │   └── agent_runs_controller.rb        index (lazy Turbo Frame)
│   ├── models/
│   │   ├── vehicle.rb                      patente normalizada uppercase
│   │   ├── work_order.rb                   status enum + broadcast
│   │   ├── ai_analysis.rb                  snapshot estructurado
│   │   ├── agent_run.rb                    observabilidad
│   │   ├── knowledge_document.rb           (Fase 3)
│   │   └── knowledge_chunk.rb              vector(1536) + neighbor
│   ├── services/
│   │   ├── ai/                             ← arquitectura de IA (ver arriba)
│   │   └── work_orders/
│   │       └── create.rb                   resuelve Vehicle + crea OT + encola job
│   ├── jobs/
│   │   └── analyze_work_order_job.rb       Sidekiq, queue :ai
│   ├── views/
│   │   ├── work_orders/                    index, new, show, _form, _ai_analysis
│   │   └── agent_runs/                     index, _agent_run
│   └── javascript/
│       └── controllers/                    Stimulus (modal, etc.)
├── config/
│   ├── routes.rb                           work_orders + agent_runs + /sidekiq
│   ├── sidekiq.yml                         concurrency y queues
│   ├── application.yml                     secrets (gitignoreado)
│   └── database.yml                        Postgres + extensión vector
├── db/
│   ├── migrate/                            vector ext, vehicles, work_orders, ...
│   ├── schema.rb
│   └── seeds.rb                            3 OTs demo realistas
├── docs/
│   └── PLAN.md                             plan completo del challenge
├── Procfile.dev                            web + css + worker
└── bin/dev                                 levanta los 3 procesos vía Foreman
```

### Rutas principales

| Método | Path | Acción |
|---|---|---|
| GET | `/` | Listado de OTs (root) |
| GET | `/work_orders/new` | Form de nueva OT |
| POST | `/work_orders` | Crea OT + encola análisis |
| GET | `/work_orders/:id` | Detalle con análisis estructurado |
| POST | `/work_orders/:id/reanalyze` | Encola nuevo análisis |
| GET | `/work_orders/:id/agent_runs` | Timeline de corridas (Turbo Frame) |
| — | `/sidekiq` | Sidekiq Web UI |

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
Fase 3   [████████░░░░░░░░░░░░]   40%   RAG (modelos + pgvector listos, UI e ingest pendientes)
Fase 4   [░░░░░░░░░░░░░░░░░░░░]    0%   Tests + video demo + deploy final
```

### Implementado

- Form de OT con todos los campos del brief + upload múltiple de fotos
- Vehicle reutilizable por patente normalizada
- `MechanicDiagnosticAgent` con tool loop y observabilidad por corrida
- Tools: `GetVehicleHistory` + `RespondWithAnalysis` (structured output forzado)
- Llamada multimodal (texto + fotos)
- `AnalyzeWorkOrderJob` (Sidekiq, queue `:ai`)
- Turbo Stream broadcast del análisis cuando termina el job
- UI con badges, anillo de confianza, banner de revisión humana, stats de la corrida
- Panel de Agent Runs como modal nativo `<dialog>` con timeline
- Botón "Re-analizar" con transición animada
- Seeds con 3 OTs demo realistas

### Scaffolded (modelo listo, no expuesto)

- `KnowledgeDocument` + `KnowledgeChunk` con `embedding vector(1536)` e índice ivfflat
- Gem `neighbor` configurada para `nearest_neighbors`
- Gem `pdf-reader` lista para extracción

### Pendiente (Fase 3 + 4)

- `/knowledge` controller + UI de upload de PDFs
- `Ai::Ingestion::{PdfExtractor, Chunker, BatchEmbedder}`
- `IngestPdfJob`
- Tool `SearchKnowledgeBase` registrada en `ToolRegistry`
- Sección `sources` del schema poblada en producción + UI de citations
- Tests críticos (agent loop con tool calls mockeadas, schema validation)
- Vision fallback para PDFs escaneados (documentado como future work)

Roadmap completo en [docs/PLAN.md](docs/PLAN.md) §8 y §9.

---

## Cómo evaluar este entregable

Si querés ir directo al grano:

1. **Levantar local** siguiendo el [Quick start](#quick-start).
2. **Crear una OT** en `/work_orders/new` con un motivo realista (ej: "frenos suenan al frenar fuerte, vibración en el volante"). Subir 1-2 fotos opcionales.
3. **Ver el análisis** aparecer en vivo gracias al broadcast Turbo Stream.
4. **Re-analizar** y ver cómo se acumulan los runs en el modal de Agent Runs.
5. **Revisar el código** en este orden:
   - `app/services/ai/agents/base_agent.rb` y `mechanic_diagnostic_agent.rb` — el loop y el system prompt
   - `app/services/ai/tools/respond_with_analysis.rb` — structured output forzado
   - `app/services/ai/tools/tool_registry.rb` — patrón de extensibilidad
   - `app/jobs/analyze_work_order_job.rb` — orquestación
   - `app/views/work_orders/_ai_analysis.html.erb` — render del análisis
6. **Leer [docs/PLAN.md](docs/PLAN.md)** para ver el razonamiento de scope, qué se decidió dejar fuera y por qué.

---

## Documentación detallada

| Archivo | Descripción |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | Plan completo del challenge — estrategia, stack, dominio, arquitectura de IA, RAG, UX, fases, future work y talking points |

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

---

## Decisiones técnicas destacadas

### ¿Por qué structured output forzado vía tool en lugar de "JSON mode"?

`strict: true` en la definición de la tool valida el schema **a nivel API de OpenAI**, no en cliente. El modelo no puede devolver un campo faltante ni un tipo incorrecto. Es contrato explícito, no parsing defensivo.

### ¿Por qué Sidekiq y no Solid Queue (default de Rails 8)?

Familiaridad + Web UI built-in en `/sidekiq` que da observabilidad de cola, retries y dead set gratis. Solid Queue sería más simple en infra (sin Redis), pero con plazo corto fui con la herramienta que mejor conozco para minimizar fricción.

### ¿Por qué pgvector y no Pinecone?

Para el volumen esperado (cientos a miles de chunks de manuales de un taller), pgvector local tiene latencia <5ms, cero infra extra y joins triviales con el resto del schema. La gem `neighbor` permite swappear el vector store en el futuro si crece el volumen — la abstracción `Ai::VectorStores::Base` está pensada en el plan.

### ¿Por qué OpenAI GPT-5 y no Anthropic Claude?

Técnicamente equivalentes para este caso de uso — ambos cubren function calling estricto, multimodal y structured output. Primó disponibilidad de credenciales y `prompt caching` automático en prefijos repetidos.

### ¿Por qué la abstracción `Ai::Providers::BaseProvider` si hay una sola implementación?

Sumar un segundo provider (Anthropic, Gemini) es agregar una clase, no reescribir el agente. El costo de la abstracción es una interfaz de 3 métodos; el beneficio es que la decisión de provider deja de ser irreversible. Mismo argumento para `ToolRegistry`: sumar tools es agregar una clase + una línea.

---

**Autor:** Angel Campo · **Challenge:** Control Car (Control Group, Chile) · **Plan completo:** [docs/PLAN.md](docs/PLAN.md)
