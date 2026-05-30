# Idempotent seed: 3 demo work orders covering different priorities and
# real-world symptom phrasings. Useful for visually validating the index
# and detail views without going through the form.

samples = [
  {
    patente: "AB1234",
    make: "Toyota",
    model: "Corolla",
    year: 2018,
    customer_name: "Juan Pérez",
    mileage: 85_000,
    reason: "Vehículo tirita en ralentí y se enciende la luz de check engine cuando acelero en pendientes. Empezó hace una semana.",
    priority: "high"
  },
  {
    patente: "CD5678",
    make: "Chevrolet",
    model: "Spark",
    year: 2020,
    customer_name: "María González",
    mileage: 42_300,
    reason: "Chequeo general por kilometraje (próximo cambio de aceite y filtros).",
    priority: "low"
  },
  {
    patente: "EF9012",
    make: "Hyundai",
    model: "Tucson",
    year: 2019,
    customer_name: "Carlos Soto",
    mileage: 118_500,
    reason: "Frenos chillan al frenar a baja velocidad. Pedal se siente más blando que antes.",
    priority: "critical"
  }
]

samples.each do |sample|
  vehicle = Vehicle.find_or_create_by!(patente: sample[:patente]) do |v|
    v.make  = sample[:make]
    v.model = sample[:model]
    v.year  = sample[:year]
  end

  # Skip if this vehicle already has a work order with the same reason
  # (avoids re-seeding duplicates on every db:seed run).
  next if vehicle.work_orders.exists?(reason: sample[:reason])

  vehicle.work_orders.create!(
    customer_name: sample[:customer_name],
    mileage:       sample[:mileage],
    reason:        sample[:reason],
    priority:      sample[:priority],
    status:        "draft"
  )
end

puts "Seed completo. WorkOrders: #{WorkOrder.count}. Vehicles: #{Vehicle.count}."
