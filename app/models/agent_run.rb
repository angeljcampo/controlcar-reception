class AgentRun < ApplicationRecord
  STATUSES = %w[running succeeded failed].freeze

  belongs_to :work_order
  has_many :retrieval_runs, dependent: :destroy

  enum :status, STATUSES.index_by(&:itself)

  validates :agent_name, presence: true
end
