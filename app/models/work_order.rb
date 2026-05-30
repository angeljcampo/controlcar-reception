class WorkOrder < ApplicationRecord
  PRIORITIES = %w[low medium high critical].freeze
  STATUSES = %w[draft analyzing analyzed in_review].freeze

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

  # Human labels for enum values, fed by config/locales/es.yml under
  # `enums.work_order.{priority,status}`.
  def priority_label = I18n.t("enums.work_order.priority.#{priority}", default: priority.to_s.humanize)
  def status_label   = I18n.t("enums.work_order.status.#{status}", default: status.to_s.humanize)

  # Convenience: fetch the latest agent run for display purposes.
  def latest_agent_run
    agent_runs.order(created_at: :desc).first
  end
end
