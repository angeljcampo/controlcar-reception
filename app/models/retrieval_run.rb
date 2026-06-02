# frozen_string_literal: true

# Snapshot de UNA invocación a search_knowledge_base.
#
# Persistido por SearchKnowledgeBase#call cuando el agente lo invoca.
# Le da al evaluador un panel "el LLM buscó X, encontró Y, citó Z" en
# vez del black box típico de "el LLM decidió algo".
#
# Cada AgentRun puede tener N retrieval_runs (el LLM puede llamar la
# tool varias veces dentro del mismo análisis con queries distintas).
class RetrievalRun < ApplicationRecord
  belongs_to :agent_run

  has_one :work_order, through: :agent_run

  validates :query, :top_k, presence: true

  # Conveniencia para la vista: chunks únicos efectivamente fetchados,
  # ordenados por fused_rank.
  def matches
    results.sort_by { |r| r["fused_rank"].to_i }
  end
end
