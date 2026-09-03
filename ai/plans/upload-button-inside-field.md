# Plan: upload-button-inside-field

Spec: `ai/feature-specs/upload-button-inside-field.md` (D1–D4 resolved, no open
questions).

## Confirmed Decisions

- **D1** The button reads "Submit" (~108px, fits inside the field at 360px).
- **D2** The visible "Add a PDF" label stays above the field.
- **D3** The native file control is replaced, not overlaid — the chat's pill is
  what "like the other one" means.
- **D4** The heading becomes "Understand any PDF document", applied **outside**
  this feature as its own commit.

## Approach

### The hiding technique, settled by measurement rather than assumption

The spec's largest risk was that `required` stops working on a hidden input:
Chrome refuses to submit a form containing an invalid control it cannot focus,
and reports it only to the console. I spiked the exact layout in headless Chrome
before writing this:

```
VALID_EMPTY=false          the empty input is correctly invalid
REPORT=false               reportValidity() blocks the submit
FOCUSABLE=true             .focus() lands on it despite opacity: 0
RECT=216x64                real dimensions, not collapsed
NOT_FOCUSABLE_ERROR=false  no "not focusable" console error
STILL_ON_PAGE=true         submission was actually prevented
```

So the input is made transparent with **`opacity-0` while keeping its box**, not
`sr-only`, `display:none` or `visibility:hidden`. Those collapse or detach it and
would break R4.3. This is the decision the rest of the layout hangs on.

### Layout

One `relative` pill matching the chat's `rounded-full` and border:

- The **file input** is absolutely positioned across the pill's left region,
  `right-28` so it stops short of the button. Transparent, but it is the click
  target — pressing anywhere on the left of the pill opens the picker, which is
  what makes the trigger feel native without being a separate element (R2.4).
  Stopping short of the button is what keeps Submit clickable rather than
  opening the picker.
- The **filename** is a `pointer-events-none` span beneath the input, truncated.
- The **Submit** button sits `right-2`, centred, exactly as the chat's does.

### Progressive enhancement, because a transparent control shows nothing

Rendered plainly, the enhanced pill would leave a no-JavaScript reader with an
invisible control and a filename that never updates — the first place this app
stops degrading (R4). So **the server renders the ordinary native control**, and
a Stimulus controller sets `data-enhanced` on the wrapper at `connect`. Every
visual change hangs off `group-data-[enhanced]:` variants written in the ERB, so
Tailwind sees the class names in a template rather than in a JS string it does
not scan.

No JavaScript therefore means the native control, which shows its own filename
and submits normally — R4.1 and R4.2 satisfied by the absence of the enhancement
rather than by a second code path.

### Focus

The real input keeps focus; the ring is forwarded to the pill with `peer-focus-visible:`
on the wrapper, so a keyboard user sees the outline the app draws everywhere else
(R2.3). Without this the ring lands on a transparent element and is invisible.

### The safety net already exists

If browser validation is ever bypassed, `DocumentValidator` raises
`ProcessingError::Missing` and `ApplicationController`'s `rescue_from` renders
"We did not get a file. Please choose your document and try again." Nothing new
is needed for the server side, and AC6 has a fallback that is already tested.

## Files Touched

- `app/views/documents/new.html.erb` — the pill; label kept (D2); button relabelled
  "Submit" (D1).
- `app/javascript/controllers/upload_controller.js` — **new**; sets
  `data-enhanced`, writes the chosen filename, restores the prompt when cleared.
- `test/system/document_screens_test.rb` — filename display, button placement,
  focus ring.
- `test/integration/document_screening_test.rb` — assert the server-rendered form
  is the un-enhanced native control, which is what proves R4 rather than assuming it.
- `app/assets/tailwind/application.css` — only if a variant needs help; expected
  to be untouched.

## Checkpoints

Land D4 first, as its own commit, so CI is green before the feature starts —
`h1` to "Understand any PDF document" plus the matching assertion in
`document_screens_test.rb:10`. It is not part of this feature and should not
share its commits.

1. **The pill, enhanced.** Rewrite the form as the `relative` pill: transparent
   input over the left region, Submit inside at `right-2`, `upload_controller`
   setting `data-enhanced`. No filename yet. Verify by hand that Submit submits
   and the left region opens the picker.
   *Commit: "Put the upload button inside the field"*

2. **The filename.** Prompt before a choice, the file's name after, truncated,
   escaped, and unchanged when the picker is cancelled. System tests with
   `attach_file(..., make_visible: true)`.
   *Commit: "Show the chosen file's name in the field"*

3. **Focus and the no-JavaScript path.** Forward the focus ring; add the
   integration assertion that the server renders the native control; confirm the
   18px floor and no-sideways-scroll tests still hold at 360px.
   *Commit: "Keep the upload field usable by keyboard and without JavaScript"*

## Test Plan

Tooling: `bin/rails test`, `bin/rails test:system` (Chrome, **not** in `bin/ci`),
`bin/rubocop`, `bin/brakeman`. No mocking library; nothing here touches Gemini.

**System — `document_screens_test`**
- Attaching a file shows its name in the field (`attach_file` needs
  `make_visible: true` against a transparent input — without it Capybara refuses).
- A very long filename does not widen the page at 360px.
- Submit renders inside the field's bounding box, not below it — compare
  `getBoundingClientRect()` of button and pill.
- Tabbing to the input makes the pill's focus ring visible.
- The existing 18px-floor and no-sideways-scroll tests must pass unmodified.

**Integration — `document_screening_test`**
- The server-rendered form still contains `input[type=file]` (existing assertions,
  unmodified — AC3).
- The server-rendered markup is **not** enhanced: no `data-enhanced`, so the
  no-JavaScript path is the native control. This is the closest CI can get to
  R4, and it is a real guarantee rather than a proxy — the attribute is only ever
  set by the browser.
- A refused upload still renders the alert above an intact form (AC9).

**Gaps stated plainly**
- **JavaScript genuinely disabled cannot be tested here** — Selenium offers no
  supported switch for it. Covered by the integration assertion above plus one
  manual check.
- Only Chrome is exercised. The pill removes most cross-browser risk by replacing
  the native chrome, but the no-JS fallback still shows it.
- `bin/ci` does not run system tests, so the filename, focus ring and placement
  are verified only by `bin/rails test:system`.

**Manual verification (Phase 6)**
Load `/`, choose a PDF, confirm the name appears and Submit works; press Tab and
confirm the ring; submit empty and confirm the browser's own bubble; then disable
JavaScript and confirm the native control appears and still uploads.

## Risks / Rollback

- **The `opacity-0` technique is measured, not assumed** — the spike above is the
  evidence. If a future browser regresses, the server-side `ProcessingError::Missing`
  path already catches an empty submit with a sensible message.
- **`attach_file` against a transparent input** is the most likely test friction;
  `make_visible: true` is the documented answer and is in the test plan.
- **Tailwind must emit `group-data-[enhanced]:` variants.** They are written in
  the ERB precisely so the scanner finds them; a silent miss shows as an
  unstyled pill and should be checked in the build output at checkpoint 1.
- **The click target is a transparent overlay**, so a layout change that lets it
  cover the button would make Submit open the picker instead. The placement
  system test guards this.
- **Rollback** is per checkpoint; the whole feature is one view, one controller
  file and test additions. No migration, no model or controller change, and the
  upload path itself is untouched.
