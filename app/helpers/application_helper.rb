module ApplicationHelper
  # Shared rounded badge used across helpers (priority, status, category,
  # probability, etc.). Keeps the Tailwind class string consistent.
  def ui_badge(text, color_classes)
    tag.span(text,
             class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color_classes}")
  end
end
