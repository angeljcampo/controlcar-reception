import { Controller } from "@hotwired/stimulus"

// Autofills vehicle metadata + last customer name when the user finishes
// typing a patente that already exists in the database. Also reveals a
// "Vehículo en tu base" banner with the patente + previous-OT meta.
//
// Wired by `data-controller="vehicle-lookup"` on the form, with targets:
//   patente, make, model, year, customerName,
//   banner, bannerPatente, bannerMeta.
// The patente input dispatches `change->vehicle-lookup#fetch` (fires on
// blur after the value changed) so we don't spam the server on every
// keystroke.
export default class extends Controller {
  static targets = [
    "patente", "make", "model", "year", "customerName",
    "banner", "bannerPatente", "bannerMeta"
  ]

  async fetch() {
    const patente = this.patenteTarget.value.trim()
    if (!patente) {
      this.#hideBanner()
      return
    }

    try {
      const response = await fetch(
        `/vehicles/lookup?patente=${encodeURIComponent(patente)}`,
        { headers: { "Accept": "application/json" } }
      )
      if (!response.ok) return

      const data = await response.json()
      if (!data.found) {
        this.#hideBanner()
        return
      }

      this.#fillIfEmpty(this.makeTarget, data.make)
      this.#fillIfEmpty(this.modelTarget, data.model)
      this.#fillIfEmpty(this.yearTarget, data.year)
      this.#fillIfEmpty(this.customerNameTarget, data.last_customer_name)

      this.#showBanner(patente, data)
    } catch (error) {
      // Network error or JSON parse failure — silently ignore. The form
      // still works manually, so a flaky network shouldn't break UX.
      console.warn("[vehicle-lookup] fetch failed:", error)
    }
  }

  #fillIfEmpty(input, value) {
    if (!input || !value) return
    if (input.value.trim() === "") input.value = value
  }

  // Surface a confirmation banner when the patente matches a known
  // vehicle. The meta line shows the stored make/model/year so the
  // recepcionista can verify at a glance that it's the right car.
  #showBanner(patente, data) {
    if (!this.hasBannerTarget) return
    this.bannerTarget.classList.remove("hidden")
    if (this.hasBannerPatenteTarget) this.bannerPatenteTarget.textContent = patente.toUpperCase()
    if (this.hasBannerMetaTarget) {
      const parts = [data.make, data.model, data.year].filter(Boolean)
      this.bannerMetaTarget.textContent = parts.length > 0
        ? parts.join(" · ")
        : "Datos cargados desde tu base"
    }
  }

  #hideBanner() {
    if (this.hasBannerTarget) this.bannerTarget.classList.add("hidden")
  }
}
