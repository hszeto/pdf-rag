# Changelog

Notable changes to this project.

## [0.3.0] - 2026-09-03

### Changed

- **The upload field is one pill**, matching the chat input: the file control, the
  chosen filename and a "Submit" button on a single line. The browser's own file
  control is replaced rather than restyled — only its button is stylable, and it
  is drawn differently by every browser.
- The heading names the file type: **"Understand any PDF document"**. The app
  accepts nothing else, at the validator and in the field's `accept` attribute.

### Notes

- The field is enhanced by JavaScript, never rendered enhanced. Without
  JavaScript the browser's own control stays, still shows its filename and still
  uploads — a transparent input would show nothing.
- The input is made transparent, not hidden. `opacity-0` keeps its box, which is
  what keeps the browser's `required` check working; collapsing the box makes
  Chrome refuse to submit while reporting it only to the console.

### Security

- **Documents are addressed by an unguessable token, not their id.** Ids were
  sequential, so `/documents/40` and `/documents/41` belonged to different people
  and either could open the other's summary, scan notes and whole conversation.
  The id stays internal — every job still passes it across the queue.

### Added

- **Rate limiting per visitor**: five documents an hour, twenty questions a
  minute. The limiter fails closed, refusing rather than admitting when the
  counter store is unreachable — Rails' own behaviour is the opposite, and would
  switch limiting off exactly when the cache is unwell.

### Fixed

- **`request.remote_ip` is the visitor again.** Render fronts every service with
  Cloudflare, whose ranges Rails does not know, so every request was logged and
  counted as coming from a Cloudflare edge.

### Changed

- Uploads are capped at 8 MB, down from 15 MB, sized for a 512 MB container that
  parses the whole file in the web process.

## [0.2.0] - 2026-09-03

### Changed

- **Documents are now kept for thirty minutes**, not an hour. The period lives in
  `Document::RETENTION` and the reader-facing copy derives from it, so the promise and
  the behaviour cannot drift apart.
- **The retention note counts down** in whole minutes instead of naming a time. It named
  a time in the server's zone, which is nobody's local time: a reader in Los Angeles at
  09:45 was told the document would go at "5:40 PM". A duration is correct everywhere.
  Under a minute it says so in words. Without JavaScript the sentence still states the
  promise and shows no clock.
- **A document leaves the screen when its window closes**, replaced in place by the
  removal message. The replacement ships with the page, so the swap costs no request and
  holds even if the server is asleep. A direct visit to an expired document still
  redirects to the upload screen, unchanged.
- **Questions and answers read as a conversation** — the reader's words on the right, the
  answer on the left, each named in text as "User" or "AI". No avatars and no timestamps;
  a per-message time would reintroduce the same timezone defect the countdown removes.
  Asking now lands on the new answer rather than the top of the page.
- **Progress is reported in pages, not passages.** How a document was chunked is an
  implementation detail; a page belongs to the reader's document. The waiting screen reads
  "Reading page 40 of 138" once both numbers are real, and the ready screen no longer
  counts anything at all.

## [0.1.1] - 2026-09-03

### Changed

- **All tables moved into a dedicated `pdfrag` Postgres schema** so the app can share
  one database with other applications. This covers its own three tables, Active
  Storage's three, and Rails' `schema_migrations` and `ar_internal_metadata` — the two
  that make a shared database dangerous rather than merely crowded. No table was
  renamed, no model changed, and no migration was edited; isolation comes from
  `schema_search_path` in `config/database.yml`.
- `db:ensure_schema` creates the schema, hooked onto `db:migrate` and `db:prepare`.
  A missing schema does not raise in Postgres — `search_path` falls through to
  `public` — so creating it is automatic rather than a documented step.

## [0.1.0] - 2026-09-02

### Added — any-PDF retrieval

Replaces the insurance-specific application on the `mvp` branch.

- **Any PDF**, screened for hostile content before it is stored. Scripts, launch
  actions and attached executables are refused; links and ordinary attachments are
  shown to the reader instead of blocking, because genuine documents are full of both.
- **Retrieval instead of sending the document.** Passages are chunked with overlap,
  embedded into Postgres with pgvector, and only the relevant few are used to summarise
  or answer. Measured on a 140-page policy: 1.7% of the document sent, in two calls.
- **Summaries** built from a generic-anchor query for the passages where a document
  explains itself.
- **Questions** answered from the three nearest passages, with citations to where in
  the document each answer came from. There is no full-text fallback.
- **One-hour retention**, enforced by a column that every read scopes to as well as by
  a deletion job, plus a sweep for orphaned files.

### Changed

- Application renamed from `InsuranceHelper` to `PdfRag`.
- Active Record and Active Storage enabled; the app previously had no database.
- PDF extraction is no longer capped at 20 pages — retrieval replaced the cap.
- A daily API quota is now reported as such rather than as a passing problem.

### Removed

- The insurance-specific session cache, plan screen, and five-minute expiry. All of it
  remains on the `mvp` branch.
