module WorkOrders
  class Create
    attr_reader :work_order

    def self.call(params) = new(params).call

    def initialize(params)
      @patente = normalize_patente(params[:patente])
      @attrs   = params.except(:patente)
    end

    def call
      if @patente.blank?
        @work_order = WorkOrder.new(@attrs)
        @work_order.errors.add(:patente, "no puede estar vacía")
        return self
      end

      vehicle = Vehicle.find_or_create_by!(patente: @patente)
      @work_order = vehicle.work_orders.new(@attrs)
      @work_order.patente = @patente
      @work_order.save
      self
    end

    def success? = @work_order&.persisted?

    private

    def normalize_patente(raw) = raw.to_s.upcase.gsub(/\s+/, "").presence
  end
end
