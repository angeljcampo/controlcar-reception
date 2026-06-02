module WorkOrders
  class Create
    attr_reader :work_order

    def self.call(params) = new(params).call

    def initialize(params)
      @patente = normalize_patente(params[:patente])
      # Pull make/model/year out so they don't get passed to WorkOrder
      # (they live on Vehicle). Blanks are dropped so re-submitting the
      # form with empty vehicle fields doesn't wipe data already saved
      # on a returning vehicle.
      @vehicle_attrs = {
        make:  params[:make].presence,
        model: params[:model].presence,
        year:  params[:year].presence
      }.compact
      @attrs = params.except(:patente, :make, :model, :year)
    end

    def call
      if @patente.blank?
        @work_order = WorkOrder.new(@attrs)
        # :blank resolves to I18n key activerecord.errors.models.work_order
        # .attributes.patente.blank ("no puede estar vacía") via the locale.
        @work_order.errors.add(:patente, :blank)
        return self
      end

      vehicle = Vehicle.find_or_create_by!(patente: @patente)
      # Persist vehicle metadata from the form. compact above means we
      # only set/update non-blank values — empty fields don't null out
      # existing data on a returning vehicle.
      vehicle.update!(@vehicle_attrs) if @vehicle_attrs.any?

      @work_order = vehicle.work_orders.new(@attrs)
      @work_order.patente = @patente

      enqueue_analysis if @work_order.save

      self
    end

    def success? = @work_order&.persisted?

    private

    def normalize_patente(raw) = raw.to_s.upcase.gsub(/\s+/, "").presence

    # Flip to "analyzing" and queue the AI analysis. Done synchronously
    # so the show page renders the spinner immediately on redirect.
    def enqueue_analysis
      @work_order.update!(status: "analyzing")
      AnalyzeWorkOrderJob.perform_later(@work_order.id)
    end
  end
end
