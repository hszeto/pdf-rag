# Feature Spec: home-page-polish

## Summary

The home page is one heading, one sentence, one field and a muted footnote. It
does not explain what happens after you upload, and the thing most likely to
reassure a stranger — that the document is deleted in thirty minutes — is the
quietest element on the screen.

## Findings

- The retention promise **already exists** (`_retention_note.html.erb`) but renders
  `text-ink-muted`, centred, `mt-10` — last on the page and below the fold on a phone.
- Its period comes from `Document::RETENTION`, so the copy cannot drift from behaviour.
  Whatever we do must keep deriving it, not hardcode "30 minutes".
- The palette is deliberately austere and **contrast-verified in `palette_test.rb`**;
  `panel` and `highlight-bg` exist precisely so "a screen of boxes is not a screen of
  white rectangles" and are already proved against `ink` and `ink-muted`.
- Three tests constrain any layout change: the 18px floor, no sideways scroll at 360px,
  and the `h1` text assertion in `document_screens_test.rb`.
- The upload pill is applied by JavaScript via `data-enhanced`; the server renders the
  native control. Any new markup around it must not assume the enhanced form.
- `main` is `max-w-3xl` with no full-bleed escape hatch.

## Requirements

- R1 A first-time visitor can tell what the app does with their file before uploading.
- R2 The thirty-minute deletion is stated plainly on the page, as one of the steps.
- R3 The retention period keeps deriving from `Document::RETENTION`.
- R4 No new colours: only existing tokens, so contrast stays proved rather than re-argued.
- R5 Nothing falls below 18px; no sideways scroll at 360px.
- R6 The page still works without JavaScript, including the native file control.

## Non-Goals

- Changing the palette, or adding dark mode.
- ~~Adding illustration assets.~~ **Overridden during implementation:** three step icons,
  a logo mark and a header wordmark were added on request. All are inline SVG using
  `currentColor` and the existing accent token, so R4 still holds — no new colours, and
  `palette_test.rb` remains untouched.
- Changing the upload mechanics, copy of the heading, or the chat screen.
- Marketing content — testimonials, pricing, feature grids.

## Edge Cases

- 360px wide: a three-column row of steps must stack, not scroll.
- No JavaScript: the native file control is taller than the pill, so anything positioned
  relative to it must not overlap.
- A flash alert renders above everything; it must not be pushed off-screen by new content.
- Browser zoom at 200%: the step row must reflow rather than clip.

## Acceptance Criteria

- AC1 The retention sentence appears in the steps and is derived from the constant.
- AC2 It still reads from `Document::RETENTION` — changing the constant changes the page.
- AC3 `palette_test.rb` passes **unmodified** — the proof that R4 held.
- AC4 The 18px floor and no-sideways-scroll system tests pass unmodified.
- AC5 The server-rendered page still contains the un-enhanced native file input.
- AC6 `bin/rails test`, `bin/rails test:system`, `bin/rubocop`, Brakeman pass.

## Resolved Decisions

- **D1** A tinted **panel** inside the existing column — `highlight-bg`, rounded — not a
  full-bleed band. The same visual lift without escaping `max-w-3xl`, and it matches the
  jumbotron already used on the chat screen.
- **D2** The steps describe what the app **does**, in positive terms — "we send the
  passages that answer your question" rather than "we never send your whole document."
  Same fact, stated as a capability instead of a disclaimer.
- **D3** ~~The retention promise gets stronger in place.~~ **Superseded during
  implementation:** the promise moved into step 3 of "How it works" and the standalone
  paragraph was removed. It now sits below the fold, which R2 originally forbade — the
  requirement was relaxed to match, because satisfying the stricter reading at 360x640
  cost words from the promise itself (measured: 37px over in a 497px viewport).
