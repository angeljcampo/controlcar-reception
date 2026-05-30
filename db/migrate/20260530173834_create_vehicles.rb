class CreateVehicles < ActiveRecord::Migration[8.1]
  def change
    create_table :vehicles do |t|
      t.string :patente, null: false
      t.string :make
      t.string :model
      t.integer :year

      t.timestamps
    end

    add_index :vehicles, :patente, unique: true
  end
end
