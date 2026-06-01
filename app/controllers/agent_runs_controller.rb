class AgentRunsController < ApplicationController
  # GET /work_orders/:work_order_id/agent_runs
  # Renders inside the Turbo Frame `agent_runs_panel` on the OT show page,
  # but also works as a standalone full-page list if visited directly.
  def index
    @work_order = WorkOrder.find(params[:work_order_id])
    @agent_runs = @work_order.agent_runs.order(created_at: :desc)
  end
end
