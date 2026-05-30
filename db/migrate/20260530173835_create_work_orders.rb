class CreateWorkOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :work_orders do |t|
      t.references :vehicle, null: false, foreign_key: true
      t.string :customer_name, null: false
      t.integer :mileage
      t.text :reason, null: false
      t.string :priority, null: false, default: "medium"
      t.string :status, null: false, default: "draft"

      t.timestamps
    end

    add_index :work_orders, :status
    add_index :work_orders, :created_at
  end
end
