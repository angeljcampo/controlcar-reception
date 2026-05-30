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
    result = WorkOrders::Create.call(work_order_attrs)
    @work_order = result.work_order

    if result.success?
      redirect_to @work_order, notice: t(".success")
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
      :customer_name, :mileage, :reason, :priority, :patente, photos: []
    )
  end
end
