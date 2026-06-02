class VehiclesController < ApplicationController
  # JSON endpoint hit by the new-OT form when the user finishes typing a
  # patente. If we already have that vehicle on file, we send back its
  # metadata + the last non-cancelled customer name so the form can
  # autocomplete the empty fields. Cancelled OTs are skipped: their
  # customer name isn't a meaningful "last visitor" signal.
  def lookup
    patente = normalize_patente(params[:patente])

    if patente.blank?
      render json: { found: false }, status: :ok and return
    end

    vehicle = Vehicle.find_by("UPPER(patente) = ?", patente)

    if vehicle.nil?
      render json: { found: false }, status: :ok and return
    end

    last_active = vehicle.work_orders
                         .where.not(status: "cancelled")
                         .order(created_at: :desc)
                         .first

    render json: {
      found: true,
      make:  vehicle.make,
      model: vehicle.model,
      year:  vehicle.year,
      last_customer_name: last_active&.customer_name
    }
  end

  private

  def normalize_patente(raw)
    raw.to_s.upcase.gsub(/\s+/, "")
  end
end
