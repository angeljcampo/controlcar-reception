import { Controller } from "@hotwired/stimulus"

// Autofills vehicle metadata + last customer name when the user finishes
// typing a patente that already exists in the database. Only fills
// fields the user left empty so we never overwrite what they're typing.
//
// Wired by `data-controller="vehicle-lookup"` on the form, with targets:
//   patente, make, model, year, customerName.
// The patente input dispatches `change->vehicle-lookup#fetch` (fires on
// blur after the value changed) so we don't spam the server on every
// keystroke.
export default class extends Controller {
  static targets = ["patente", "make", "model", "year", "customerName"]

  async fetch() {
    const patente = this.patenteTarget.value.trim()
    if (!patente) return

    try {
      const response = await fetch(
        `/vehicles/lookup?patente=${encodeURIComponent(patente)}`,
        { headers: { "Accept": "application/json" } }
      )
      if (!response.ok) return

      const data = await response.json()
      if (!data.found) return

      this.#fillIfEmpty(this.makeTarget, data.make)
      this.#fillIfEmpty(this.modelTarget, data.model)
      this.#fillIfEmpty(this.yearTarget, data.year)
      this.#fillIfEmpty(this.customerNameTarget, data.last_customer_name)
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
}
