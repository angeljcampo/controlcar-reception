class MakeWorkOrderPriorityNullable < ActiveRecord::Migration[8.1]
  # Priority es autoridad EXCLUSIVA del LLM. Antes de que el agente
  # termine, no debería existir una prioridad (el badge "Media" antes
  # del análisis confundía al usuario haciéndolo creer que ya estaba
  # decidida).
  #
  # Cambios:
  #   - Permitir NULL (mientras el agente no terminó)
  #   - Quitar el default "medium" (forzaba un valor inventado)
  #
  # Filas existentes con priority pre-existente quedan intactas.
  def up
    change_column_default :work_orders, :priority, from: "medium", to: nil
    change_column_null    :work_orders, :priority, true
  end

  def down
    change_column_default :work_orders, :priority, from: nil, to: "medium"
    # Cualquier fila con priority null se vuelve "medium" al revertir
    # para mantener la NOT NULL constraint.
    execute "UPDATE work_orders SET priority = 'medium' WHERE priority IS NULL"
    change_column_null :work_orders, :priority, false
  end
end
