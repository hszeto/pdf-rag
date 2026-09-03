# Feature Spec: pdf-insight-rag

## Summary

Replaces the insurance-only MVP with a general PDF reader: upload any PDF, have it
screened for hostile content, then chunked and embedded into Postgres so questions can
be answered from the handful of passages that actually matter rather than from the whole
document. Documents persist rather than expiring, which is a deliberate reversal of the
MVP's strongest privacy property and needs a stated retention policy.

---

## Context from the codebase (Phase 0 findings)

Confirmed by reading the repo and this machine, not assumed.

### What exists and carries over
The MVP (branch `mvp`, through `98b73f4`) is complete through its checkpoint 5c and
green: 132 unit/integration tests, 10 system tests, rubocop and brakeman clean. These
are architecture-independent and should be reused rather than rewritten:

- `app/services/document_validator.rb` — magic-byte and size checks, cheapest-first
- `app/services/pdf_extraction_service.rb` — `pdf-reader` wrapping, maps
  `EncryptedPDFError` / `MalformedPDFError` to distinct user-facing errors. Carries a
  `MAX_PAGES = 20` cap that this feature removes.
- `app/services/gemini_client.rb` — injected transport, `responseSchema` structured
  output, `thinkingBudget: 0`, and upstream error diagnostics that parse Google's quota
  IDs out of the response body. Public API today: `#analyze_document`, `#answer`.
- `app/services/processing_error.rb` — error hierarchy where each class carries its own
  user-facing wording
- `app/jobs/analyze_document_job.rb` — the pattern of passing only an id across the
  queue and recording failures on the record rather than raising into Sidekiq retries
- The Tailwind `@theme` palette, whose WCAG AA contrast is asserted by reading the CSS
  file itself, and the system tests that measure computed font sizes in real Chrome
- The processing screen, whose elapsed time comes from the server because Stimulus
  controller state does not survive polling (measured: 5 reconnects in 9 seconds)

### What must be built or enabled
- **Active Record is off.** `config/application.rb:7` comments out
  `active_record/railtie`. There is no `config/database.yml` and no adapter gem in the
  `Gemfile`.
- **Active Storage is off.** `config/application.rb:8` comments out
  `active_storage/engine`, and there is no `config/storage.yml`.
- **pgvector is not installed.** `pg_available_extensions` has no `vector` row.
  `brew install pgvector` is needed, and the formula shows a nonzero build-error rate.
- `SessionCache` and `InsuranceSession` are cache-backed value objects with a 300s TTL.
  They are replaced by Active Record models, not adapted.
- `PlanPresenter`, `QuestionAnswerer` and the insurance-specific views are
  domain-specific and do not carry over.

### Environment
- PostgreSQL **14.24** running on 5432; `pg_config` on PATH is also 14.24, so a
  brew-built pgvector should match. Only `postgresql@14` is installed.
- Current user `henry` can connect to Postgres without a password.
- Redis 8.10.1 under `brew services`; cache on DB 0, Action Cable DB 1, Sidekiq DB 2.
- Sidekiq 8.1.7 wired, `Procfile.dev` runs a worker.
- `origamindee` 4.0.2 installs and runs on Ruby 4.0.6 — verified in an isolated bundle,
  including detection of a JavaScript OpenAction and a Launch OpenAction.
- **`CLAUDE.md` is badly out of date.** It still describes a freshly generated app with
  "no models, no routes beyond `/up`, no root route". It needs rewriting.
- The app module is still `InsuranceHelper`, which no longer matches the product.
- Branch is `mvp`. This work needs its own branch.

---

## Resolved Decisions

All open questions are answered. The original Q&A is preserved verbatim under
**Answered Questions (record)** at the end of this document.

**D1 — URI policy: allow, but surface them.** External links never block a document.
The reader is shown the list of links found so they can judge for themselves. Chosen
because every genuine document has links — the UHC policy has ten, all legitimate — so
blocking on them would reject real documents, while hiding them entirely would drop a
signal the reader may want. No blocklist, no heuristics.

**D2 — Non-executable embedded files: allow with a note.** The attachment is named in
the same place the links are surfaced. Executable extensions remain a hard block (D-R2).
C2PA Content Credentials, which the UHC policy carries, pass without comment being
special-cased.

**D3 — Retention: one hour.** Documents, chunks, and attached files are removed an hour
after upload. Longer than the MVP's five minutes so a reader can work through a long
document without losing it; short enough that the privacy story survives the move to
persistence. Requires a sweep job, and the UI must say plainly what the hour means.

**D4 — Keep the existing `GeminiClient`.** It is tested, handles structured output and
quota diagnostics, and its injected transport is the only workable test seam in a
project with no mocking library. It gains an `embed` method. `ruby_llm` and `langchainrb`
are not adopted; no new AI gem enters the Gemfile.

**D5 — Chunking: ship 500 words with overlap, tune later.** Treated as a starting point
rather than a validated choice. Retrieval quality is measured against the real 140-page
policy after it works end to end, not before.

**D6 — Deduplicate now.** Hash the extracted text; an identical document reuses the
existing chunks and embeddings rather than re-embedding. Built in from the start rather
than retrofitted, since it changes the ingestion path.

**D7 — Ingestion: one job per chunk batch.** Gives progress and resumability, and stops
a single worker being held for the length of a long document. Costs coordination — the
document is only "ready" once every batch reports in.

**D8 — Stay on the Gemini free tier. Rescued by batching, not by price.**

The reasoning needs restating, because the original premise was wrong in a way that
happened not to matter. Embeddings *are* cheap per token, but the free tier's binding
constraint is a **request-per-day count**, not a dollar amount — cheapness does not buy
more requests. What actually makes the free tier viable is batching:

- `batchEmbedContents` accepts **at most 100 chunks per request** — confirmed from the
  API's own 400 response, not inferred.
- A 50-chunk batch was embedded successfully in **one** HTTP request, 3072 dimensions
  each.
- So a 160-page document is roughly **2–4 requests**, not the ~200 the spec assumed.

That changes the arithmetic by two orders of magnitude and makes staying on the free
tier defensible. Two cautions stand: embedding requests still hit 429 under load
(observed at a 100-chunk batch immediately after a 50-chunk one), and generation and
embedding draw on separate quota buckets, so one can fail while the other works.
Ingestion must therefore batch, and must survive a 429 mid-document (D7's per-batch jobs
make that resumable).

**Model name, for the third time:** `text-embedding-004` is retired and 404s. The
embedding model is **`gemini-embedding-001`**, 3072 dimensions, confirmed live.

**D9 — Rename the application.** Only 8 references across 6 files today
(`config/application.rb`, both environment files, `cable.yml`, `deploy.yml`, the PWA
manifest), so it is nearly free now and much more expensive once databases are named
after it. Following Rails conventions the module becomes **`PdfRag`** and the directory
`pdf_rag`; "PDFrag" as written would be an unconventional constant and reads awkwardly.
The directory rename is the user's to perform.

**D10 — Branch `pdf-rag`, cut from `main`.** `mvp` stays untouched as the working
reference. The user creates the branch.

---

## Requirements

### R1 — Upload and safety screening
- R1.1 Accept a single PDF upload per document record.
- R1.2 Reject files whose first bytes are not `%PDF-`, and files over the size limit,
  before any parsing.
- R1.3 Screen every accepted PDF structurally with `origamindee` **before** text
  extraction, chunking, or any call to an external service.
- R1.4 The screen classifies each signal rather than merely detecting it, per the policy
  in R2. A detected signal is not automatically a rejection.
- R1.5 A rejected document is not stored, not extracted, and never sent anywhere.
- R1.6 The screen must tolerate malformed PDFs without crashing, and a PDF the scanner
  cannot parse is treated as unsafe rather than waved through.
- R1.7 The reader is told *why* a document was refused, in plain language, with a way to
  try another file.

### R2 — Safety policy
Structural signals and their disposition:

| Signal | Disposition |
|---|---|
| JavaScript (`/JavaScript` action, named scripts) | **Block** |
| `/Launch` action | **Block** |
| Auto-run `OpenAction` of an executable type | **Block** |
| Embedded file with an executable extension | **Block** |
| Embedded file, known-benign type (e.g. C2PA Content Credentials) | Allow |
| Embedded file, other | See Open Questions |
| `/URI` actions | See Open Questions |
| Encrypted / password-required | Reject as unreadable, distinct from unsafe |

- R2.1 The policy lives in one place, is enumerable, and is testable signal by signal.
- R2.2 Every block decision records which signal caused it, for support and debugging.

### R3 — Ingestion (background)
- R3.1 All ingestion runs in Sidekiq; the upload request returns as soon as the file is
  stored and screened.
- R3.2 Extract text with `pdf-reader` across the **whole** document — the MVP's 20-page
  cap is removed, since retrieval replaces it.
- R3.3 Split text into overlapping chunks of roughly 500 words so meaning is not severed
  at page or chunk boundaries.
- R3.4 Each chunk stores its text, its embedding, and enough position information to say
  where an answer came from.
- R3.5 Embed chunks via the Gemini embedding API in batches of up to 100 per request
  (the API's hard limit, confirmed), and persist both text and vector. A 160-page
  document is 2-4 requests, not 200 (D8).
- R3.6 Progress is visible: a document moves through discrete states and the reader sees
  which one it is in.
- R3.7 A failure part-way through leaves the document in a recorded failed state, never
  silently half-ingested.

### R4 — Data model
- `Document` — `has_one_attached :file`, status, title, generated summary, timestamps,
  and the reason for any refusal.
- `DocumentChunk` — `belongs_to :document`, `content` text, `embedding` vector(3072),
  position metadata. Indexed for cosine similarity search via `neighbor`.
- R4.1 Deleting a document deletes its chunks and its attached file.
- R4.2 Documents, chunks and attached files are removed one hour after upload by a
  sweep, and the interface says plainly that this happens (D3).

### R5 — Summary ("generic anchor")
- R5.1 After ingestion, run an automated retrieval query for structural language
  ("executive summary", "conclusion", "abstract", "main findings").
- R5.2 Take the top 5 chunks by cosine similarity and ask the model for 3–5 bullets.
- R5.3 The whole document is never sent for summarisation.
- R5.4 A document with no clear structural anchors still produces a usable summary.

### R6 — Question answering
- R6.1 Embed the question, retrieve the 3 most relevant chunks, and answer strictly from
  them.
- R6.2 The full document text is never sent on any path.
- R6.3 When the retrieved context does not answer the question, say so plainly rather
  than guessing from general knowledge.
- R6.4 Answers cite which part of the document they came from.
- R6.5 Conversation history persists with the document.

### R7 — Interface
- R7.1 Upload, processing, document view with summary, and chat.
- R7.2 Processing shows progress and does not appear stalled on a long document.
- R7.3 Refusals and failures always arrive with a way forward.
- R7.5 External links and any embedded attachments found during screening are shown to
  the reader rather than hidden or used to block (D1, D2).
- R7.4 Inherits the MVP's type scale and verified-contrast palette.

### R8 — Cost and quota
- R8.1 Embedding requests are batched (up to 100 chunks each), and a document whose
  extracted text hashes to one already ingested reuses the existing chunks rather than
  re-embedding (D6, D8).
- R8.2 Quota exhaustion is reported honestly — a daily cap must not be described as
  "try again in a moment".
- R8.3 Upstream failures are logged with status and quota id, never with document text.

### R9 — Testing
- R9.1 No test may reach a live API. There is no mocking library, so every external seam
  is injected, as `GeminiClient` already does.
- R9.2 Hostile PDF fixtures are generated deterministically rather than downloaded.

---

## Non-Goals

- User accounts, authentication, or per-user document isolation
- Querying multiple documents in one conversation
- Non-PDF formats
- OCR for scanned or image-only PDFs
- Antivirus scanning of attachment *payloads* — structural inspection only
- Re-ranking, hybrid keyword+vector search, or query rewriting
- Streaming responses
- Migrating any data from the MVP

---

## Edge Cases

**Safety screening**
- A legitimate document trips benign flags: the real UnitedHealthcare policy carries a
  C2PA "Content Credentials" attachment and ten URIs (nyc.gov, hhs.gov, uhc.com,
  `mailto:`, `tel:`). A naive scanner rejects the most representative document available.
- Malformed values in genuine files — that same document contains the URI
  `http://refer/`.
- A PDF `origamindee` cannot parse at all, though `pdf-reader` can, or the reverse.
- A PDF that is encrypted with an empty user password: readable, not locked.
- Deeply nested or self-referencing object graphs; a scanner walking every object must
  terminate.
- A PDF crafted so the scanner itself is the target (decompression bombs, huge object
  counts).

**Ingestion**
- A 160-page document produces hundreds of chunks and hundreds of embedding calls;
  partial failure mid-way.
- A page whose text extracts as empty (image-only) inside an otherwise textual document.
- A document whose total text exceeds what a single summarisation prompt can hold even
  after retrieval.
- Two users uploading the identical file.
- Text so short it yields a single chunk.
- Chunk boundaries splitting a table or a sentence, degrading retrieval.

**Retrieval and answering**
- The top 3 chunks are all irrelevant, and the model must decline rather than improvise.
- A question about something genuinely absent from the document.
- A question whose answer spans chunks that do not individually rank well.
- Embedding the question fails while the document is fine.

**Quota and infrastructure**
- The embedding quota is exhausted mid-ingestion, leaving a document half-embedded.
- Generation and embedding hit separate quota buckets, so one can work while the other
  does not.
- Postgres or Redis unavailable at upload time.
- pgvector missing from the database, which surfaces only when the first query runs.

---

## Acceptance Criteria

**Safety**
1. A PDF with a JavaScript `OpenAction` is refused, and the reason names JavaScript.
2. A PDF with a `/Launch` action is refused.
3. A PDF carrying an executable attachment is refused.
4. **The real UnitedHealthcare policy is accepted**, despite its C2PA attachment and ten
   URIs.
5. A refused document leaves no stored file, no chunks, and no external call.
6. A PDF the scanner cannot parse is refused, not accepted by default.
7. Each policy signal has its own test, and the policy is enumerable in one place.

**Ingestion**
8. A 160-page document ingests without any web request exceeding a few seconds.
9. Chunks overlap, and a sentence spanning a boundary appears in both neighbours.
10. Every chunk has a non-null embedding of the expected dimension.
11. A failure part-way leaves a recorded failed state and a message, not a stuck spinner.
12. Re-uploading an already-ingested identical document does not re-embed it.

**Summary and answering**
13. A summary appears after ingestion without the whole document being sent — assertable
    on the outbound payload.
14. Asking a question sends only the retrieved chunks; no request ever contains the full
    text.
15. A question the document does not cover produces an explicit "not in this document"
    rather than a plausible invention.
16. An answer names where in the document it came from.

**Retention, links and deduplication**
21. External links found in a document are visible to the reader, and their presence
    never blocks the upload.
22. An hour after upload, the document, its chunks and its attached file are gone.
23. Uploading a document whose text matches one already ingested makes no embedding
    calls at all.
24. Embedding a 160-page document issues single-digit HTTP requests, not hundreds.

**Operational**
17. Document text never appears in any log file.
18. A 429 is logged with its quota id, and a daily cap is not described as momentary.
19. No test makes a network call; the suite passes with no API key present.
20. `bin/ci` is green — rubocop, bundler-audit, importmap audit, brakeman
    (`--exit-on-warn`), and the test suite.

---

## Answered Questions (record)

All resolved; the decisions they produced are in **Resolved Decisions** above,
which is authoritative. Kept verbatim as the record of what was asked and answered.

**Q1 — URI policy.** Every real document contains links; the UHC policy has ten, all
legitimate. Options: (a) allow all and ignore them; (b) allow, but show the reader the
list of external links found; (c) block on a domain blocklist; (d) block on heuristics
such as mismatched link text. (b) is honest and cheap; (c) and (d) risk rejecting
legitimate documents. Which?
**Answer:** b

**Q2 — Non-executable embedded files.** C2PA Content Credentials are benign and common.
An arbitrary embedded `.docx` or `.zip` is neither clearly hostile nor clearly safe.
Allow with a note, or block anything not on a known-benign allowlist?
**Answer:** Allow with a note

**Q3 — Retention.** Persistence reverses the MVP's core privacy promise. How long do
documents live — until explicitly deleted, a fixed window, or a background sweep? And
what does the UI promise about it? This determines whether Active Storage files sit on
disk indefinitely.
**Answer:** 1 hour

**Q4 — `ruby_llm` or the existing `GeminiClient`?** The current client is tested, handles
structured output and quota diagnostics, and has an injected transport that exists
because there is no mocking library. Adopting `ruby_llm` (1.16.0, actively maintained,
11.7M downloads) means rewriting a known-good component and devising a new test
strategy; keeping `Net::HTTP` means hand-rolling the embedding call, which is one
endpoint. `langchainrb` looks weaker on both counts (0.19.5, May 2025, 1.5M downloads).
**Answer:** the existing `GeminiClient`

**Q5 — Chunk size and overlap.** 500 words with overlap is a starting point, not a
validated choice; it interacts directly with retrieval quality. Ship the default and
tune later, or measure against the 140-page policy first?
**Answer:** Ship the default and tune later

**Q6 — Deduplication.** Hashing extracted text and reusing an existing document's chunks
would make repeated uploads of a common document nearly free. Worth building now, or
after there is evidence documents repeat?
**Answer:** Worth building now

**Q7 — Ingestion granularity.** One job for the whole document is simple but loses all
progress on failure and holds a worker for a long time. One job per chunk batch gives
progress and resumability at the cost of coordination. Which?
**Answer:** One job per chunk batch gives progress and resumability at the cost of coordination.

**Q8 — Billing.** Ingestion is roughly 200 embedding calls per document. The free tier's
daily cap was exhausted repeatedly by ordinary MVP testing, and this feature is far
hungrier. Is billing being enabled?
**Answer:** nope. I heard that Send chunks to an embedding model (like Gemini's text-embedding-004) is extremely cheap. Costing fractions of a cent for thousands of pages.

**Q9 — Rename the application?** The module is still `InsuranceHelper` and the directory
is `insurance_helper`, neither of which matches an any-PDF product. Rename now, live with
it, or leave it for later?
**Answer:** rename to PDFrag?

**Q10 — Branch name.** This needs its own branch off `main`; `mvp` should stay as the
working reference. `pdf-insight-rag` matches this spec's slug. Confirm, or name it
something else — you create it, I will not.
**Answer:** i'll create a pdf-rag off of `main`
