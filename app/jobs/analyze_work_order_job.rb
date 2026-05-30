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
    work_order.update!(status: "analyzing")

    analysis_args = run_agent(work_order)

    work_order.transaction do
      persist_analysis(work_order, analysis_args)
      work_order.update!(status: "analyzed")
    end
  rescue => e
    # Roll the WorkOrder back to draft so the UI shows it as not-analyzed.
    # The full error trail (stack, retries) is in the AgentRun row and the
    # Sidekiq retry tab.
    work_order&.update(status: "draft")
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
end
