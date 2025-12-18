import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  clearSplitData() {
    // Clear all split check data from localStorage
    const keysToRemove = []
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i)
      if (key && key.startsWith('splitCheck_')) {
        keysToRemove.push(key)
      }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key))
  }
}