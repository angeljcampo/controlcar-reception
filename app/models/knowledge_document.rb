class KnowledgeDocument < ApplicationRecord
  STATUSES = %w[pending processing ready failed].freeze

  has_many :knowledge_chunks, dependent: :destroy
  has_one_attached :file

  enum :status, STATUSES.index_by(&:itself)

  validates :title, presence: true
end
