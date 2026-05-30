class WorkOrdersController < ApplicationController
  before_action :set_work_order, only: :show

  def index
    @work_orders = WorkOrder
      .includes(:vehicle, :ai_analysis)
      .order(created_at: :desc)
  end

  def show
  end

  def new
    @work_order = WorkOrder.new(priority: "medium")
  end

  def create
    patente = normalize_patente(params.dig(:work_order, :patente))

    if patente.blank?
      @work_order = WorkOrder.new(work_order_attrs.merge(patente: ""))
      @work_order.errors.add(:patente, "no puede estar vacía")
      return render :new, status: :unprocessable_entity
    end

    vehicle = Vehicle.find_or_create_by!(patente: patente)
    @work_order = vehicle.work_orders.new(work_order_attrs)
    @work_order.patente = patente

    if @work_order.save
      redirect_to @work_order, notice: "Orden de trabajo creada correctamente."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_work_order
    @work_order = WorkOrder
      .includes(:vehicle, :ai_analysis, :agent_runs, photos_attachments: :blob)
      .find(params[:id])
  end

  def work_order_attrs
    params.require(:work_order).permit(
      :customer_name, :mileage, :reason, :priority, photos: []
    )
  end

  def normalize_patente(raw)
    raw.to_s.upcase.gsub(/\s+/, "").presence
  end
end
