import { Controller } from "@hotwired/stimulus"

// Polls the receipt parse status endpoint while the background job runs.
// On "ready" it reloads into the full result page; on "error"/"missing" it
// sends the user back to the upload form.
//
//   data-controller="receipt-poll"
//   data-receipt-poll-url-value="/split_checks/current/status"
//   data-receipt-poll-redirect-value="/split_checks/current"
//   data-receipt-poll-interval-value="2000"
export default class extends Controller {
  static values = {
    url: String,
    redirect: String,
    interval: { type: Number, default: 2000 }
  }

  connect() {
    this.poll()
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  async poll() {
    let status = "processing"
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      const data = await response.json()
      status = data.status
    } catch (_e) {
      // Network hiccup — keep polling.
    }

    if (status === "processing") {
      this.timer = setTimeout(() => this.poll(), this.intervalValue)
    } else {
      // ready → full navigation so the interactive split-check page initializes
      // cleanly. error/missing → show handles it (renders the form with an alert
      // or redirects). Either way, navigate to the result URL.
      window.location.href = this.redirectValue
    }
  }
}
