class WorkOrdersController < ApplicationController
  before_action :set_work_order, only: %i[show reanalyze cancel]

  def index
    @work_orders = WorkOrder
      .includes(:vehicle, :ai_analysis)
      .order(created_at: :desc)
  end

  def show
  end

  def new
    # Priority queda en blanco hasta que el LLM lo decida en
    # AnalyzeWorkOrderJob. El form ya no expone el campo al usuario.
    @work_order = WorkOrder.new
  end

  def create
    result = WorkOrders::Create.call(work_order_attrs)
    @work_order = result.work_order

    if result.success?
      redirect_to @work_order, notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def reanalyze
    if @work_order.cancelled?
      redirect_to @work_order, alert: t("work_orders.cancel.cannot_reanalyze") and return
    end

    @work_order.update!(status: "analyzing")
    AnalyzeWorkOrderJob.perform_later(@work_order.id)
    redirect_to @work_order, notice: t(".queued")
  end

  def cancel
    if @work_order.cancelled?
      redirect_to @work_order, alert: t(".already_cancelled") and return
    end

    @work_order.update!(status: "cancelled")
    redirect_to work_orders_path, notice: t(".success")
  end

  private

  def set_work_order
    @work_order = WorkOrder
      .includes(:vehicle, :ai_analysis, :agent_runs, photos_attachments: :blob)
      .find(params[:id])
  end

  def work_order_attrs
    # `:priority` is intentionally NOT permitted — the LLM owns that
    # field. `:make`/`:model`/`:year` are virtual attrs on WorkOrder
    # that the create service forwards onto the Vehicle so the LLM
    # gets actual metadata instead of nulls in get_vehicle_history.
    params.require(:work_order).permit(
      :customer_name, :mileage, :reason, :patente,
      :make, :model, :year,
      photos: []
    )
  end
end
