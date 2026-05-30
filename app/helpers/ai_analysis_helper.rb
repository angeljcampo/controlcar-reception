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

  PROBABILITY_CLASSES = {
    "high"   => "bg-red-50 text-red-700 border border-red-200",
    "medium" => "bg-yellow-50 text-yellow-700 border border-yellow-200",
    "low"    => "bg-green-50 text-green-700 border border-green-200"
  }.freeze

  def category_label(category)
    return nil if category.blank?

    I18n.t("enums.ai_analysis.category.#{category}", default: category.to_s.humanize)
  end

  def category_badge(analysis)
    return nil if analysis.category.blank?

    ui_badge(category_label(analysis.category),
             CATEGORY_CLASSES.fetch(analysis.category, "bg-zinc-100 text-zinc-700"))
  end

  def probability_label(probability)
    I18n.t("enums.ai_analysis.probability.#{probability}", default: probability.to_s.humanize)
  end

  def probability_badge(probability)
    ui_badge(probability_label(probability),
             PROBABILITY_CLASSES.fetch(probability, "bg-zinc-100 text-zinc-700"))
  end

  # Percent (0-100) for the confidence progress bar.
  def confidence_percentage(analysis)
    return 0 if analysis.confidence.blank?

    (analysis.confidence.to_f * 100).round
  end

  # Tailwind color class for the confidence bar based on the value.
  def confidence_bar_color(analysis)
    case analysis.confidence.to_f
    when 0...0.5 then "bg-red-500"
    when 0.5...0.7 then "bg-yellow-500"
    else "bg-emerald-500"
    end
  end

  # Formats cents as a short USD string, e.g. 5 → "$0.05", 250 → "$2.50".
  def format_cents(cents)
    return "—" if cents.nil?

    format("$%.2f", cents.to_i / 100.0)
  end
end
