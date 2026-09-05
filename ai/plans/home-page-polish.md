# Plan: home-page-polish

Spec: `ai/feature-specs/home-page-polish.md` — D1–D3 resolved, no open questions.

## Confirmed Decisions

- **D1** Tinted panel inside the column, not a full-bleed band — `_chat.html.erb:22` already
  does exactly this, so it is a reuse rather than a new pattern.
- **D2** Steps state what the app does, positively.
- **D3** Superseded in implementation — the promise lives in step 3, not as its own paragraph.

## Approach

- The jumbotron already exists: `rounded-2xl bg-highlight-bg p-5 sm:p-8`. Copy it verbatim
  so the home page and chat screen are visibly the same app.
- The steps sit on `bg-panel rounded-2xl`, the second surface — same treatment
  `_scan_notes.html.erb` uses, so a screen of boxes is not a screen of white rectangles.
- **Superseded:** the promise was to strengthen in place. During implementation it moved
  into step 3 instead, and the standalone paragraph went away. R3 still holds — step 3
  builds its sentence from `Document::RETENTION`.
- Steps stack with `grid gap-4 sm:grid-cols-3`, so 360px gets one column and no overflow.
- Every new leaf element stays at `text-body` (18px) or above; step numerals are `text-fact`.

### Two findings that change what needs testing

- **The no-sideways-scroll test does not cover the home page.** It visits
  `document_path(ready_document)` — the chat screen. The spec's AC4 assumed otherwise. A
  home-page variant has to be added, or this feature's riskiest change is unguarded.
- **The retention copy is asserted verbatim**, inside the same test as the 18px floor. The
  rewrite moved it into step 3, so that assertion was updated to the new sentence — still
  built from `Document::RETENTION`, so AC2's guarantee is unchanged.

## Files Touched

- `app/views/documents/new.html.erb` — wrap heading, lead and form in the panel; add the steps.
- `app/views/documents/_retention_note.html.erb` — the now-unused `document: nil` branch
  removed. The `document` branch drives the live countdown and is left alone.
- `test/system/document_screens_test.rb` — retention wording, home-page overflow, step stacking.
- `CHANGELOG.md` — after the last checkpoint.

## Checkpoints

1. **The whole page, in one pass.** The panel around heading, lead and form; the promise
   strengthened to `text-ink` on the panel surface with its copy untouched; the three steps
   below it. One view, one partial, one test file — nothing here is sequenced, so splitting
   it bought rollback granularity a view-only change does not need.
   → verify: the existing home-page system tests pass; the promise renders in step 3 from
   the constant (AC1/AC2); no horizontal overflow at 360px; steps are one
   column at 360px and three at 1024px; 18px floor holds; `palette_test.rb` untouched and
   passing; `bin/rails test`, `bin/rails test:system`, `bin/rubocop`, `bin/brakeman` green.
   *Commit: "Give the home page something to look at"*

## Test Plan

- Existing five home-page system tests pass **unmodified** — the evidence D1 changed only
  presentation. Checkpoint 1 is where they are most likely to break.
- **New:** home-page horizontal overflow is `<= 0` at 360px — the gap found above.
- **New:** the three steps occupy one column at 360px and three at 1024px.
- `palette_test.rb` passes unmodified, and is not opened (AC3).
- Integration: the server-rendered page still contains the native file input, no
  `data-enhanced` (AC5) — the existing assertion in `document_screening_test.rb`.
- `bin/rails test`, `bin/rails test:system`, `bin/rubocop`, `bin/brakeman` (AC6).
- **Gap:** `bin/ci` does not run system tests, so every visual guarantee here is verified
  only by `bin/rails test:system` locally.

## Risks / Rollback

- **AC1 as first written could not be met.** A standalone promise ended 37px below the fold
  in a 497px viewport, and every remedy cost words from the promise → resolved by moving it
  into step 3 and relaxing R2, recorded in the spec.
- Nesting the pill inside a padded panel is the change most likely to break something: two
  system tests measure the pill's geometry → they run before the checkpoint is reported.
- **One checkpoint means one commit to bisect if geometry breaks** → acceptable here because
  all three changes live in a single view file and are trivially separable by eye; it would
  not be acceptable if any of them touched a migration or a controller.
- Steps are new copy on the busiest page → wording is cheap to revise; no logic depends on it.
- **Rollback** is per checkpoint, all view-only. No migration, no model, no controller, and
  the upload path itself is untouched.
