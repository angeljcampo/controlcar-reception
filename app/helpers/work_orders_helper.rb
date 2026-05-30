module WorkOrdersHelper
  PRIORITY_CLASSES = {
    "low"      => "bg-green-100 text-green-800",
    "medium"   => "bg-yellow-100 text-yellow-800",
    "high"     => "bg-orange-100 text-orange-800",
    "critical" => "bg-red-100 text-red-800"
  }.freeze

  STATUS_CLASSES = {
    "draft"     => "bg-zinc-100 text-zinc-700",
    "analyzing" => "bg-blue-100 text-blue-700",
    "analyzed"  => "bg-emerald-100 text-emerald-700",
    "in_review" => "bg-amber-100 text-amber-700"
  }.freeze

  def priority_badge(work_order)
    badge(work_order.priority_label, PRIORITY_CLASSES[work_order.priority])
  end

  def status_badge(work_order)
    badge(work_order.status_label, STATUS_CLASSES[work_order.status])
  end

  private

  def badge(text, color_classes)
    tag.span(text,
             class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_classes}")
  end
end
