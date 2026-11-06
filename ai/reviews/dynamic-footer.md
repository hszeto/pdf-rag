# Review: Dynamic Footer

## Summary
- Branch `footer` against `main`: 3 files, 1 must fix, 3 should fix, 2 nit

## Plan Trace
- `app/views/shared/_footer.html.erb` → checkpoint 1
- `app/views/layouts/application.html.erb` → checkpoint 2
- `test/system/document_screens_test.rb` → checkpoint 3
- All files in plan ✓

## Coverage
- Footer renders on the home page — tested (but not scoped to footer element)
- Footer renders on document detail pages — tested (but not scoped to footer element)
- Copyright year matches `Date.current.year` — tested with hardcoded assertion
- Footer styling is consistent — **not covered** — uses `text-sm` which violates 18px minimum
- Year updates without code changes — **not covered** — test doesn't use time travel

## Findings
- [must fix] `app/views/shared/_footer.html.erb:4` — `text-sm` is 14px, violates app's 18px minimum typography policy. Use `text-body` (what the header tagline uses) instead.
  - Answer: good call. need to fix this.
- [should fix] `test/system/document_screens_test.rb:237-243` — Test doesn't prove year is computed dynamically. Add `travel_to Date.new(2031, 6, 1)` case to verify computation, not hardcoding.
- [should fix] `test/system/document_screens_test.rb:239,242` — `assert_text` matches anywhere on page. Scope with `within("footer") { assert_text ... }` to verify footer element actually renders.
- [should fix] `app/views/shared/_footer.html.erb:3` — Spacing is doubled: `main` ends with `pb-10 sm:pb-16`, footer adds `pt-10 sm:pt-16`. Drop or reduce footer's top padding (e.g., `pt-0` or `pt-4`).
- [nit] `app/views/shared/_footer.html.erb:3` — On short pages, footer may float partway up window (not pinned). Confirm with spec author if sticky behavior is desired.
- [nit] `test/system/document_screens_test.rb:237` — Test name says "every page" but visits two. Rename to match (e.g., "upload and document pages").

## Not Covered
- None. All files read and assessed.
