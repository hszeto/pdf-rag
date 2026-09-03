import { Controller } from "@hotwired/stimulus"

// Turns the plain file field into the same pill the chat input uses.
//
// The enhancement is applied here rather than rendered by the server, and that
// is the whole design: a transparent file input shows nothing, so without
// JavaScript the reader would have no way to see which file they had chosen.
// Leaving the native control in place until this runs means the no-JavaScript
// path is the browser's own, fully working control (R4).
//
// The input is made transparent, never hidden. `opacity-0` keeps its box, which
// is what keeps the browser's own `required` check working — collapse the box
// and Chrome silently refuses to submit, reporting only to the console.
export default class extends Controller {
  static targets = ["name"]

  PROMPT = "Choose a PDF"

  connect() {
    this.element.dataset.enhanced = ""
    this.render()
  }

  disconnect() {
    delete this.element.dataset.enhanced
  }

  render() {
    if (!this.hasNameTarget) return

    const input = this.element.querySelector("input[type=file]")
    const file = input?.files?.[0]

    // textContent, never innerHTML: a filename is a string from outside, and
    // the app already refuses to trust anything a document brings with it.
    //
    // Cancelling the picker fires no change event and leaves `files` as it was,
    // so the previous name simply stays — no special case needed.
    this.nameTarget.textContent = file ? file.name : this.PROMPT
  }
}
