import { Controller } from "@hotwired/stimulus"

// Waits for a document to finish being read.
//
// Polls rather than opening a socket: the wait is seconds to a couple of
// minutes, and a reload is the same request the reader would make by hand.
//
// Everything is derived from a timestamp the server supplies, never from how
// long this controller has been alive. Each poll replaces the whole page, so the
// controller is torn down and rebuilt every couple of seconds — anything kept in
// instance state resets that often, which silently kills a rotating message or a
// "taking longer" notice before it can ever fire.
export default class extends Controller {
  static targets = ["message", "slow"]
  static values = { interval: Number, slowAfter: Number, startedAt: Number }

  messages = [
    "Reading your document…",
    "Working through the pages…",
    "Finding the important parts…",
    "Almost there…"
  ]

  ROTATE_EVERY = 4000

  connect() {
    this.render()
    this.timer = setInterval(() => this.tick(), this.intervalValue || 3000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

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

    if (this.hasSlowTarget && elapsed > (this.slowAfterValue || 30000)) {
      this.slowTarget.classList.remove("hidden")
    }
  }

  tick() {
    this.render()
    // A plain visit: the server decides which screen comes next from the
    // document's status, so there is nothing for the client to interpret.
    window.Turbo.visit(window.location.href, { action: "replace" })
  }
}
