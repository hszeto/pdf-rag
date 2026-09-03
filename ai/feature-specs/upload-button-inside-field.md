# Feature Spec: upload-button-inside-field

## Summary

Rebuild the upload screen's file field as the same pill the chat uses: the
control and its submit button on one line, button inside the field's bounds. The
native file control is replaced rather than overlaid, so the two screens read as
the same component.

## Context from the codebase (Phase 0 findings)

### What the chat form does (`app/views/documents/_ask_form.html.erb`)

A `relative` wrapper, a `rounded-full` text input with `pr-28` reserving space,
and the submit absolutely positioned `right-2 top-1/2 -translate-y-1/2`.

### What the upload form does (`app/views/documents/new.html.erb:13-19`)

A visible `text-lead font-bold` label ("Add a PDF"), a `rounded-lg` file field,
and a full-width-on-mobile submit **below** it.

### The difference that shapes this work

**It is `<input type="file">`, not a text field.** It has no `placeholder`, its
interior is browser chrome (only `::file-selector-button` is stylable, and the
native button sits on the left), and Safari and Firefox draw it differently from
Chrome. D3 resolves this by replacing the control rather than styling it.

### The measurement that decides the layout

Rendered at `text-body` bold with `px-6`, against ~328px of field at 360px:

| Label | Approx. width |
|---|---|
| "Ask" (the chat's) | ~78px |
| "Read my document" (today's) | ~208px — too wide |
| **"Submit"** (chosen) | **~108px** |

### The app already takes no-JavaScript seriously

`_processing.html.erb:36` carries a `<noscript>` fallback, and the retention note
states its promise in words when the countdown cannot run. A custom file control
that only works with JavaScript would be the first place the app stops degrading
gracefully — hence R4.

### A failing test found while orienting, unrelated to this feature

`test/system/document_screens_test.rb:10` asserts the `h1` reads "Understand any
document". The working tree changes it to "PDF file explain" (uncommitted), so
that test **fails now**. See Open Question 1 — it is decoupled from this work and
does not block planning.

## Resolved Decisions

- **D1 — The button reads "Submit".** ~108px, so it fits inside the field at
  360px with room for a filename beside it.
- **D2 — The visible "Add a PDF" label stays.** It is the only instruction on the
  screen, and a file input has no placeholder to move it into.
- **D3 — The native file control is replaced, not overlaid.** "Like the other
  one" means the chat's clean pill, so the real `<input type="file">` is hidden
  from view and a styled trigger stands in for it. This is the largest part of
  the work and was a Non-Goal in the previous draft.
- **D4 — The heading becomes "Understand any PDF document".** Decided here so it
  is not lost, but applied *outside* this feature: it is a two-line copy change
  that unbreaks a system test, and bundling it would muddle the diff.

## Requirements

### R1 — The field is one pill

- R1.1 The trigger, the chosen filename and the Submit button sit on a single
  line inside one rounded container, matching the chat's radius and button shape.
- R1.2 The button is right-aligned and never overlaps the filename.
- R1.3 The "Add a PDF" label stays above the field (D2).

### R2 — The control is replaced but still real

- R2.1 A real `<input type="file">` remains in the DOM and remains what submits —
  both existing tests asserting `input[type=file]` keep passing unmodified.
- R2.2 It is hidden visually in a way that keeps it focusable and operable by
  keyboard, not removed from the accessibility tree.
- R2.3 The visual pill shows a focus ring when the input behind it has focus, so
  a keyboard user can see where they are.
- R2.4 Activating the trigger opens the file picker, by pointer and by keyboard.

### R3 — It says what was chosen

- R3.1 Before a file is chosen, the field shows a prompt in place of a filename.
- R3.2 After one is chosen, it shows that file's name.
- R3.3 A long filename truncates inside the field rather than pushing the button
  out or forcing the page sideways.

### R4 — It still works without JavaScript

- R4.1 With JavaScript disabled, a reader can still choose a file and submit it.
- R4.2 With JavaScript disabled, they can still see which file they chose —
  falling back to the browser's own control is an acceptable way to do this.
- R4.3 The browser's own "required" validation still prevents an empty submit,
  and its message is still reachable (see Edge Cases).

### R5 — Nothing already guaranteed regresses

- R5.1 Nothing on the screen falls below 18px.
- R5.2 The page does not scroll sideways at 360px.
- R5.3 A refused upload still renders the alert above an intact form.

## Non-Goals

- Drag-and-drop, file previews, or client-side type and size checks. Validation
  stays on the request, where `DocumentValidator` performs it.
- Any change to what happens after upload — screening, ingestion, redirects.
- Changing the chat form. It is the reference, not the subject.
- Changing the `h1` or the paragraph beneath it. The wording is settled (D4);
  the edit lands separately.
- Restyling the file control on any screen other than the upload page.

## Edge Cases

- **`required` on a visually-hidden input.** Chrome refuses to submit a form
  containing an invalid control it cannot focus, reporting "An invalid form
  control with name='document' is not focusable" — and it does so silently, in
  the console. How the input is hidden decides whether R4.3 holds; `display: none`
  certainly breaks it.
- **A long filename** — R3.3, and the no-sideways-scroll test guards it.
- **A filename with markup-ish characters**, which must be escaped wherever it is
  displayed.
- **Choosing a file, then cancelling the picker**, which leaves the previous
  selection intact and must not blank the display.
- **Keyboard focus** — R2.3. The app draws a 3px accent outline; a hidden input
  moves that ring somewhere invisible unless it is forwarded.
- **The flash alert above the form** when an upload is refused, which must keep
  its spacing.
- **Browsers other than Chrome.** Only Chrome is covered by the suite, and the
  native control's dimensions differ elsewhere — less critical once it is
  replaced, but the no-JS fallback still exposes it.

## Acceptance Criteria

- AC1 The trigger, filename and Submit button render on one line inside a single
  rounded field, at 360px and at 1400px.
- AC2 The button reads "Submit" and does not overlap the filename.
- AC3 `input[type=file]` is still present; both existing tests asserting it pass
  unmodified.
- AC4 Tabbing to the control shows a visible focus ring on the pill.
- AC5 Choosing a file displays its name in the field.
- AC6 Submitting with no file is still refused by the browser, and the refusal is
  perceivable rather than a silent console error.
- AC7 With JavaScript disabled, a file can still be chosen, seen and submitted.
- AC8 The 18px-floor and no-sideways-scroll system tests pass.
- AC9 A refused upload still renders the alert with the form intact beneath it.
- AC10 `bin/rails test`, `bin/rails test:system`, `bin/rubocop` and Brakeman pass.

## Open Questions

None outstanding. All four were answered and promoted to Resolved Decisions
above. D3 grew the scope from a restyle to a replacement of the native control,
which is what R2, R3 and R4 exist to constrain.
