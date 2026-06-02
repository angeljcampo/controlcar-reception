class KnowledgeDocument < ApplicationRecord
  STATUSES            = %w[pending processing ready failed].freeze
  CHUNKING_STRATEGIES = %w[token_window structured_dtc].freeze

  has_many :knowledge_chunks, dependent: :destroy
  has_one_attached :file

  enum :status, STATUSES.index_by(&:itself)
  # prefix evita colisiones (ej. .token_window? vs .structured_dtc?).
  enum :chunking_strategy, CHUNKING_STRATEGIES.index_by(&:itself), prefix: true

  validates :title, presence: true
  validates :chunking_strategy, inclusion: { in: CHUNKING_STRATEGIES }
end
