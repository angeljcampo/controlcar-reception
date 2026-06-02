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

  connect() {
    // Remember the last patente we resolved so we can tell apart "user
    // is still editing the same plate" from "user typed a different
    // plate". On a different plate, we overwrite the previously auto-
    // filled fields instead of leaving stale data from the old lookup.
    this._lastResolvedPatente = null
  }

  async fetch() {
    const raw = this.patenteTarget.value.trim()
    const patente = raw.toUpperCase()

    if (!patente) {
      this.#hideBanner()
      this._lastResolvedPatente = null
      return
    }

    // Same patente as last successful lookup? Skip — no need to re-fetch
    // or re-flash the banner on every blur.
    if (patente === this._lastResolvedPatente) return

    try {
      const response = await fetch(
        `/vehicles/lookup?patente=${encodeURIComponent(patente)}`,
        { headers: { "Accept": "application/json" } }
      )
      if (!response.ok) return

      const data = await response.json()

      if (!data.found) {
        // Patente nueva pero NO está en la BD. Si antes habíamos llenado
        // los campos con datos de OTRA patente, los limpiamos para que
        // no queden datos engañosos del lookup anterior.
        this.#hideBanner()
        if (this._lastResolvedPatente !== null) {
          this.#clearAll()
        }
        this._lastResolvedPatente = null
        return
      }

      // Patente encontrada: sobrescribimos siempre los campos auto-
      // completables con lo que devuelve la BD. Si el user había
      // editado algo a mano, lo pisamos — el supuesto es que la patente
      // es la fuente de verdad y el resto de los datos viene de ahí.
      this.#setValue(this.makeTarget, data.make)
      this.#setValue(this.modelTarget, data.model)
      this.#setValue(this.yearTarget, data.year)
      this.#setValue(this.customerNameTarget, data.last_customer_name)

      this.#showBanner(patente, data)
      this._lastResolvedPatente = patente
    } catch (error) {
      // Network error or JSON parse failure — silently ignore. The form
      // still works manually, so a flaky network shouldn't break UX.
      console.warn("[vehicle-lookup] fetch failed:", error)
    }
  }

  // Setea el valor del input (sobreescribiendo lo que haya) cuando hay
  // un value real desde el lookup. Si la BD no tiene un dato (e.g.
  // make=null para un vehículo viejo), no escribe "null" — deja lo
  // que ya esté.
  #setValue(input, value) {
    if (!input) return
    if (value === null || value === undefined || value === "") return
    input.value = value
  }

  // Limpia los campos auto-completables. Se llama cuando la patente
  // cambia a una que no existe en la BD — así no se mezclan datos de
  // un vehículo viejo con la patente nueva del user.
  #clearAll() {
    [this.makeTarget, this.modelTarget, this.yearTarget, this.customerNameTarget]
      .filter(Boolean)
      .forEach((el) => { el.value = "" })
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
