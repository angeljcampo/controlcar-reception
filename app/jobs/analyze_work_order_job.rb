class AnalyzeWorkOrderJob < ApplicationJob
  # Dedicated queue so concurrency caps for OpenAI calls don't starve
  # other background work (and vice versa).
  queue_as :ai

  # Configuration errors don't get retried — fix the env var and re-enqueue.
  discard_on Ai::Providers::OpenAIProvider::MissingApiKey

  # Transient provider/network failures: retry up to 3 times with backoff.
  retry_on Ai::Providers::OpenAIProvider::ApiError,
           Ai::Agents::BaseAgent::MaxIterationsExceeded,
           Net::ReadTimeout,
           wait: 10.seconds,
           attempts: 3

  # @param work_order_id [Integer]
  def perform(work_order_id)
    work_order = WorkOrder.find(work_order_id)
    work_order.update!(status: "analyzing") unless work_order.analyzing?
    broadcast_safely(work_order)

    analysis_args = run_agent(work_order)

    work_order.transaction do
      persist_analysis(work_order, analysis_args)
      work_order.update!(status: "analyzed")
    end

    # Post-success broadcast is best-effort. A flaky cable connection
    # must not undo the successful persistence above, so we swallow
    # errors here (status stays "analyzed").
    broadcast_safely(work_order.reload)
  rescue => e
    # Real failure path: agent or persistence raised. Roll back to "draft"
    # so the UI shows the OT as not-analyzed (the user can re-trigger).
    work_order&.update(status: "draft")
    broadcast_safely(work_order.reload) if work_order
    raise
  end

  private

  def run_agent(work_order)
    agent = Ai::Agents::MechanicDiagnosticAgent.new(
      provider: Ai::Providers::OpenAIProvider.new,
      context:  { work_order: work_order }
    )
    agent.run
  end

  def persist_analysis(work_order, args)
    analysis = work_order.ai_analysis || work_order.build_ai_analysis
    analysis.assign_attributes(
      category:              args[:category],
      possible_failures:     args[:possible_failures] || [],
      suggested_priority:    args[:priority],
      priority_reason:       args[:priority_reason],
      next_steps:            args[:next_steps] || [],
      sources:               args[:sources] || [],
      confidence:            args[:confidence],
      requires_human_review: args[:requires_human_review] || false,
      observations:          args[:observations]
    )
    analysis.save!
  end

  # Push the current analysis UI to the WorkOrder's Turbo Stream channel.
  # The show page subscribes via `turbo_stream_from @work_order`, so any
  # connected browser updates without a page reload. Wrapped in
  # broadcast_safely so a cable hiccup doesn't propagate as a job error.
  def broadcast_safely(work_order)
    Turbo::StreamsChannel.broadcast_replace_to(
      work_order,
      target:  ActionView::RecordIdentifier.dom_id(work_order, :analysis),
      partial: "work_orders/ai_analysis_state",
      locals:  { work_order: work_order }
    )
  rescue => e
    Rails.logger.warn("[AnalyzeWorkOrderJob] broadcast failed for WO #{work_order.id}: #{e.class}: #{e.message}")
  end
end
