class KnowledgeChunk < ApplicationRecord
  belongs_to :knowledge_document

  # neighbor gem: enables KnowledgeChunk.nearest_neighbors(:embedding, vector, distance: "cosine")
  has_neighbors :embedding

  validates :content, presence: true
end
