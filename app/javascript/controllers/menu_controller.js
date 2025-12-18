import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "dialogContent", "item", "result"]

  show() {
    this.dialogTarget.showModal()
  }

  hide() {
    this.dialogTarget.close()
  }

  hideOnClickOutside({ target }) {
    if (this.dialogTarget.contains(target) && !this.dialogContentTarget.contains(target)) {
      this.hide()
    }
  }

  itemSelected({ target }) {
    this.hide()
    this.resultTarget.textContent = `${target.textContent} was selected`
  }
}
