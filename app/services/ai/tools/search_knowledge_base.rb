# frozen_string_literal: true

module Ai
  module Tools
    # Tool de retrieval: busca chunks relevantes en la knowledge base.
    #
    # ESTRATEGIA: Hybrid retrieval con Reciprocal Rank Fusion.
    #
    #   1. Vector search (semántico): embebe la query y busca por cosine
    #      distance contra los embeddings de los chunks. Bueno para
    #      conceptos parafraseados ("vehículo no arranca" → chunks de
    #      starter, batería, alternador).
    #
    #   2. Keyword search (tsvector): busca por overlap léxico usando el
    #      content_tsv generado. Bueno para identificadores EXACTOS donde
    #      semántico falla: "P0301" no se "parece" semánticamente a otros
    #      códigos pero ES literalmente P0301.
    #
    #   3. Reciprocal Rank Fusion (Cormack et al., 2009): suma 1/(k+rank)
    #      para cada documento en cada ranking. Estándar de la industria
    #      para combinar rankings sin necesidad de score normalization.
    #
    # OUTPUT INCLUYE:
    #   - matches: top-K chunks con breadcrumb + content + metadata
    #   - threshold_passed: bool, hay al menos 1 match "fuerte"
    #   - best_vector_distance: para que el LLM ajuste confidence
    #   - vector_rank / keyword_rank por chunk: explicabilidad
    class SearchKnowledgeBase < BaseTool
      TOP_K_DEFAULT          = 5
      OVER_FETCH_FACTOR      = 2          # fetch 2x para alimentar la fusión
      RRF_K                  = 60         # constante estándar de RRF
      # Cosine distance < threshold = match fuerte. Calibrado empíricamente:
      # con KB en inglés y queries naturales en español chileno, distances
      # típicas para matches semánticamente correctos quedan entre 0.55-0.65
      # por el costo del cross-lingual. Si la KB se ingesta traducida al
      # español, este threshold puede bajar a 0.50.
      STRONG_MATCH_THRESHOLD = 0.65
      MAX_CONTENT_PREVIEW    = 800        # truncar content devuelto al LLM

      class << self
        def tool_name
          "search_knowledge_base"
        end

        def description
          <<~TXT.strip
            Busca en los manuales técnicos del taller (códigos DTC, manuales de
            servicio, guías internas) usando una query en lenguaje natural.

            CUÁNDO LLAMAR:
            - Cuando el motivo de ingreso menciona síntomas que pueden mapear a
              códigos DTC ("check engine", "tirita", "se calienta", "no enciende")
            - Cuando aparece un código diagnóstico explícito ("P0301", "U0001")
            - Cuando necesitas validar una hipótesis de falla contra documentación

            BUENA QUERY: incluye los términos técnicos del motivo
            ("tirita y check engine encendido", "P0742", "frenos chillan").
            Evita queries genéricas ("problemas con el auto").

            OUTPUT: top-K chunks con breadcrumb, content y score. Si
            threshold_passed es false, los matches son débiles — baja tu
            confidence y NO cites estos chunks como evidencia firme.
          TXT
        end

        def input_schema
          # strict: true en OpenAI requiere que required incluya TODAS las
          # properties. top_k no es genuinamente opcional acá — el modelo
          # debe pasarlo, sugerimos 5 en el description.
          {
            type: "object",
            additionalProperties: false,
            required: %w[query top_k],
            properties: {
              query: {
                type: "string",
                description: "Query en lenguaje natural o código DTC. Ej: 'check engine y tirita', 'P0301', 'frenos chillan'."
              },
              top_k: {
                type: "integer",
                description: "Cantidad de chunks a devolver. Default sensato: 5. Subir a 8-10 si la query es ambigua o querés más cobertura."
              }
            }
          }
        end
      end

      def call(query:, top_k: TOP_K_DEFAULT)
        return empty_result(query) if query.blank?

        started_at  = Time.current
        over_fetch  = top_k * OVER_FETCH_FACTOR

        vec_results, embedding_tokens = vector_search_with_metrics(query, limit: over_fetch)
        kw_results                    = keyword_search(query, limit: over_fetch)

        fused = reciprocal_rank_fusion(vec_results, kw_results, top_k: top_k)

        strong_matches = fused.count do |m|
          m[:vector_distance] && m[:vector_distance] < STRONG_MATCH_THRESHOLD
        end

        best_distance    = fused.filter_map { |m| m[:vector_distance] }.min
        threshold_passed = strong_matches >= 1
        latency_ms       = ((Time.current - started_at) * 1000).round

        # Persistir el RetrievalRun para observabilidad (best-effort: si
        # falla por cualquier razón, NO rompemos la búsqueda — el LLM
        # igual recibe los resultados).
        persist_retrieval_run(
          query:                query,
          top_k:                top_k,
          fused:                fused,
          total_matches:        fused.size,
          strong_matches_count: strong_matches,
          threshold_passed:     threshold_passed,
          best_vector_distance: best_distance,
          latency_ms:           latency_ms,
          embedding_tokens:     embedding_tokens
        )

        {
          query:                query,
          matches:              fused.map { |m| format_match(m) },
          total_matches:        fused.size,
          strong_matches_count: strong_matches,
          best_vector_distance: best_distance,
          threshold_passed:     threshold_passed
        }
      end

      private

      def vector_search_with_metrics(query, limit:)
        embed_result = Ai::Ingestion::BatchEmbedder.call([ query ])
        embedding    = embed_result[:embeddings].first
        tokens       = embed_result[:total_tokens]

        results = ready_chunks
                    .nearest_neighbors(:embedding, embedding, distance: "cosine")
                    .limit(limit)
                    .each_with_index
                    .map { |c, rank| { chunk: c, vector_rank: rank, vector_distance: c.neighbor_distance } }

        [ results, tokens ]
      end

      def keyword_search(query, limit:)
        # Usamos plainto_tsquery porque acepta input arbitrario sin
        # necesidad de escapar operadores. Ranking via ts_rank con boost
        # implícito en breadcrumb (setweight 'A' en la migration).
        sanitized = ActiveRecord::Base.connection.quote(query)
        rank_expr = "ts_rank(content_tsv, plainto_tsquery('spanish', #{sanitized}))"

        ready_chunks
          .where("content_tsv @@ plainto_tsquery(?, ?)", "spanish", query)
          .order(Arel.sql("#{rank_expr} DESC"))
          .limit(limit)
          .each_with_index
          .map { |c, rank| { chunk: c, keyword_rank: rank } }
      end

      def ready_chunks
        KnowledgeChunk
          .joins(:knowledge_document)
          .where(knowledge_documents: { status: "ready" })
      end

      # RRF: para cada chunk, score = Σ 1/(K + rank_i + 1)
      # +1 porque rank empieza en 0 en nuestro código, RRF asume 1-indexed.
      def reciprocal_rank_fusion(vec_results, kw_results, top_k:)
        scores = Hash.new(0.0)
        chunks = {}
        meta   = Hash.new { |h, k| h[k] = {} }

        vec_results.each do |r|
          id = r[:chunk].id
          scores[id] += 1.0 / (RRF_K + r[:vector_rank] + 1)
          chunks[id] = r[:chunk]
          meta[id][:vector_rank]     = r[:vector_rank]
          meta[id][:vector_distance] = r[:vector_distance]
        end

        kw_results.each do |r|
          id = r[:chunk].id
          scores[id] += 1.0 / (RRF_K + r[:keyword_rank] + 1)
          chunks[id] ||= r[:chunk]
          meta[id][:keyword_rank] = r[:keyword_rank]
        end

        scores
          .sort_by { |_, s| -s }
          .first(top_k)
          .each_with_index
          .map do |(id, score), fused_rank|
            {
              chunk:       chunks[id],
              fused_rank:  fused_rank,
              fused_score: score,
              **meta[id]
            }
          end
      end

      def format_match(m)
        chunk = m[:chunk]
        {
          breadcrumb:      chunk.breadcrumb,
          content:         chunk.content.truncate(MAX_CONTENT_PREVIEW),
          document_title:  chunk.knowledge_document.title,
          page:            chunk.page_number,
          dtc_code:        chunk.metadata["dtc_code"],
          fused_rank:      m[:fused_rank],
          fused_score:     m[:fused_score].round(4),
          vector_distance: m[:vector_distance]&.round(3),
          vector_rank:     m[:vector_rank],
          keyword_rank:    m[:keyword_rank]
        }
      end

      def empty_result(query)
        {
          query:                query,
          matches:              [],
          total_matches:        0,
          strong_matches_count: 0,
          best_vector_distance: nil,
          threshold_passed:     false
        }
      end

      # Best-effort: si el agent_run no está en el context (caso de
      # invocación directa fuera del agent loop), o si el insert falla,
      # NO rompemos la búsqueda. El LLM igual recibe sus matches.
      def persist_retrieval_run(query:, top_k:, fused:, total_matches:,
                                strong_matches_count:, threshold_passed:,
                                best_vector_distance:, latency_ms:, embedding_tokens:)
        agent_run = context[:agent_run]
        return if agent_run.nil?

        results_payload = fused.map do |m|
          {
            chunk_id:        m[:chunk]&.id,
            vector_rank:     m[:vector_rank],
            keyword_rank:    m[:keyword_rank],
            vector_distance: m[:vector_distance]&.round(4),
            fused_rank:      m[:fused_rank],
            fused_score:     m[:fused_score].round(6)
          }
        end

        RetrievalRun.create!(
          agent_run:            agent_run,
          query:                query,
          top_k:                top_k,
          total_matches:        total_matches,
          strong_matches_count: strong_matches_count,
          threshold_passed:     threshold_passed,
          best_vector_distance: best_vector_distance,
          results:              results_payload,
          latency_ms:           latency_ms,
          embedding_tokens:     embedding_tokens
        )
      rescue => e
        # Loggeamos pero NO propagamos — la observabilidad no debe
        # tumbar el feature principal (la búsqueda).
        Rails.logger.warn(
          "[SearchKnowledgeBase] no pude persistir RetrievalRun: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
