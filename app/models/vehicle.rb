class Vehicle < ApplicationRecord
  has_many :work_orders, dependent: :destroy

  validates :patente, presence: true, uniqueness: { case_sensitive: false }
  validates :year,
            numericality: { only_integer: true, greater_than: 1900 },
            allow_nil: true

  before_validation :normalize_patente

  # Returns previous work orders for this vehicle (excluding the one passed in),
  # ordered most recent first. Used as context for the diagnostic agent.
  def history_excluding(work_order)
    work_orders.where.not(id: work_order&.id).order(created_at: :desc)
  end

  private

  def normalize_patente
    self.patente = patente.to_s.upcase.gsub(/\s+/, "").presence
  end
end
