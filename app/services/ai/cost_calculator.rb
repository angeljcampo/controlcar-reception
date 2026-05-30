module Ai
  # Translates token counts into a cents-based cost for the AgentRun
  # observability snapshot. Pricing is hard-coded per model and lives here
  # as the single source of truth — update when OpenAI changes the rates.
  #
  # Returns nil for unknown models (caller decides how to fall back).
  module CostCalculator
    # USD per 1,000,000 tokens, per OpenAI pricing for GPT-5.
    PRICING = {
      "gpt-5" => { input: 3.00, output: 15.00 }
    }.freeze

    def self.cents_for(model:, input_tokens:, output_tokens:)
      price = PRICING[model]
      return nil unless price

      input_cents  = (input_tokens.to_f  / 1_000_000.0) * price[:input]  * 100
      output_cents = (output_tokens.to_f / 1_000_000.0) * price[:output] * 100
      (input_cents + output_cents).round
    end
  end
end
