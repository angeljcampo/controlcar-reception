module AgentRunsHelper
  # Small colored circle + glyph that visually distinguishes the three
  # AgentRun states in the timeline list.
  def agent_run_status_icon(run)
    case run.status
    when "succeeded"
      status_glyph("✓", "bg-emerald-100 text-emerald-700", label: t("agent_runs.status.succeeded"))
    when "failed"
      status_glyph("✗", "bg-red-100 text-red-700", label: t("agent_runs.status.failed"))
    when "running"
      status_glyph("⟳", "bg-blue-100 text-blue-700 animate-spin", label: t("agent_runs.status.running"))
    else
      status_glyph("?", "bg-zinc-100 text-zinc-600", label: run.status.to_s)
    end
  end

  private

  def status_glyph(glyph, color_classes, label:)
    tag.span(glyph,
             class: "inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-bold #{color_classes}",
             title: label,
             aria: { label: label })
  end
end
