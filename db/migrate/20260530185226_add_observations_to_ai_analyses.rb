class AddObservationsToAiAnalyses < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_analyses, :observations, :text
  end
end
