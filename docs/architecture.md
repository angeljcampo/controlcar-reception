# Arquitectura — Fase 3 (RAG) + decisiones técnicas

Este doc complementa el [README](../README.md) y el [plan original](./PLAN.md). Foco en las decisiones técnicas de **Fase 3 (Retrieval-Augmented Generation)** y en lo que quedó como *future work* honestamente documentado.

> Para evaluar el código: empezar por la sección [Diagrama del flujo RAG](#diagrama-del-flujo-rag) para tener el mapa mental, después saltar a la decisión de interés.

---

## Tabla de contenidos

1. [Diagrama del flujo RAG](#diagrama-del-flujo-rag)
2. [Hybrid retrieval con Reciprocal Rank Fusion](#hybrid-retrieval-con-reciprocal-rank-fusion)
3. [Estrategias de chunking por documento](#estrategias-de-chunking-por-documento)
4. [Calibración del LLM (confidence + human review)](#calibración-del-llm-confidence--human-review)
5. [Prompts y schemas como archivos (no inline)](#prompts-y-schemas-como-archivos-no-inline)
6. [Observabilidad del retrieval (RetrievalRun)](#observabilidad-del-retrieval-retrievalrun)
7. [Priority autoridad exclusiva del LLM](#priority-autoridad-exclusiva-del-llm)
8. [Deploy sin shell (bootstrap via UI)](#deploy-sin-shell-bootstrap-via-ui)
9. [Auto-fallback del chunker](#auto-fallback-del-chunker)
10. [Trade-offs aceptados conscientemente](#trade-offs-aceptados-conscientemente)
11. [Future work](#future-work)

---

## Diagrama del flujo RAG

```
                    ┌──────────────────────────────────────────┐
   /work_orders/new │  Usuario crea OT (patente, motivo, fotos)│
                    └────────────────────┬─────────────────────┘
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │  WorkOrders::Create                       │
                    │   • find_or_create Vehicle por patente    │
                    │   • crea WorkOrder (priority: NULL)       │
                    │   • encola AnalyzeWorkOrderJob            │
                    └────────────────────┬─────────────────────┘
                                         │
                                         ▼ (Sidekiq / :async en prod)
                    ┌──────────────────────────────────────────┐
                    │  MechanicDiagnosticAgent (BaseAgent loop) │
                    │   ┌────────────────────────────────────┐  │
                    │   │ system_prompt ← app/prompts/...md  │  │
                    │   └────────────────────────────────────┘  │
                    │                                          │
                    │   ▼ tool call 1                          │
                    │   get_vehicle_history(patente)           │
                    │                                          │
                    │   ▼ tool call 2..N (LLM puede iterar)    │
                    │   search_knowledge_base(query, top_k)    │
                    │      ├─ vector_search (pgvector cosine)  │
                    │      ├─ keyword_search (tsvector ts_rank)│
                    │      ├─ Reciprocal Rank Fusion           │
                    │      └─ persist RetrievalRun ◄────┐      │
                    │                                  │      │
                    │   ▼ tool call FINAL              │      │
                    │   respond_with_analysis(args)    │      │
                    │      ↑ strict: true              │      │
                    │      ↑ schema ← config/schemas/  │      │
                    └────────────────────┬─────────────┴──────┘
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │  Persistir AiAnalysis + sync priority    │
                    │  Turbo Stream broadcast a /work_orders/N │
                    └────────────────────┬─────────────────────┘
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │  UI muestra: análisis + sources con DTC  │
                    │  + panel "Búsquedas en knowledge base"   │
                    │    con queries del LLM y scores          │
                    └──────────────────────────────────────────┘
```

---

## Hybrid retrieval con Reciprocal Rank Fusion

### Problema

Vector embeddings (cosine similarity sobre `text-embedding-3-small`) son excelentes para **parafraseo semántico** — "vehículo no arranca" matchea chunks de batería/starter/alternador aunque ninguno mencione exactamente "no arranca". Pero fallan en **identificadores exactos**: `P0301` no se "parece" semánticamente a `P0302`. Un mecánico que busca P0301 quiere ese código, no códigos "similares".

### Solución

Dos índices sobre el mismo conjunto de chunks:

1. **Vector search** (`pgvector` con HNSW): cosine distance sobre embeddings de 1536 dims. Cubre parafraseo y conceptos.
2. **Keyword search** (Postgres `tsvector` con GIN): `to_tsvector('spanish', ...)` con `setweight('A', breadcrumb) || setweight('B', content)`. Los códigos DTC viven en el breadcrumb (`"DTC_Codes › P0301 — Cylinder 1 Misfire"`), boosteados al rango A. Cubre identificadores exactos y términos técnicos literales.

### Reciprocal Rank Fusion (Cormack et al., 2009)

Para cada documento `d` aparecido en alguno de los rankings, su **score fusionado** es:

```
score(d) = Σᵢ  1 / (k + rank_i(d))
```

donde `i` itera sobre los rankings (vector + keyword), `rank_i(d)` es la posición de `d` en el ranking `i` (1-indexed), y `k=60` (la constante recomendada por el paper original).

**Por qué RRF y no otra fusión:**

- **No necesita score normalization.** Cosine distance vive en [0, 2] y `ts_rank` devuelve floats en escalas inconsistentes — normalizar manualmente es frágil. RRF solo usa las posiciones (ordinales), inmune al rango de scores subyacentes.
- **Es el estándar de la industria** para retrieval híbrido (Elasticsearch lo implementa nativo, IBM Watson lo usa, etc.).
- **Robusto a outliers**: un chunk con score altísimo en un ranking pero ausente en el otro no domina la fusión.

Implementación en [`Ai::Tools::SearchKnowledgeBase#reciprocal_rank_fusion`](../app/services/ai/tools/search_knowledge_base.rb).

### Threshold-aware behavior

Después de fusionar, el tool computa `strong_matches_count`: cuántos de los chunks fetcheados tienen `vector_distance < STRONG_MATCH_THRESHOLD` (0.65). Si es 0, devuelve `threshold_passed: false` al LLM.

El system prompt instruye al LLM: si `threshold_passed: false`, **no cites** esos chunks como evidencia firme, baja tu confidence y considera marcar `requires_human_review: true`. Es la barrera contra alucinaciones citadas.

---

## Estrategias de chunking por documento

### Por qué no una sola estrategia

Los 3 PDFs precargados tienen estructuras radicalmente distintas:

| Documento | Formato | Tamaño |
|---|---|---|
| Ford 2007 PCED (DTC_Codes) | Tabular: `P0010 - Title\n Description: ...\n Possible Causes: ...` | 147 págs, ~330 códigos |
| Denton "Diagnóstico Avanzado" | Prose narrativa en español, capítulos con headings | 46 págs preview, conceptual |
| PCS Diagnostic Codes | Tabla densa multi-columna jumbled en plain text | 3 págs |

Una sola estrategia produce chunks subóptimos en al menos uno. Por eso `KnowledgeDocument#chunking_strategy` es enum:

### `structured_dtc`

Para manuales OEM tipo Ford. Regex line-based busca `^[UPBC]\d{4} - Title` y agrupa todo el bloque siguiente hasta el próximo header. Resultado: **1 chunk = 1 código DTC completo** con `Description`, `Possible Causes`, `Diagnostic Aids`.

Beneficios:
- Retrieval por código devuelve el chunk exacto (no "el chunk que contiene también otros DTCs").
- El breadcrumb `"DTC_Codes › P0301 — Cylinder 1 Misfire"` queda con peso A en el tsvector → keyword search por código es instant.
- Citations son legibles: "P0301 · pág 34 · 'El monitor de misfire detecta cuando...'"

### `token_window`

Para prose narrativa (Denton). Ventanas de ~800 tokens (estimado por chars × 4) con overlap de ~150 tokens, **paragraph-aware**: nunca parte un párrafo al medio. Si un párrafo solo supera el target, se mete entero en un chunk.

Beneficios:
- Preserva contexto semántico (un párrafo completo).
- Overlap mantiene continuidad para búsquedas que caen en boundaries.
- Funciona para cualquier prose, no requiere estructura específica.

### Auto-fallback

Si el usuario sube un PDF eligiendo `structured_dtc` pero el chunker no detecta el formato (< 10 matches del regex), `StructuredDtcChunker` levanta `DetectionError`. El job lo captura y **automáticamente reintenta con `token_window`**, actualizando el `chunking_strategy` del doc para reflejar lo que realmente se usó. Ver [`IngestPdfJob#chunk_pages`](../app/jobs/ingest_pdf_job.rb).

Resultado para el usuario: no importa si elige "mal" la estrategia, el sistema se recupera y la UI muestra el chip de strategy real.

---

## Calibración del LLM (confidence + human review)

### Iteración 1 (bug)

Primera versión del system prompt:

> *"Si los síntomas son ambiguos o tu confianza es baja (< 0.7), poné `requires_human_review: true`."*

Resultado observado: el LLM daba **0.68 para casos obvios** donde técnicamente "sabía" que era 0.92. Ejemplo: motivo `"Mi auto no avanza, gasolina en 0"` → confidence 0.68 + review humana. El LLM auto-censuraba para no triggear la regla conservadora.

### Iteración 2 (fix)

Refactor del prompt con tres cambios:

1. **Escala explícita 0-1 con anchors y ejemplos** (`app/prompts/agents/mechanic_diagnostic.md`):

```
- 0.90-0.98 → Síntoma INEQUÍVOCO con causa 1:1
    * "Tablero gasolina en 0 + no avanza" → 0.92
    * "Cliente trae código P0301" → 0.93
- 0.75-0.89 → Diagnóstico probable con respaldo KB
- 0.60-0.74 → Múltiples causas plausibles
- < 0.40 → Información insuficiente
```

2. **Desacople explícito** confidence vs human_review:

> *"confidence y requires_human_review son INDEPENDIENTES:*
> *• 'Tanque en 0' → confidence 0.92, requires_human_review FALSE (cargar nafta es trivial)*
> *• 'Frenos chillan' → confidence 0.78, requires_human_review TRUE (seguridad)"*

3. **Few-shot examples** para anclar cada banda.

### Resultado validado en 4 casos

| Motivo del cliente | Iteración 1 | Iteración 2 |
|---|---|---|
| "Tanque en 0, no avanza" | 0.68, review=true | **0.92, review=false** ✓ |
| "Escáner arroja P0301" | 0.78, review=false | 0.78, review=false |
| "Pierde fuerza + olor bencina" | 0.66, review=true | 0.66, review=true |
| "Frenos chillan + pedal blando" | 0.78, review=false | 0.78, **review=true** ✓ |

El sistema ahora discrimina correctamente entre **certeza** (confidence) y **necesidad de verificación experta** (human review). Caso de seguridad puede tener confidence alta + review obligatorio.

### Talking point

> *"Calibración inteligente, no defensiva. El LLM reconoce su propia incertidumbre cuando los síntomas son ambiguos, pero da confidence alta cuando la evidencia lo amerita. Es lo que un mecánico responsable haría."*

---

## Prompts y schemas como archivos (no inline)

### Antes (Fase 2)

```ruby
class MechanicDiagnosticAgent < BaseAgent
  def system_prompt
    <<~PROMPT
      Sos un experto en diagnóstico mecánico...
      [80 líneas más de heredoc]
    PROMPT
  end
end
```

Problemas:
- Producto/QA no puede editar el prompt sin tocar Ruby.
- `git diff` mezcla cambios de lógica con cambios de tono.
- 80 líneas de texto narrativo dentro de un archivo `.rb` es ilegible.
- El schema de `RespondWithAnalysis` tenía ~120 líneas de Hash anidado — JSON disfrazado de Ruby.

### Ahora (Fase 3)

- `app/prompts/agents/mechanic_diagnostic.md` — prompt completo en Markdown.
- `app/prompts/ingestion/spanish_translator.md` — prompt del traductor.
- `config/schemas/respond_with_analysis.json` — schema JSON puro, navegable.
- `Ai::PromptTemplate.load("agents/mechanic_diagnostic")` — loader con cache + auto-reload en dev. Soporta ERB para interpolación de locals (`<%= business_name %>`).
- `Ai::SchemaTemplate.load("respond_with_analysis")` — loader con `symbolize_names: true` y **stripping recursivo de keys con prefix `_`** (convención para meta-info embebida en JSON que no debe llegar al modelo).

### Beneficio adicional

JSON schemas portables: el mismo `respond_with_analysis.json` podría reusarse desde un frontend para validar formularios, o exportarse como OpenAPI doc, sin reescribir.

---

## Observabilidad del retrieval (RetrievalRun)

### Modelo

```ruby
RetrievalRun
  belongs_to :agent_run     # cada query del LLM cae bajo un AgentRun
  has_one :work_order, through: :agent_run

  fields:
    query                  text     # texto exacto que el LLM pasó al tool
    top_k                  integer
    total_matches          integer  # chunks fetcheados
    strong_matches_count   integer  # con dist < threshold
    threshold_passed       boolean
    best_vector_distance   decimal
    results                jsonb    # [{chunk_id, vector_rank, keyword_rank, fused_score, ...}]
    latency_ms             integer
    embedding_tokens       integer
```

Persistido por `SearchKnowledgeBase#call` con `agent_run` inyectado al context por `BaseAgent#execute_one_tool`.

### UI

`/work_orders/:id` muestra un `<details>` plegable **"Búsquedas en knowledge base"** con:
- Cantidad de queries del LLM (típicamente 1-4 según ambigüedad del motivo)
- Para cada query: texto literal + badge STRONG/WEAK MATCH + stats row (matches, fuertes, best dist, latencia, tokens)
- Tabla por query: chunk, vec_rank, kw_rank, vec_dist, RRF score

### Por qué importa

Es la diferencia entre **"el LLM decidió algo"** y **"el LLM hizo estas 3 búsquedas, recibió estos chunks con estos scores, citó tales fuentes"**. Para un evaluador, esto demuestra que el sistema **no es black box** — el árbol de razonamiento es auditable.

---

## Priority autoridad exclusiva del LLM

### Antes

Migration: `priority` con `default: "medium"`, `null: false`. Controller `new`: `WorkOrder.new(priority: "medium")`.

Resultado UI: el badge "Media Prioridad" aparecía **mientras** el LLM analizaba. Confuso — parece que la decisión ya fue tomada.

### Ahora

- Migration `make_work_order_priority_nullable`: `default: nil`, `null: true`.
- Controller `new`: `WorkOrder.new` (sin priority).
- Helpers `priority_badge` y `priority_with_suffix_badge` devuelven `nil` cuando priority es nil → UI no renderiza el pill durante `:analyzing`.
- Cuando `AnalyzeWorkOrderJob` termina, sobrescribe priority con el verdict del LLM. El badge aparece reciencito con el valor correcto.

### Principio general

Para sistemas AI-driven: **separar autoridades de datos**. Si un campo es "owned by AI", no debe tener default human-set. Si no lo separás, los humanos terminan viendo placeholders que parecen decisiones tomadas.

---

## Deploy sin shell (bootstrap via UI)

### El problema

Render free **no provee shell access** al container. No se puede ejecutar `bin/rails db:seed` manualmente después del deploy. Y poner el seed completo (con ingest de 3 PDFs + traducción ~10 min) en `db:prepare` del entrypoint arriesga **timeout del boot** — Render mata containers que no responden el health check en N segundos.

### La solución

Separar el seed en dos partes:

1. **`db/seeds.rb`** (sigue corriendo en `db:prepare`): solo 3 WorkOrders demo, ~1 segundo. No bloquea el boot.
2. **`KnowledgeBaseBootstrap`** (service reusable): expuesto via `POST /knowledge/bootstrap`. Crea los 3 KnowledgeDocuments + dispatch `IngestPdfJob.perform_later` para cada uno (async, no bloquea el HTTP).

### Flow para el evaluador en producción

1. Render despliega → boot rápido sin seeds pesados.
2. Evaluador navega a `/knowledge` → ve banner **"Cargar manuales precargados"** con los 3 PDFs disponibles + checkbox de traducción.
3. Click → notice "Procesando 3 PDFs...". Los 3 docs aparecen como `PROCESANDO` en la lista.
4. Cuando terminan: 3 cards `LISTO` con stats. Total: ~1 min sin traducción, ~10 min con.

### Idempotencia

`KnowledgeBaseBootstrap` skipea docs ya `:ready` (no re-ingesta). Si un doc quedó `:failed`, lo recrea. Si más adelante agregás un 4to PDF al `CATALOG`, el banner reaparece solo para ese — los 3 cargados no se tocan.

---

## Auto-fallback del chunker

Cubierto arriba en [Estrategias de chunking](#estrategias-de-chunking-por-documento). El detalle del comportamiento:

```ruby
# IngestPdfJob#chunk_pages
chunker_class.call(pages, document_title: @doc.title)
rescue Ai::Ingestion::StructuredDtcChunker::DetectionError => e
  Rails.logger.warn("[IngestPdfJob] structured_dtc no detectó formato. Fallback a token_window.")
  @doc.update!(chunking_strategy: :token_window)   # ← refleja la realidad en BD
  Ai::Ingestion::TokenWindowChunker.call(pages, document_title: @doc.title)
end
```

Trade-off elegido: **silencioso vs explícito**. Para un sistema de taller donde el recepcionista no es técnico, el silencioso es preferible — el sistema "se cura solo". La UI muestra el chip `token_window` para que el técnico que revise vea cuál se usó realmente. Para una tool dev-facing, el mensaje explícito + retry button habría sido la opción correcta.

---

## Trade-offs aceptados conscientemente

Cosas que sé que no están óptimas pero la decisión fue intencional dado el scope/plazo:

| Decisión | Trade-off |
|---|---|
| Single-tenant sin auth | No multi-taller, no roles. Devise + scoping es 1 día más de trabajo. Documentado en *future work*. |
| Enums hardcoded en `respond_with_analysis.json` | Si cambias `WorkOrder::PRIORITIES`, hay que actualizar el JSON manualmente. Priorizamos portabilidad del schema sobre DRY automático. |
| Polling fallback en lieu de fix de Cable | Si el broadcast Turbo no llega, la UI recarga la página después de 10s. Belt-and-suspenders sobre lo que realmente debería ser un fix de la conexión. |
| `:async` adapter en producción (no Sidekiq) | Render free no soporta workers separados. Si Puma reinicia mid-job, el job se pierde. Aceptable porque los jobs son cortos (~30s-2min) y reintentables. |
| Sin OCR para PDFs escaneados | Solo born-digital. Manuales antiguos de papel escaneados quedan fuera. Future work documentado. |
| Sin re-ranking cross-encoder | RRF + tsvector es suficiente para ~400 chunks. Cross-encoders (Cohere Rerank, etc.) tienen sentido sobre miles de chunks. |
| Sin query rewriting con LLM antes del retrieval | Overkill para esta escala. El LLM ya hace múltiples queries iterativas si la primera es weak. |
| Tests selectivos (171 specs), no exhaustivos | Cobertura sobre piezas frágiles (math, parsing, orchestration). Sin tests de asociaciones triviales ni view specs. |

---

## Future work

Documentado para que se vea que está pensado, no improvisado:

### Vision fallback para PDFs escaneados

Detectar páginas con bajo recuento de texto (< 50 chars/página → probablemente scan), renderizar a PNG con `pdftoppm`, batch de 5 págs por call a GPT-5 multimodal con prompt de extracción. Mantener idempotencia por página, concurrency cap por job para no saturar la API.

### Multi-tenancy con Devise

`Tenant` model + `Devise` con `belongs_to :tenant` en User. `current_tenant` resolvable en ApplicationController via subdomain o usuario. Todas las queries de WorkOrder/KnowledgeDocument scoped al tenant. Roles (recepcionista, mecánico, admin).

### Re-ingest con traducción on-demand

Botón "Traducir al español" en la card de cada documento de `/knowledge`. Dispara un job que reusa los chunks existentes pero corre `SpanishTranslator` sobre ellos + re-embebe el resultado traducido. Permite empezar sin traducción (rápido) y traducir después si la calidad del retrieval lo requiere.

### Dashboard de observabilidad agregada

Más allá del panel por-OT actual. Gráficos de:
- Costo de OpenAI por día (LLM + embeddings + translator)
- Latencia p50/p95/p99 del agente
- Tasa de reanálisis por OT (proxy de calidad del primer análisis)
- Top 10 chunks más citados (qué partes del KB son más útiles)
- Tasa de threshold_passed por motivo (qué queries no encuentran respuesta)

### Golden set de regresión RAG

Archivo `spec/fixtures/rag_golden_set.yml`:

```yaml
- motivo: "Mi auto tirita en ralentí y prende check engine"
  expected_category: engine
  expected_sources_contains: [P0300, P0301]
  expected_confidence_range: [0.65, 0.85]
- ...
```

Spec que corre el agente real (no stubeado) contra cada caso y verifica que category, sources, y confidence están en rango aceptable. Detecta regresiones cuando se cambia el prompt o el threshold.

### Vector store swappable

Interfaz `Ai::VectorStores::Base` + implementaciones `PgvectorStore` (actual) y `PineconeStore` (futuro). Decisión de migración: > 100k chunks o multi-region.

### Auth en endpoints sensibles

`/knowledge/bootstrap` actualmente es público (cualquiera con la URL puede triggerlo y consumir OpenAI tokens). Para producción real: token simple en credentials, o full Devise con role admin requerido.

### Más tools del agente

- `LookupDtcCode(code)` — tabla local de códigos OBD-II con metadatos rápidos sin pasar por el RAG.
- `EstimateRepairTime(component, severity)` — basado en historial del taller (cuando tengamos data real).
- `SuggestSimilarOTs(motivo)` — fuzzy match contra motivos parecidos resueltos.

### Streaming token-a-token

ActionCable + SSE para que el análisis aparezca palabra por palabra mientras el LLM genera, en vez del "spinner → boom todo de una". UX de "está pensando..." con texto apareciendo en vivo. Tool calls intercaladas con streaming requiere parsing cuidadoso de los chunks deltas.

---

## Referencias

- Cormack, Clarke, Büttcher (2009). *Reciprocal Rank Fusion outperforms Condorcet and individual rank learning methods*. SIGIR.
- [OpenAI Function Calling with strict mode](https://platform.openai.com/docs/guides/function-calling) — `strict: true`.
- [pgvector + neighbor gem](https://github.com/ankane/neighbor).
- [Postgres tsvector + ts_rank + setweight](https://www.postgresql.org/docs/current/textsearch-controls.html).
