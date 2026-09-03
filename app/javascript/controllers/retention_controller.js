import { Controller } from "@hotwired/stimulus"

// Counts down what is left of a document's life, and takes the document off the
// screen when that reaches zero.
//
// Everything derives from a timestamp the server supplies, never from how long
// this controller has been alive. Asking a question is a full redirect and the
// processing screen replaces the page every few seconds, so the controller is
// torn down and rebuilt constantly — a count it kept itself would restart from
// the beginning each time and quietly never finish.
//
// Whole minutes, never seconds (D1). The note exists to be honest about the
// limit, not to stand over the reader while they read.
export default class extends Controller {
  static targets = ["remaining", "live", "expired"]
  static values = { expiresAt: Number }

  TICK = 1000

  connect() {
    this.render()
    // Ticking every second while displaying minutes looks wasteful, but it is
    // what makes zero land promptly rather than up to a minute late.
    this.timer = setInterval(() => this.render(), this.TICK)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  remainingMs() {
    if (!this.hasExpiresAtValue || !this.expiresAtValue) return null
    return this.expiresAtValue * 1000 - Date.now()
  }

  render() {
    const left = this.remainingMs()
    if (left === null) return
    if (left <= 0) return this.expire()
    if (!this.hasRemainingTarget) return

    const minutes = Math.floor(left / 60000)
    this.remainingTarget.textContent =
      minutes >= 1
        ? `in ${minutes} ${minutes === 1 ? "minute" : "minutes"}`
        : "in less than a minute"
  }

  // The document is unreachable from this instant, so the page stops showing it
  // rather than leaving an answer on screen that can no longer be acted on.
  //
  // The replacement already arrived with the page, so no request is made. That
  // matters on a free instance which may be asleep: the promise is kept even
  // when the server cannot be reached to confirm it (R4.2).
  expire() {
    clearInterval(this.timer)
    if (this.hasLiveTarget) this.liveTarget.classList.add("hidden")
    if (this.hasExpiredTarget) this.expiredTarget.classList.remove("hidden")
  }
}
