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

# ─── Knowledge base: PDFs precargados ────────────────────────────────
# Idempotente. Si el documento ya existe Y está :ready, no hacemos nada.
# Si está :failed o :pending, lo re-ingestamos.
#
# El ingest es SÍNCRONO al seedear (perform_now) para que `db:seed`
# deje la app lista para usar — el evaluador no tiene que esperar
# Sidekiq ni subir nada manualmente.
#
# Tiempo esperado: ~10 minutos con traducción (DTC_Codes son 147 págs).
# Para iterar rápido localmente, exportá SKIP_KB_TRANSLATE=1 antes de
# correr seeds — se ingesta en inglés (recall semántico bajo pero
# keyword search sigue funcionando).
KB_DOCUMENTS = [
  {
    filename:           "DTC_Codes.pdf",
    title:              "Códigos DTC OBD-II (Ford 2007 PCED)",
    chunking_strategy:  :structured_dtc,
    # En inglés. Si SKIP_KB_TRANSLATE=1 o falla traducción se ingesta tal cual
    # — keyword search por código DTC funciona igual.
    needs_translation:  true
  },
  {
    filename:           "PCS_Diagnostic_Codes.pdf",
    title:              "PCS Diagnostic Codes (Transmisión)",
    chunking_strategy:  :token_window,
    needs_translation:  true
  },
  {
    filename:           "Denton_Diagnostico_Automotriz.pdf",
    title:              "Diagnóstico Avanzado de Fallas Automotrices (Tom Denton, 3ra ed)",
    chunking_strategy:  :token_window,
    # YA está en español → siempre skip translation, ingest rápido + distances
    # de retrieval más bajas para queries naturales en español chileno.
    needs_translation:  false
  }
].freeze

translate = ENV["SKIP_KB_TRANSLATE"].blank?
seed_dir  = Rails.root.join("db/seed_pdfs")

KB_DOCUMENTS.each do |entry|
  path = seed_dir.join(entry[:filename])
  unless path.exist?
    warn "  ⚠️  #{entry[:filename]} no encontrado en db/seed_pdfs/, skipping"
    next
  end

  doc = KnowledgeDocument.find_or_initialize_by(title: entry[:title])
  if doc.persisted? && doc.ready?
    puts "  ✓ #{entry[:title]} ya está ready (#{doc.total_chunks} chunks), skipping"
    next
  end

  doc.chunking_strategy = entry[:chunking_strategy]
  doc.status            = "pending"
  doc.error_message     = nil
  doc.save!

  doc.file.attach(
    io:           File.open(path),
    filename:     entry[:filename],
    content_type: "application/pdf"
  ) unless doc.file.attached?

  # Si el doc YA está en español, nunca traducir, sin importar el flag global.
  effective_translate = translate && entry[:needs_translation]

  print "  → Ingesta de #{entry[:title]}#{effective_translate ? ' (con traducción ES)' : ' (sin traducción)'}... "
  t = Time.now
  IngestPdfJob.perform_now(doc.id, translate: effective_translate)
  elapsed = ((Time.now - t)).round
  doc.reload
  if doc.ready?
    puts "✓ #{doc.total_chunks} chunks en #{elapsed}s"
  else
    puts "✗ falló: #{doc.error_message}"
  end
end

puts "KnowledgeBase seedeada. Documents: #{KnowledgeDocument.count}, Chunks: #{KnowledgeChunk.count}."
