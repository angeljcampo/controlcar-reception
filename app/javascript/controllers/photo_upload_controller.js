import { Controller } from "@hotwired/stimulus"

// Visual feedback para el input de fotos de la OT.
//
// El file_field nativo de Rails está hidden detrás de un label .wof-drop.
// Sin JS, el usuario hace click → se abre el picker → selecciona archivos →
// no pasa nada visualmente (porque el input está hidden). Este controller
// renderiza thumbnails + permite remover archivos individualmente.
//
// HTML esperado:
//   <div data-controller="photo-upload">
//     <input type="file" data-photo-upload-target="input" multiple>
//     <label data-photo-upload-target="dropzone">…</label>
//     <div data-photo-upload-target="previews"></div>
//   </div>
//
// Caveat técnico: el FileList del input es inmutable. Para "quitar" un archivo
// tenemos que reconstruir un DataTransfer con los archivos que quedan y
// asignar dataTransfer.files al input. Esto está soportado en Chrome/Edge/
// Firefox/Safari modernos.
export default class extends Controller {
  static targets = ["input", "dropzone", "previews", "count", "empty"]

  connect() {
    this.files = []
    this.render()
  }

  // Triggered by the file input's "change" event when the user picks files.
  // Append (not replace) so picking twice in a row accumulates.
  onChange(event) {
    const picked = Array.from(event.target.files || [])
    if (picked.length === 0) return

    // Filter out duplicates by name+size (best-effort, FileList doesn't have
    // stable IDs). Image-only validation also lives here.
    picked.forEach((file) => {
      if (!file.type.startsWith("image/")) return
      const dupe = this.files.find((f) => f.name === file.name && f.size === file.size)
      if (!dupe) this.files.push(file)
    })

    this.syncInputAndRender()
  }

  // Click handler on a preview's "remove" button.
  remove(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    if (Number.isNaN(index)) return

    this.files.splice(index, 1)
    this.syncInputAndRender()
  }

  // Push the current `this.files` array back into the real <input> so the
  // form submits with the correct set, then re-render the preview grid.
  syncInputAndRender() {
    const dt = new DataTransfer()
    this.files.forEach((f) => dt.items.add(f))
    this.inputTarget.files = dt.files
    this.render()
  }

  render() {
    if (!this.hasPreviewsTarget) return

    if (this.files.length === 0) {
      this.previewsTarget.innerHTML = ""
      this.previewsTarget.classList.add("hidden")
      if (this.hasCountTarget) this.countTarget.textContent = ""
      if (this.hasDropzoneTarget) this.dropzoneTarget.classList.remove("wof-drop-has-files")
      return
    }

    this.previewsTarget.classList.remove("hidden")
    if (this.hasDropzoneTarget) this.dropzoneTarget.classList.add("wof-drop-has-files")
    if (this.hasCountTarget) {
      this.countTarget.textContent = `${this.files.length} foto${this.files.length === 1 ? "" : "s"}`
    }

    // Build preview cards. We use object URLs (fast, no base64 inflation)
    // and revoke them on disconnect to avoid leaks.
    this.revokeUrls()
    this._objectUrls = []

    this.previewsTarget.innerHTML = this.files
      .map((file, i) => {
        const url = URL.createObjectURL(file)
        this._objectUrls.push(url)
        const size = this.humanSize(file.size)
        const name = this.escapeHtml(file.name)
        return `
          <div class="wof-photo-card" data-photo-index="${i}">
            <img src="${url}" alt="${name}" loading="lazy">
            <button type="button"
                    class="wof-photo-remove"
                    data-action="click->photo-upload#remove"
                    data-index="${i}"
                    aria-label="Quitar foto">
              <span class="material-symbols-outlined" style="font-size:16px">close</span>
            </button>
            <div class="wof-photo-meta">
              <span class="wof-photo-name">${name}</span>
              <span class="wof-photo-size">${size}</span>
            </div>
          </div>
        `
      })
      .join("")
  }

  disconnect() {
    this.revokeUrls()
  }

  revokeUrls() {
    if (!this._objectUrls) return
    this._objectUrls.forEach((url) => URL.revokeObjectURL(url))
    this._objectUrls = []
  }

  humanSize(bytes) {
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }

  escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]))
  }
}
