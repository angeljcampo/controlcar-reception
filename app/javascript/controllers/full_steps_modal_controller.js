import { Controller } from "@hotwired/stimulus"

// Opens a native <dialog> showing the full diagnosis steps timeline.
// ESC and backdrop click close it (native <dialog> + backdropClick handler).
//
// Wired up by `data-controller="full-steps-modal"` on the wrapping element,
// with a single `dialog` target pointing at the <dialog>.
export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    event.preventDefault()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // Clicks on the dialog element itself (the backdrop area) close it.
  // Clicks on inner content bubble up but don't match this condition.
  backdropClick(event) {
    if (event.target === this.dialogTarget) {
      this.dialogTarget.close()
    }
  }
}
