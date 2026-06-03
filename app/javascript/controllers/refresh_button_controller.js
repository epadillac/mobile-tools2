import { Controller } from "@hotwired/stimulus"

// Keeps the "Actualizar" button disabled while the lazy energy_data Turbo Frame
// is loading, so a user can't fire a second request before the values land.
// Re-enables once the frame finishes loading OR errors out (e.g. a timeout),
// so the user can always retry.
//
// The button is rendered disabled in HTML by default, so it is not clickable
// even before this controller connects.
//
//   data-controller="refresh-button"
//   data-refresh-button-frame-value="energy_data"
//   data-action="click->refresh-button#guard"
export default class extends Controller {
  static targets = ["idleIcon", "spinnerIcon", "label"]
  static values = {
    frame: String,
    idleText: { type: String, default: "Actualizar" },
    loadingText: { type: String, default: "Cargando…" }
  }

  connect() {
    this.onFrameLoad = this.onFrameLoad.bind(this)
    this.onError = this.onError.bind(this)
    document.addEventListener("turbo:frame-load", this.onFrameLoad)
    document.addEventListener("turbo:fetch-request-error", this.onError)
    document.addEventListener("turbo:frame-missing", this.onError)

    // If the frame already finished before we connected, enable right away;
    // otherwise keep the default disabled state until it loads/errors.
    const frame = document.getElementById(this.frameValue)
    if (frame?.complete) this.enable()
    else this.disable()
  }

  disconnect() {
    document.removeEventListener("turbo:frame-load", this.onFrameLoad)
    document.removeEventListener("turbo:fetch-request-error", this.onError)
    document.removeEventListener("turbo:frame-missing", this.onError)
  }

  onFrameLoad(event) {
    if (event.target.id === this.frameValue) this.enable()
  }

  onError(event) {
    const target = event.target
    if (target?.id === this.frameValue || target?.closest?.(`#${this.frameValue}`)) {
      this.enable()
    }
  }

  // Block clicks while loading (the lazy frame may still be in flight).
  guard(event) {
    if (this.element.dataset.loading === "true") {
      event.preventDefault()
      event.stopImmediatePropagation()
    }
  }

  disable() {
    this.element.dataset.loading = "true"
    this.element.setAttribute("aria-disabled", "true")
    this.element.classList.add("pointer-events-none", "opacity-60", "cursor-not-allowed")
    this.idleIconTarget?.classList.add("hidden")
    this.spinnerIconTarget?.classList.remove("hidden")
    if (this.hasLabelTarget) this.labelTarget.textContent = this.loadingTextValue
  }

  enable() {
    delete this.element.dataset.loading
    this.element.removeAttribute("aria-disabled")
    this.element.classList.remove("pointer-events-none", "opacity-60", "cursor-not-allowed")
    this.idleIconTarget?.classList.remove("hidden")
    this.spinnerIconTarget?.classList.add("hidden")
    if (this.hasLabelTarget) this.labelTarget.textContent = this.idleTextValue
  }
}
