# Plan: pdf-insight-rag

Spec: `ai/feature-specs/pdf-insight-rag.md` (D1–D10 resolved, no open questions).
Branch: `pdf-rag`, cut from `main` and merged from `mvp` at `98b73f4`.

## Confirmed Decisions

| # | Decision |
|---|---|
| D1 | URIs never block; the links found are shown to the reader |
| D2 | Non-executable embedded files allowed, and named alongside the links |
| D3 | Retention: one hour, then document, chunks and file are gone |
| D4 | Keep the existing `GeminiClient`; add `#embed`. No new AI gem |
| D5 | 500-word chunks with overlap as a starting point; tune after it works |
| D6 | Deduplicate by content hash from the start |
| D7 | One ingestion job per chunk batch, for progress and resumability |
| D8 | Free tier, made viable by batching — **100 chunks per request, API hard limit** |
| D9 | Rename to `PdfRag` / `pdf_rag` |
| D10 | Branch `pdf-rag` — already created |

---

## Approach

### Where screening happens, and why it costs a second or two
R1.5 says a refused document is never stored. That forces screening **into the request**,
before Active Storage attaches anything — a job would have to store the file first, which
is exactly what the requirement forbids.

Measured on the real 140-page policy: **2,368ms total — 2,350ms of it parsing**, and only
18ms walking 5,097 objects for signals. So the cost is inherent to reading the PDF, not to
the policy checks, and no amount of cleverness in the scanner reduces it.

That makes upload a ~2.5s request. Acceptable, and the honest trade for the guarantee that
hostile files never touch storage. Everything after screening is asynchronous.

### Pipeline
```
POST /documents
  ├─ DocumentValidator      magic bytes, size          (carried over, unchanged)
  ├─ PdfSafetyScanner       origamindee, D1/D2 policy  (~2.4s, in-request)
  ├─ reject → nothing stored, nothing sent anywhere
  └─ accept → Document created + file attached, status: extracting
                 └─ IngestDocumentJob
                      ├─ extract text (no page cap — retrieval replaces it)
                      ├─ content_hash → if a ready twin exists, copy its chunks, done
                      ├─ chunk at ~500 words with overlap
                      ├─ create DocumentChunk rows with null embeddings
                      └─ enqueue EmbedChunkBatchJob per 100 chunks
                            └─ last batch to finish enqueues SummarizeDocumentJob
```

### Batch coordination without a coordinator
`EmbedChunkBatchJob` embeds its slice, saves the vectors, then asks whether any chunk on
the document still has a null embedding. The batch that finds none is the last one, and it
enqueues the summary. No counters, no locks, no job-completion callbacks — the database
already knows the answer, and a retried batch reaches the same conclusion.

### Deduplication
`Document#content_hash` is a SHA-256 of the extracted text. On a hit against a `ready`
document, chunk rows are **copied** — content and embedding — rather than shared. Copying
costs storage but keeps `belongs_to :document` simple and means retention deletion cannot
strand another document's chunks. Zero embedding calls, which AC 23 asserts.

### Retention as data, not just a job
Every document gets `expires_at` (upload + 1 hour) and a `DeleteDocumentJob` scheduled for
then. **Queries scope to `expires_at > now` regardless**, so a job that never runs — lost
queue, restart, bug — cannot expose an expired document. The job is how the bytes get
freed; the column is what makes the promise true.

### Retrieval
`neighbor` on `DocumentChunk`, cosine distance over `vector(3072)`. Two callers:
- **Summary**: embed the fixed anchor phrase ("executive summary, conclusion, abstract,
  main findings"), take the top 5, ask for 3–5 bullets.
- **Q&A**: embed the question, take the top 3, answer strictly from them, cite positions.

Both go through one `ChunkRetriever` so "how many, and how ranked" lives in one place.

### GeminiClient gains one method
`#embed(texts)` → `batchEmbedContents`, slicing at 100 (the API's hard limit, confirmed by
its own 400 response). Same injected transport, so it is testable with the existing fake.
No new gem.

---

## Files Touched

**Foundations**
- `config/application.rb` — module `InsuranceHelper` → `PdfRag`; uncomment
  `active_record/railtie` and `active_storage/engine`
- `config/database.yml` — new
- `config/storage.yml` — new
- `Gemfile` — add `pg`, `neighbor`, `origamindee`
- `config/environments/*.rb`, `config/cable.yml`, `config/deploy.yml`,
  `app/views/pwa/manifest.json.erb` — the remaining 8 rename references
- `db/migrate/*` — Active Storage tables, `documents`, `document_chunks`, `messages`
- `CLAUDE.md` — currently describes a freshly generated app; full rewrite

**Deleted (insurance-specific)**
- `app/services/session_cache.rb`, `insurance_session.rb`, `question_answerer.rb`
- `app/presenters/plan_presenter.rb`
- `app/controllers/sessions_controller.rb`, `concerns/session_scoped.rb`
- `app/views/sessions/_plan`, `_chat`, `_grounding_note`, `_replace_document`,
  `_removed_notice`
- their tests: `session_cache_test`, `insurance_session_test`, `question_answerer_test`,
  `session_lifecycle_test`, `plan_screen_test` (both), `chat_test`, `document_analysis_test`

**Kept unchanged**
- `app/services/document_validator.rb`, `processing_error.rb`
- `app/services/gemini_client/net_http_transport.rb`
- `app/assets/tailwind/application.css` and `test/services/palette_test.rb`
- `test/support/fake_gemini_transport.rb`, `gemini_stubbing.rb`

**Modified**
- `app/services/pdf_extraction_service.rb` — drop `MAX_PAGES`; retrieval replaces the cap
- `app/services/gemini_client.rb` — add `#embed`; drop `analyze_document`'s insurance
  schema in favour of a summary call
- `app/controllers/documents_controller.rb` — screen, create, attach, enqueue
- `app/views/sessions/_processing.html.erb` — reused as-is for ingestion progress

**New**
- `app/models/document.rb`, `document_chunk.rb`, `message.rb`
- `app/services/pdf_safety_scanner.rb` and `pdf_safety_policy.rb`
- `app/services/text_chunker.rb`, `chunk_retriever.rb`
- `app/jobs/ingest_document_job.rb`, `embed_chunk_batch_job.rb`,
  `summarize_document_job.rb`, `delete_document_job.rb`
- `app/controllers/messages_controller.rb` — rewritten around retrieval
- views for upload, document, chat

---

## Checkpoints

1. **Foundations and demolition.** Rename to `PdfRag`. Enable Active Record and Active
   Storage. Add `pg`, `database.yml`, install pgvector and `CREATE EXTENSION`. Add
   `neighbor` and `origamindee`. Delete the insurance-specific code and its tests.
   *Green means:* the suite passes with the insurance tests gone, and a migration runs.

2. **Safety screening.** `PdfSafetyScanner` + `PdfSafetyPolicy` implementing D1/D2, wired
   into the upload path before anything is stored. Hostile fixtures generated with
   origamindee.
   *Verifies:* AC 1–7.

3. **Models and ingestion.** `Document`, `DocumentChunk`, `TextChunker`,
   `IngestDocumentJob`, dedup by content hash. Chunks created without embeddings.
   *Verifies:* AC 9, 12.

4. **Embedding.** `GeminiClient#embed`, `EmbedChunkBatchJob`, batch coordination, status
   transitions.
   *Verifies:* AC 8, 10, 11, 24.

5. **Summary.** `ChunkRetriever`, the generic-anchor query, `SummarizeDocumentJob`.
   *Verifies:* AC 13.

6. **Q&A.** Retrieval-backed answering with citations and persisted history.
   *Verifies:* AC 14–16.

7. **Retention.** `expires_at`, query scoping, `DeleteDocumentJob`, and the UI copy that
   states the hour.
   *Verifies:* AC 22.

8. **Interface, docs and hardening.** Upload/document/chat screens, links and attachments
   surfaced, `CLAUDE.md` rewrite, README, changelog.
   *Verifies:* AC 17–21.

---

## Test Plan

### Tooling that exists
`bin/rails test` (Minitest, parallel), `bin/rails test:system` (Chrome, not in `bin/ci`),
`bin/rubocop`, `bin/brakeman --exit-on-warn`, `bin/bundler-audit`, `bin/importmap audit`,
sequenced by `bin/ci`. Carried over: the injected-transport pattern, `FakeGeminiTransport`,
and the `setup` hook that makes any unstubbed Gemini call fail loudly.

### Tooling that does not exist
- **No mocking library.** Minitest 6 dropped `Minitest::Mock`; no webmock. Every external
  seam stays injectable. `GeminiClient#embed` must be drivable through the existing fake.
- **A database now exists**, which is new for this project: fixtures or factories, and
  `parallelize` needs per-worker databases. Neither has ever been configured here.
- **pgvector must be present in the test database too**, or every retrieval test fails on
  a missing extension rather than on the code.

### Tests to add
**Safety (`test/services/pdf_safety_scanner_test.rb`)** — one test per policy signal:
JavaScript OpenAction blocked; `/Launch` blocked; executable attachment blocked;
unparseable PDF blocked; C2PA-style attachment allowed; a document with ten URIs allowed
and the URIs returned. Hostile fixtures are **generated with origamindee at test time or
by a rake task**, not committed as binaries — building them is how we know what is in them.

**AC 4 needs care.** It says the real UnitedHealthcare policy must be accepted. That file
is 4.2MB and is the user's, so committing it is a judgement call. Plan: a synthetic
fixture reproducing the same signals (one benign attachment, ten assorted URIs including a
malformed one), plus a documented manual check against the real file. **The automated test
is a proxy; it does not prove the real document passes.**

**Ingestion** — chunk overlap: a sentence spanning a boundary appears in both neighbours;
a short document yields one chunk; a document whose hash matches a ready one creates zero
embedding calls; a failed batch leaves the document in a failed state, not stuck.

**Embedding** — batches never exceed 100; a 200-chunk document issues 2 requests, not 200
(AC 24, asserted on the fake's call count); a 429 mid-ingestion leaves the document
resumable; no request payload ever contains the whole document text.

**Retrieval and answering** — the outbound payload contains only retrieved chunks;
a question with no relevant chunks produces an explicit refusal; answers carry citations.

**Retention** — a document past `expires_at` is invisible to queries *even if the delete
job never ran*; the job removes rows and the attached file.

### Manual verification
- The real 140-page policy: accepted, ingested, and answerable
- Retrieval quality — whether 500-word chunks actually surface the right passages is a
  judgement no assertion makes for us (D5 defers this deliberately)
- Screen reader behaviour on the new screens
- That an hour later, the file is genuinely gone from disk

---

## Risks / Rollback

**Setup**
- **pgvector may not install cleanly.** Homebrew reports a nonzero build-error rate, and
  only `postgresql@14` is present while brew's default formula is newer. `pg_config` on
  PATH is 14.24, which is the good case, but if the bottle targets a different major
  version the fallback is building pgvector from source with `PG_CONFIG` set. This is
  checkpoint 1 and blocks everything.
- **Parallel test databases have never been configured here.** The suite currently runs
  parallel with no database at all; adding one without per-worker databases produces
  confusing cross-test failures.

**Design**
- **Upload is now a ~2.5s request** because screening must precede storage. If that
  becomes unacceptable, the only way out is relaxing R1.5's "never stored" guarantee.
- **Chunk quality is unvalidated** (D5). Bad boundaries degrade every answer, and the
  failure is silent — plausible answers from the wrong passage.
- **Retention leans on a scheduled job.** The `expires_at` scoping means a lost job cannot
  leak data, but it can leak *storage*, and nothing yet sweeps orphans.
- **Copying chunks on dedup** duplicates vectors. Cheap now, wasteful if one document is
  uploaded hundreds of times.

**Operational**
- Embedding and generation draw on **separate quota buckets**; a 429 was observed on a
  100-chunk batch immediately after a 50-chunk one. Ingestion must survive it mid-document.
- Brakeman runs with `--exit-on-warn`; Active Storage upload handling is a likely trigger.
- **The privacy story changes shape.** Files now sit on disk for an hour. That is the
  decision (D3), but it is worth stating in the UI rather than leaving implied.

**Rollback**
Checkpoint 1 is the only irreversible-feeling one, because it deletes the insurance
feature — but `mvp` holds all of it, unchanged, so nothing is actually lost. Every later
checkpoint is additive: models, jobs and services that can be reverted individually. There
are migrations from checkpoint 1 onward, so rollback past that point means `db:rollback`,
not just reverting code.
