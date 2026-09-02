import { Controller } from "@hotwired/stimulus"

// Waits for the background job to finish reading the document.
//
// Polls rather than opening a socket: the wait is seconds, not minutes, and a
// reload is the same request the reader would make by hand. Each poll also
// counts as activity, so nobody watching this screen has their document removed
// out from under them.
//
// Everything is derived from a timestamp the server supplies, never from how
// long this controller has been alive. Each poll replaces the whole page, so the
// controller is torn down and rebuilt roughly every two seconds — measured at
// five rebuilds in nine seconds. Anything kept in instance state resets that
// often, which silently killed both the rotating messages and the "taking
// longer" notice: neither could outlive a single interval.
export default class extends Controller {
  static targets = ["message", "slow"]
  static values = { interval: Number, slowAfter: Number, startedAt: Number }

  // Deliberately calm and non-technical: no percentages, no jargon.
  messages = [
    "This usually takes a few seconds.",
    "Looking through your document…",
    "Finding the important parts…",
    "Almost there…"
  ]

  ROTATE_EVERY = 4000

  connect() {
    this.render()
    this.timer = setInterval(() => this.tick(), this.intervalValue || 2000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  // Milliseconds since the server began the analysis. Survives any number of
  // page replacements because it comes from the server, not from us.
  elapsed() {
    if (!this.hasStartedAtValue || !this.startedAtValue) return 0
    return Date.now() - this.startedAtValue * 1000
  }

  render() {
    const elapsed = this.elapsed()

    if (this.hasMessageTarget) {
      const index = Math.floor(elapsed / this.ROTATE_EVERY) % this.messages.length
      this.messageTarget.textContent = this.messages[index]
    }

    if (this.hasSlowTarget && elapsed > (this.slowAfterValue || 20000)) {
      this.slowTarget.classList.remove("hidden")
    }
  }

  tick() {
    this.render()
    // A plain visit: the server decides which screen comes next from the
    // session's status, so there is nothing for the client to interpret.
    window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
