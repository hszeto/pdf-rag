# Plan: chat-ui-and-retention-countdown

Spec: `ai/feature-specs/chat-ui-and-retention-countdown.md` (D1–D7 resolved, no open
questions).

## Confirmed Decisions

- **D1** Countdown shows whole minutes, never seconds — the note is honest about the
  limit, not a timer designed to hurry anyone.
- **D2** Under a minute remaining, the note says so in words rather than counting to
  zero. *(Derived, not stated by the user — flagged again at handoff.)*
- **D3** The processing screen reports pages read, not passages found, and keeps its
  spinner. No migration: chunks already carry `page`, and `IngestDocumentJob` writes
  every chunk row before embedding starts.
- **D4** WhatsApp layout — question right, answer left. No avatars, no timestamps.
- **D5** The two sides are labelled "User" and "AI".
- **D6** At zero the content is swapped in place, client-side. A direct visit to an
  expired document still redirects, unchanged.
- **D7** Retention is thirty minutes.

## Approach

### Retention period

`Document::RETENTION` is the single source and stays that way.
`SweepExpiredDocumentsJob::ORPHAN_GRACE` is already derived from it and needs no edit.
Verified: `EmbedChunkBatchJob`'s retry-budget assertion (`RETRY_WAIT * 5 <
RETENTION / 4`) becomes `375 < 450` and still passes, so no job constant moves.

### Page progress without a migration

Two model methods keep the arithmetic out of the view and make it testable without a
browser:

- `Document#page_count` → `chunks.maximum(:page)`
- `Document#pages_read` → `chunks.embedded.maximum(:page)`

Both return `nil` when unknown, which is what drives the display rules: the progress
line renders **only when both are present**. That falls out correctly in every phase —
during `extracting` no chunks exist, so nothing shows; before the first batch returns
`pages_read` is `nil`, so nothing shows; and a document whose chunks have null pages
yields `nil` rather than "page  of ". No extra guard clauses needed.

### The countdown

A new `retention_controller.js`, following the precedent of `processing_controller.js`
exactly: **all state comes from a server-supplied epoch timestamp**, never from a
counter the controller increments. This is the trap CLAUDE.md records, and asking a
question triggers a full redirect, so the controller is torn down and rebuilt often.

- One value: `expiresAt` (`document.expires_at.to_i`).
- Ticks every 1000 ms so zero is detected promptly, but only writes text when the
  rendered minute changes.
- `minutes = Math.floor(remainingMs / 60000)`; `>= 1` renders "in N minutes",
  otherwise "in less than a minute", and `<= 0` triggers the swap.

The controller wraps the document content in `show.html.erb` rather than sitting on
the retention note alone, because at zero it must replace the whole thing (R4.1). The
removal message ships hidden in the same response, so the swap needs no network call
(R4.2) — which matters on a free instance that may be asleep.

**Progressive enhancement:** the server renders a complete sentence ending
"…30 minutes after you added it." The controller replaces only the trailing phrase
with "in 29 minutes". Both readings are grammatical, so no-JS gets the promise in
words with no clock time (R3.5), satisfying AC5 without a second code path.

### Chat layout

Restyle `_chat.html.erb` only — no controller or model change. The `<ol>` stays for
screen readers (R2.6); alignment comes from flex utilities on each `<li>`.

**Reuse the existing palette, add no colours.** `notice-bg`/`notice-ink` for the
reader's message, `paper` with `border-rule` for the AI's. Both pairs are already
asserted in `test/services/palette_test.rb`. A new surface colour would need a new
`@theme` token *and* a new `PAIRS` entry, which is avoidable churn for no gain.

Long-content edge cases are handled with `break-words` and a max width on the bubble,
covered by the existing horizontal-overflow system test.

For R2.3, `MessagesController#create` redirects with an anchor to the newest message,
and each `<li>` gets a matching DOM id. That is a two-line change and avoids any
scroll scripting.

## Files Touched

- `app/models/document.rb` — `RETENTION` to `30.minutes`; add `page_count`, `pages_read`.
- `app/controllers/documents_controller.rb` — `expired_message` copy.
- `app/controllers/messages_controller.rb` — redirect with anchor to the new message.
- `app/views/documents/_retention_note.html.erb` — countdown markup, 30-minute copy,
  `expires_at` epoch data attribute; drop the `strftime` clock time.
- `app/views/documents/show.html.erb` — remove the passage count; wrap content in the
  retention controller; add the hidden removal block.
- `app/views/documents/_processing.html.erb` — page progress replaces passage count.
- `app/views/documents/_chat.html.erb` — WhatsApp layout, "User"/"AI" labels, ids.
- `app/javascript/controllers/retention_controller.js` — **new**.
- `test/models/document_test.rb` — **new**; `page_count` / `pages_read`.
- `test/integration/retention_test.rb` — copy assertions, epoch attribute, no clock.
- `test/integration/asking_questions_test.rb` — anchor redirect, labels.
- `test/system/document_screens_test.rb` — copy, chat alignment, countdown, swap.
- `README.md`, `CLAUDE.md` — thirty minutes wherever they say one hour.
- `CHANGELOG.md` — entry under a new heading.

## Checkpoints

Each is commit-sized and independently verifiable. Stop after each for review and a
commit before starting the next.

1. **Retention becomes thirty minutes.**
   `Document::RETENTION`, `expired_message`, both branches of the retention note,
   README, CLAUDE.md. Update `RetentionTest` and the system test's copy assertions.
   Confirm `SweepExpiredDocumentsJob` and the retry-budget test need no edit.
   *Commit: "Shorten document retention from one hour to thirty minutes"*

2. **Stop exposing chunking.**
   Remove the passage count from `show.html.erb`. Add `page_count` / `pages_read` with
   `test/models/document_test.rb`. Replace the processing screen's passage count with
   page progress. Rename the system test that says "its passages".
   *Commit: "Report progress as pages read rather than passages found"*

3. **The exchange reads as a conversation.**
   Restyle `_chat.html.erb`; "User"/"AI" labels; message ids; anchor redirect in
   `MessagesController`. Add layout and label assertions.
   *Commit: "Lay questions and answers out as a conversation"*

4. **Countdown and in-place expiry.**
   `retention_controller.js`; countdown markup; hidden removal block; wrap
   `show.html.erb`. Integration tests for the server-rendered fallback and the epoch
   attribute; system tests for the live countdown and the swap. CHANGELOG entry.
   *Commit: "Count down the time remaining and remove the document in place"*

## Test Plan

Tooling that exists: `bin/rails test` (Minitest, parallel), `bin/rails test:system`
(Capybara + Chrome), `bin/rubocop`, `bin/brakeman`, `bin/ci`. **No mocking library** —
every Gemini seam is injected via `stub_gemini`. Nothing here touches Gemini, so no
new stubbing is needed.

**Unit — `test/models/document_test.rb` (new)**
- `page_count` is nil with no chunks; is the highest chunk page otherwise.
- `pages_read` is nil when nothing is embedded; is the highest embedded page otherwise.
- Both nil when chunks carry null pages.
- `expires_at` is set thirty minutes out on create.

**Integration — `RetentionTest`**
- Upload screen states thirty minutes in words.
- Document screen states thirty minutes and renders **no** clock time — assert the
  absence of the old `strftime` output, so a regression fails loudly.
- The retention note carries `expires_at.to_i` as a data attribute.
- Existing expiry-redirect tests must pass **unmodified** (AC8) — they are the guard
  on D6's promise that server behaviour is unchanged.

**Integration — `asking_questions_test`**
- Response redirects to an anchor for the new message.
- "User" and "AI" appear as text; the citation line still renders.

**Integration — screens**
- Neither the ready nor the processing screen contains "passage".
- Processing screen with chunks but no embeddings shows no page numbers; with some
  embedded shows "Reading page N of M".

**System — `document_screens_test` (Chrome; NOT in `bin/ci`)**
- Countdown renders minutes and contains no `AM`/`PM`.
- Question right-aligned, answer left-aligned.
- A document expiring within a few seconds swaps to the removal message in place,
  with a generous `wait:`.
- The existing 18px-floor and no-horizontal-scroll tests must still pass with the new
  bubbles.

**Gap to state plainly:** `bin/ci` does not run system tests, so the countdown's JS
behaviour and the in-place swap are covered *only* by `bin/rails test:system`, run by
hand. The server-rendered fallback, the epoch attribute and all copy are covered by
integration tests, so CI still catches everything except the live ticking itself.

**Manual verification** (Phase 6): upload a small PDF, watch the countdown decrement a
minute, ask a question and confirm the countdown survives the reload showing the
correct remaining time.

## Risks / Rollback

- **The countdown's ticking is only system-tested.** A regression could reach main
  through a green `bin/ci`. Mitigated by keeping every server-rendered part under
  integration tests; the irreducible risk is the JS tick itself.
- **The zero-swap system test is timing-sensitive** and a plausible flake source. If
  it proves unstable, fall back to asserting the hidden block is present and correct
  and verify the swap manually, rather than leaving a flaky test in the suite.
- **Thirty minutes tightens the embedding retry budget** from 10% to 21% of a
  document's life. Nothing fails today; a future increase to `RETRY_WAIT` above 90
  seconds would break the existing assertion, which is the intended alarm.
- **A duplicate upload never shows page progress** — `reuse_existing_chunks` sets
  `status: "ready"` directly, skipping the processing screen. Correct behaviour, but
  worth knowing when manually testing with the same PDF twice.
- **Bubble styling could breach the 18px floor or cause overflow.** The two existing
  system tests already assert both and will catch it.
- **Rollback** is per checkpoint: each is one commit touching views, one model method
  pair, and one new controller file. Checkpoint 1 is the only one that changes a
  durable promise; reverting it restores the hour with no data implications, since
  `expires_at` is written per document at creation.
