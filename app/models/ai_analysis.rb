class AiAnalysis < ApplicationRecord
  CATEGORIES = %w[
    engine transmission brakes suspension electrical
    cooling fuel exhaust tires body diagnosis_needed other
  ].freeze
  PRIORITIES = WorkOrder::PRIORITIES

  belongs_to :work_order

  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true
  validates :suggested_priority, inclusion: { in: PRIORITIES }, allow_nil: true
  validates :confidence,
            numericality: {
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: 1
            },
            allow_nil: true

  # True when the analysis flagged itself as low-confidence.
  def low_confidence?
    confidence.present? && confidence < 0.7
  end
end
