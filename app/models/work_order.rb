class WorkOrder < ApplicationRecord
  PRIORITIES = %w[low medium high critical].freeze
  STATUSES = %w[draft analyzing analyzed in_review].freeze

  PRIORITY_LABELS = {
    "low" => "Baja",
    "medium" => "Media",
    "high" => "Alta",
    "critical" => "Crítica"
  }.freeze

  STATUS_LABELS = {
    "draft" => "Borrador",
    "analyzing" => "Analizando",
    "analyzed" => "Analizado",
    "in_review" => "En revisión"
  }.freeze

  # Virtual attribute used by the form. The controller normalizes it and
  # find_or_creates the underlying Vehicle so the form looks like one entity.
  attr_accessor :patente

  belongs_to :vehicle
  has_one :ai_analysis, dependent: :destroy
  has_many :agent_runs, dependent: :destroy
  has_many_attached :photos

  enum :priority, PRIORITIES.index_by(&:itself)
  enum :status, STATUSES.index_by(&:itself)

  validates :customer_name, presence: true
  validates :reason, presence: true
  validates :mileage,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  def priority_label = PRIORITY_LABELS.fetch(priority, priority)
  def status_label   = STATUS_LABELS.fetch(status, status)

  # Convenience: fetch the latest agent run for display purposes.
  def latest_agent_run
    agent_runs.order(created_at: :desc).first
  end
end
