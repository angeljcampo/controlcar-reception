import { Controller } from "@hotwired/stimulus"

// Opens a native <dialog> on demand and triggers the lazy Turbo Frame
// inside to fetch agent runs from the controller. Clicking the backdrop
// or pressing ESC closes it (both are native <dialog> behaviors).
//
// Wired up by `data-controller="agent-runs-modal"` on the wrapping div
// with targets `dialog` (the <dialog> element) and `frame` (the
// turbo-frame whose src we set on first open).
export default class extends Controller {
  static targets = ["dialog", "frame"]
  static values = { url: String }

  open(event) {
    event.preventDefault()

    // Set src only on first open so re-opening doesn't re-fetch.
    // To force a refresh, the user can close + click the icon again
    // with a different action; for now we cache.
    if (this.hasFrameTarget && !this.frameTarget.src) {
      this.frameTarget.src = this.urlValue
    }

    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // Click on the dialog element itself (not its inner content) closes
  // it — that's the area outside the modal panel.
  backdropClick(event) {
    if (event.target === this.dialogTarget) {
      this.dialogTarget.close()
    }
  }
}
