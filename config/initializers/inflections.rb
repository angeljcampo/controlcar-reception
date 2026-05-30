# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# Acronyms used in class/module names so they capitalize correctly under
# Zeitwerk autoload and Rails helpers (humanize, titleize, etc.).
# Note: we deliberately do NOT add "AI" as an acronym — that would force
# AiAnalysis to become AIAnalysis and break existing model autoload.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "OpenAI"
end
