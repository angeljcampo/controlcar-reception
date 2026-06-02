module AiAnalysisHelper
  CATEGORY_CLASSES = {
    "engine"           => "bg-orange-100 text-orange-800",
    "transmission"     => "bg-purple-100 text-purple-800",
    "brakes"           => "bg-red-100 text-red-800",
    "suspension"       => "bg-blue-100 text-blue-800",
    "electrical"       => "bg-yellow-100 text-yellow-800",
    "cooling"          => "bg-cyan-100 text-cyan-800",
    "fuel"             => "bg-amber-100 text-amber-800",
    "exhaust"          => "bg-gray-100 text-gray-800",
    "tires"            => "bg-zinc-100 text-zinc-800",
    "body"             => "bg-pink-100 text-pink-800",
    "diagnosis_needed" => "bg-indigo-100 text-indigo-800",
    "other"            => "bg-zinc-100 text-zinc-700"
  }.freeze

  # Material Symbols Outlined icon names per mechanical category. The icon
  # is rendered as <span class="material-symbols-outlined">name</span>.
  CATEGORY_SYMBOLS = {
    "engine"           => "build",
    "transmission"     => "settings",
    "brakes"           => "brake_alert",
    "suspension"       => "directions_car",
    "electrical"       => "bolt",
    "cooling"          => "ac_unit",
    "fuel"             => "local_gas_station",
    "exhaust"          => "air",
    "tires"            => "trip_origin",
    "body"             => "directions_car",
    "diagnosis_needed" => "search",
    "other"            => "help_outline"
  }.freeze

  # Probability pill colors per the Stitch reference: no border, no dot,
  # bg-100 / text-800, uppercase 10px.
  PROBABILITY_CLASSES = {
    "high"   => "bg-red-100 text-red-800",
    "medium" => "bg-amber-100 text-amber-800",
    "low"    => "bg-green-100 text-green-800"
  }.freeze

  # Solid color for the ranked numeric circle next to each failure card.
  PROBABILITY_RING_BG = {
    "high"   => "bg-error text-on-error",
    "medium" => "bg-orange-500 text-white",
    "low"    => "bg-secondary text-on-secondary"
  }.freeze

  # Text color for the "ALTA/MEDIA/BAJA" label next to the failure title.
  PROBABILITY_LABEL_COLOR = {
    "high"   => "text-error",
    "medium" => "text-orange-500",
    "low"    => "text-secondary"
  }.freeze

  def category_label(category)
    return nil if category.blank?

    I18n.t("enums.ai_analysis.category.#{category}", default: category.to_s.humanize)
  end

  def category_symbol(category)
    CATEGORY_SYMBOLS.fetch(category, "help_outline")
  end

  # Stroke color for the confidence ring, bucketed the same way as the
  # old bar (<0.5 red, <0.7 yellow, ≥0.7 emerald).
  def confidence_stroke_class(analysis)
    case analysis.confidence.to_f
    when 0...0.5 then "stroke-red-500"
    when 0.5...0.7 then "stroke-amber-500"
    else "stroke-primary"
    end
  end

  def probability_label(probability)
    I18n.t("enums.ai_analysis.probability.#{probability}", default: probability.to_s.humanize)
  end

  # Uppercase status-style pill matching the Stitch reference (no dot,
  # no border, 10px bold uppercase).
  def probability_badge(probability)
    color_classes = PROBABILITY_CLASSES.fetch(probability, "bg-zinc-100 text-zinc-700")
    tag.span(probability_label(probability),
             class: "inline-flex items-center px-2 py-0.5 rounded-lg text-[10px] font-bold uppercase tracking-wide #{color_classes}")
  end

  # Background color class for the numbered circle next to each failure card.
  def probability_circle_class(probability)
    PROBABILITY_RING_BG.fetch(probability, "bg-zinc-400 text-white")
  end

  # Text color class for the ALTA/MEDIA/BAJA label next to the failure title.
  def probability_label_color(probability)
    PROBABILITY_LABEL_COLOR.fetch(probability, "text-on-surface-variant")
  end

  # Percent (0-100) for the confidence ring.
  def confidence_percentage(analysis)
    return 0 if analysis.confidence.blank?

    (analysis.confidence.to_f * 100).round
  end

  # Formats cents as a short USD string, e.g. 5 → "$0.05", 250 → "$2.50".
  def format_cents(cents)
    return "—" if cents.nil?

    format("$%.2f", cents.to_i / 100.0)
  end

  # Splits a free-text step "action" into a short heading + body. The
  # LLM often phrases steps as "Verb noun phrase: detail detail detail",
  # using either ":" or ";" as the natural split between the headline
  # and the explanation. We honour that split when it appears within
  # the first ~80 chars so the modal's <h3> stays scannable.
  # Returns [title, description]; title is nil when no clean split
  # exists so the view falls back to a description-only card.
  def split_step_action(action)
    return [nil, action.to_s] if action.blank?

    if (m = action.match(/\A(.{5,80}?)[:;]\s+(.+)\z/m))
      title = m[1].strip
      desc  = m[2].strip.sub(/\A./, &:upcase)
      return [title, desc]
    end

    [nil, action.to_s]
  end
end
