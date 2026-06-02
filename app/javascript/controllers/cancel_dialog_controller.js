import { Controller } from "@hotwired/stimulus"

// Confirmation dialog for cancelling a WorkOrder. The trigger is a
// type=button outside the form; clicking it opens the native <dialog>,
// where the actual <form> POSTing to /work_orders/:id/cancel lives.
// This way the destructive action is gated by an explicit confirmation
// step instead of by the native (ugly) `window.confirm`.
//
// Wired by `data-controller="cancel-dialog"` with `dialog` target.
export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    event.preventDefault()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // Clicking the <dialog> element itself (the backdrop area) closes
  // the modal. Clicks inside the modal panel bubble up but don't
  // match this exact target, so they're left alone.
  backdropClick(event) {
    if (event.target === this.dialogTarget) {
      this.dialogTarget.close()
    }
  }
}
