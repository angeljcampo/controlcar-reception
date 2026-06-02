module WorkOrdersHelper
  # Pill colors for the Garage (dark) theme. Each pair is a saturated-dark
  # background + light text so the pill stays legible on the dark panels
  # (#11161E). `/40` opacity on the bg gives a tinted glass feel.
  PRIORITY_CLASSES = {
    "low"      => "bg-emerald-900/50 text-emerald-300 border border-emerald-500/30",
    "medium"   => "bg-amber-900/50 text-amber-300 border border-amber-500/30",
    "high"     => "bg-red-900/50 text-red-300 border border-red-500/30",
    "critical" => "bg-red-900/60 text-red-200 border border-red-500/40"
  }.freeze

  # Status semantics (dark theme):
  #   draft     = neutral zinc (not started)
  #   analyzing = blue tint (in progress)
  #   analyzed  = lime tint (success — matches the Garage accent)
  #   in_review = amber tint (needs human attention)
  #   cancelled = red tint (discarded)
  STATUS_CLASSES = {
    "draft"     => "bg-zinc-700/50 text-zinc-300 border border-zinc-500/30",
    "analyzing" => "bg-blue-900/50 text-blue-300 border border-blue-500/30",
    "analyzed"  => "bg-lime-900/40 text-lime-300 border border-lime-500/30",
    "in_review" => "bg-amber-900/50 text-amber-300 border border-amber-500/30",
    "cancelled" => "bg-red-900/50 text-red-300 border border-red-500/30"
  }.freeze

  def priority_badge(work_order)
    pill(work_order.priority_label, PRIORITY_CLASSES[work_order.priority])
  end

  # "Alta Prioridad", "Media Prioridad", etc. for the header card pill.
  def priority_with_suffix_badge(work_order)
    pill("#{work_order.priority_label} #{t('work_orders.show.priority_suffix')}",
         PRIORITY_CLASSES[work_order.priority])
  end

  def status_badge(work_order)
    pill(work_order.status_label, STATUS_CLASSES[work_order.status])
  end

  # Renders a priority pill from a raw enum value (e.g. AiAnalysis#suggested_priority)
  # without needing a WorkOrder instance.
  def priority_badge_for(priority_value)
    return nil if priority_value.blank?

    label = I18n.t("enums.work_order.priority.#{priority_value}",
                   default: priority_value.to_s.humanize)
    pill(label, PRIORITY_CLASSES.fetch(priority_value, "bg-zinc-100 text-zinc-700"))
  end

  private

  # Rounded-full pill, mixed case, label-md (12px / 600 / 0.05em tracking).
  def pill(text, color_classes)
    tag.span(text,
             class: "inline-flex items-center px-3 py-1 rounded-full text-label-md #{color_classes}")
  end
end
