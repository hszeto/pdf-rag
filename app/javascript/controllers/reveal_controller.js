import { Controller } from "@hotwired/stimulus"

// Brings the newest answer into view after a question is asked.
//
// The obvious approach — redirecting to a #fragment — cannot work here. Turbo
// submits the form with fetch, fetch follows the redirect internally, and the
// fragment is stripped from the URL it reports. The server sends
// "Location: /documents/1#message_9" and the browser lands on "/documents/1"
// with no anchor and no scroll. A query parameter survives that round trip,
// which is why MessagesController marks the new answer with `?asked=`.
export default class extends Controller {
  connect() {
    // `center` rather than `start`: the citation sits below the answer, and
    // both should be readable without scrolling again. Animated unless the
    // reader has asked for less motion, as the spinner and the countdown are.
    // Deferred by two frames, not run inline. Turbo replaces the body — which is
    // what connects this controller — and only then scrolls the page to the top.
    // Scrolling here immediately is silently undone a moment later.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      this.element.scrollIntoView({ behavior: still ? "auto" : "smooth", block: "center" })
    }))

    // The parameter has done its job. Drop it so a reload, a bookmark or a
    // shared link does not scroll someone to a message they were not reading.
    const url = new URL(window.location)
    if (url.searchParams.has("asked")) {
      url.searchParams.delete("asked")
      window.history.replaceState(window.history.state, "", url)
    }
  }
}
