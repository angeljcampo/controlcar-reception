module WorkOrdersHelper
  # Pill colors aligned with the latest Stitch reference: mixed case
  # (no uppercase), rounded-full, slightly bigger horizontal padding.
  PRIORITY_CLASSES = {
    "low"      => "bg-green-100 text-green-800",
    "medium"   => "bg-amber-100 text-amber-800",
    "high"     => "bg-error-container text-error",
    "critical" => "bg-error-container text-error"
  }.freeze

  # Each status gets a light bg + dark text pair so the pill stays legible
  # against the page surface. The colors also encode meaning:
  #   draft     = neutral gray (not started)
  #   analyzing = blue (in progress)
  #   analyzed  = green (done / success)
  #   in_review = amber (needs human attention)
  #   cancelled = red (discarded — uses MD3 error-container tokens)
  STATUS_CLASSES = {
    "draft"     => "bg-surface-container-high text-on-surface-variant",
    "analyzing" => "bg-blue-100 text-blue-700",
    "analyzed"  => "bg-green-100 text-green-800",
    "in_review" => "bg-amber-100 text-amber-800",
    "cancelled" => "bg-error-container text-on-error-container"
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
