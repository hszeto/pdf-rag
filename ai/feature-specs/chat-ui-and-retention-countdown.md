# Feature Spec: chat-ui-and-retention-countdown

## Summary

Three changes to what the reader sees on a ready document: stop exposing how the
document was chunked, restyle the question-and-answer exchange so it reads like a
messaging thread rather than a form with a transcript below it, and replace the
retention note's wall-clock time with a countdown in whole minutes. Separately,
shorten the retention period itself from one hour to thirty minutes.

## Context from the codebase (Phase 0 findings)

### What exists

- `app/views/documents/show.html.erb:26` renders
  `<%= pluralize(@document.chunks.count, "passage") %> ready to search.`
- `app/views/documents/_processing.html.erb:26` renders the **same detail** in a
  different form: `"N passages found so far."` — the only progress signal on the
  waiting screen. A spinner sits above it at lines 16–17.
- `app/views/documents/_chat.html.erb` renders an `<ol>` of messages. Asked and
  answered are distinguished by margin (`sm:ml-12` / `sm:mr-12`), by a label
  ("You asked" / "Answer"), and by fill vs. border. Citations render as
  `From page 4 of your document.` from `message.citations`, which
  `QuestionAnswerer` populates with `DocumentChunk#location` values.
- `app/views/documents/_retention_note.html.erb` has two branches: with a document
  it names `expires_at.strftime("%-l:%M %p")`; without one it says "one hour after
  you add it".
- `Document::RETENTION = 1.hour` (`app/models/document.rb:20`) is the single source
  of the period. `SweepExpiredDocumentsJob::ORPHAN_GRACE` is derived from it.
- `MessagesController#create` **redirects** to `document_path` on success. Asking a
  question is a full page load, not a Turbo Stream append.
- `DocumentsController#load_document` redirects an expired document to the upload
  screen with an alert. `RetentionTest` asserts that redirect in two tests.

### Two findings that shape the requirements

**The displayed time is not the reader's local time — it is UTC.** `config.time_zone`
is commented out in `config/application.rb:39`, so Rails' default of UTC applies, and
`strftime` formats the UTC value with no zone marker. A reader in Los Angeles at
09:45 is shown "5:40 PM". The server has no reliable way to know the reader's zone,
which is why a countdown is the right fix rather than a formatting change: a duration
is correct in every timezone.

**A countdown cannot hold its own state.** This is the trap recorded in `CLAUDE.md`:
the processing screen replaces the page every few seconds, and asking a question
triggers a full redirect, so any Stimulus controller is torn down and rebuilt
regularly. `processing_controller.js` already handles this by deriving everything
from a server-supplied `started-at` timestamp. The countdown must work the same way —
from `expires_at`, never from a counter the controller increments.

## Resolved Decisions

- **D1 — The countdown shows whole minutes, never seconds.** A ticking second counter
  reads as pressure; the note exists to be honest about the limit, not to hurry
  anyone. The figure changes once a minute.
- **D2 — Below one minute the note says so in words** rather than counting toward
  zero. *(Assumption drawn from D1 — flagged in the handoff, easy to change.)*
- **D3 — The processing screen replaces its passage count with page progress**, e.g.
  "Reading page 40 of 138", and keeps its existing spinner. **No migration is
  required**: every chunk row already carries its `page`, and `IngestDocumentJob`
  creates all chunk rows before any embedding starts, so the total is
  `chunks.maximum(:page)` and progress is `chunks.embedded.maximum(:page)`. During
  the `extracting` status no chunks exist yet, so that phase keeps a plain
  "Reading your document…" with no numbers.
- **D4 — The layout is WhatsApp, not Slack**: the reader's question on the right, the
  answer on the left. No avatars and no per-message timestamps — timestamps would
  reintroduce the very UTC problem the countdown removes.
- **D5 — The two sides are labelled "User" and "AI".**
- **D6 — When the countdown reaches zero the page is swapped in place** for the
  removal message, client-side, from markup already delivered in the response. The
  server's existing behaviour for a *direct visit* to an expired document — redirect
  to the upload screen with an alert — is deliberately unchanged, so `RetentionTest`'s
  redirect assertions continue to hold.
- **D7 — Retention is thirty minutes.**

## Requirements

### R1 — Stop exposing chunking

- R1.1 The ready document screen no longer states a passage count.
- R1.2 No reader-facing copy names passages, chunks, embeddings or vectors. Internal
  names (`DocumentChunk`, `ChunkRetriever`) are unaffected.
- R1.3 Citations remain exactly as they are — "From page 4 of your document." — because
  a page is a property of the reader's document, not of how it was processed.
- R1.4 The processing screen reports progress as pages read, not passages found (D3),
  and states no page numbers before any are known.

### R2 — The exchange reads as a conversation

- R2.1 A question renders aligned to the right, an answer aligned to the left (D4).
- R2.2 Each message is attributed in text as "User" or "AI" (D5).
- R2.3 The newest exchange is the one the reader lands on after asking.
- R2.4 The citation line stays attached to the answer it belongs to.
- R2.5 The input keeps its accessible label and remains usable without JavaScript.
- R2.6 The message list remains a semantic list for screen readers, and sender
  attribution stays available as text rather than being carried by colour or
  position alone.
- R2.7 No avatars and no per-message timestamps (D4).

### R3 — Retention is shown as a countdown

- R3.1 The retention note on a document screen shows whole minutes remaining,
  decreasing once a minute, instead of a clock time (D1).
- R3.2 With under a minute left the note says so in words (D2).
- R3.3 No wall-clock time is displayed anywhere in the retention note.
- R3.4 The countdown derives from a server-supplied `expires_at`, so it survives the
  page being replaced.
- R3.5 Without JavaScript the note still states the promise in words, with no
  countdown.
- R3.6 The upload screen (no document yet) states the period in words.

### R4 — Expiry is handled in place

- R4.1 When the countdown reaches zero, the document content is replaced with the
  removal message without navigating away (D6).
- R4.2 The replacement needs no network request, so it is correct even if the
  service is asleep or unreachable.
- R4.3 A direct visit to an expired document still redirects to the upload screen
  with its existing alert — unchanged (D6).

### R5 — Retention becomes thirty minutes

- R5.1 `Document::RETENTION` becomes `30.minutes`, and remains the single source of
  the period.
- R5.2 Every reader-facing statement of the period agrees with it, including
  `DocumentsController#expired_message` ("That document has been removed…").
- R5.3 README and CLAUDE.md are updated wherever they state one hour.

## Non-Goals

- Live updates over Action Cable, streaming answers, or a typing indicator. Asking
  a question stays a form post; nothing here requires a socket.
- Any change to retrieval, chunking, embedding, or the answering prompt. This is a
  presentation change plus one constant.
- Making the summary section conversational. It is a document description, not a turn
  in the conversation.
- Persisting or displaying a reader's timezone.
- Changing the processing screen's polling mechanism.
- Changing what the server does when an expired document is requested directly.
- Adding a `page_count` column. D3 establishes it is unnecessary.

## Edge Cases

- **Under a minute remains.** Covered by D2: the note switches to words rather than
  showing `0`.
- **The countdown reaches zero while the reader is on the page.** Covered by D6: the
  content is swapped in place. Note the reader may still have an answer on screen
  that they can no longer act on — the swap must remove it, not merely annotate it.
- **The document expires between page render and the reader asking a question.**
  Already handled: `MessagesController` raises `ProcessingError::NoDocument` and
  redirects to root. Shortening the period makes this more frequent, not different.
- **Page total can understate the document.** D3 derives the total from the highest
  page that produced text, so a PDF whose final pages are blank or image-only will
  show "of 138" for a 140-page file. Honest about what was read, but not identical
  to the PDF's page count.
- **A chunk with a null `page`.** `DocumentChunk#location` already falls back to
  "part N"; the progress line must not render "page  of ".
- **A single-page or single-passage document** should not read as though progress
  stalled, and must not display "page 1 of 1" as if that were failure.
- **A document that is slow to process eats a larger share of its life.** A 140-page
  document takes a couple of minutes to embed; against thirty minutes that is a
  materially bigger fraction than against sixty.
- **The retry budget's headroom shrinks.** `test/jobs/embed_chunk_batch_job_test.rb:177`
  asserts `EmbedChunkBatchJob::RETRY_WAIT * 5 < Document::RETENTION / 4`. With
  `RETRY_WAIT = 75.seconds` that is `375 < 900` today and `375 < 450` at thirty
  minutes. It still passes, but the margin falls from 2.4× to 1.2×, and the retry
  schedule goes from consuming 10% of a document's life to 21%.
- **A document with no messages yet** should present as a conversation waiting to
  start rather than as an empty list.
- **A very long question or answer** must not break the chat layout, and a long
  unbroken string must not force horizontal scrolling.

## Acceptance Criteria

- AC1 The ready document screen contains no passage or chunk count, and
  `RetentionTest`'s existing assertions are updated rather than deleted.
- AC2 An answer still displays its page citation, and the existing citation test
  continues to pass unchanged.
- AC3 The processing screen shows page progress once pages are known and no page
  numbers before that, and never uses the word "passage".
- AC4 With JavaScript enabled, the retention note shows whole minutes remaining,
  decreasing without a page reload, and is correct after the full page load caused
  by asking a question.
- AC5 With JavaScript disabled, the retention note states the promise in words and
  shows no clock time.
- AC6 No view renders `expires_at` as a wall-clock time.
- AC7 When the countdown reaches zero the document content is replaced in place by
  the removal message, with no network request.
- AC8 A direct GET of an expired document still redirects to the upload screen; both
  existing `RetentionTest` expiry tests pass unmodified.
- AC9 `Document::RETENTION` is `30.minutes`, `expires_at` is set thirty minutes out on
  create, and no reader-facing string says "one hour".
- AC10 Questions render right-aligned and answers left-aligned, each labelled "User"
  or "AI" in text; no avatars or timestamps appear.
- AC11 The chat exchange remains a semantic list with text-based sender attribution,
  and the question input keeps its label.
- AC12 `bin/rails test` and `bin/rubocop` pass; Brakeman produces no warnings.

## Open Questions

None outstanding — all six were answered and promoted to Resolved Decisions above.
D2 is the one item derived rather than stated, and is called out as an assumption.
