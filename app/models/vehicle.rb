class Vehicle < ApplicationRecord
  has_many :work_orders, dependent: :destroy

  validates :patente, presence: true, uniqueness: { case_sensitive: false }
  validates :year,
            numericality: { only_integer: true, greater_than: 1900 },
            allow_nil: true

  before_validation :normalize_patente

  # Returns previous work orders for this vehicle (excluding the one
  # passed in AND any cancelled order), ordered most recent first.
  # Used as context for the diagnostic agent: a cancelled OT never
  # made it to actual mechanic work, so it's noise (or misleading
  # "history") for the LLM. We strip it out at the source.
  def history_excluding(work_order)
    work_orders
      .where.not(id: work_order&.id)
      .where.not(status: "cancelled")
      .order(created_at: :desc)
  end

  private

  def normalize_patente
    self.patente = patente.to_s.upcase.gsub(/\s+/, "").presence
  end
end
