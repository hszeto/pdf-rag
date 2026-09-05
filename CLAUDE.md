# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`PdfRag` — upload a PDF, have it screened for hostile content, chunked and embedded
into Postgres, then ask questions answered from the passages that matter rather than
from the whole document. Documents are kept for **thirty minutes**, then removed.

The `mvp` branch holds a superseded insurance-specific version of this app. It is a
working reference, not dead code — several services here came from it unchanged.

## Commands

```bash
bin/setup              # install deps, clear logs/tmp, then exec bin/dev
bin/setup --skip-server   # deps only; what bin/ci runs first
bin/dev                # foreman: server + tailwind watch + sidekiq worker

bin/ci                 # setup, rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/rails test                        # all non-system tests
bin/rails test test/services/text_chunker_test.rb          # one file
bin/rails test test/services/text_chunker_test.rb:42       # one test, by line
bin/rails test test/services test/jobs                     # one or more directories
bin/rails test -n /retention/                              # by name pattern
bin/rails test:system                 # Chrome; NOT in bin/ci
bin/rails retention:sweep             # remove expired documents and orphaned files
```

## Prerequisites

- **PostgreSQL 14** with **pgvector**. Homebrew's `pgvector` bottle only ships for
  postgresql@17/@18; on pg14 it must be built from source against `pg_config`. The
  extension is enabled by a migration, so a fresh `db:migrate` sets it up.
- **All tables live in the `pdfrag` schema**, not `public`, so this app can share one
  database with others. `schema_search_path: pdfrag,public` in `database.yml`; the
  schema is created by `db:ensure_schema`, hooked onto `db:migrate` and `db:prepare`.
- **Redis** — cache on DB 0, Action Cable DB 1, Sidekiq DB 2. `brew services start redis`.
  Only development and production need it: the test environment uses the `:test` queue
  adapter, so tests assert the enqueue (`assert_enqueued_with`) and drive the job itself
  with `perform_now`. Nothing in the suite needs a running Redis or worker.
- **`gemini_api_key` in Rails encrypted credentials.** Models: `gemini-2.5-flash` for
  generation, `gemini-embedding-001` (3072 dimensions) for vectors.

## Architecture

**The pipeline.** Upload → validate → **screen** → store → ingest → embed → summarise.
Screening runs *on the request*, before Active Storage stores anything, because a
refused document must never be written anywhere. It costs ~2s on a 140-page file,
almost entirely PDF parsing. Everything after that is Sidekiq, and only the document
id ever crosses the queue — never its text.

`Document#status` walks `pending → extracting → embedding → summarizing → ready`, or
`failed` with a `failure_reason` written for the reader. Every job re-loads through
`Document.live` and returns quietly if the document is gone or has moved on, because a
queued job can outlive the thing it was queued for.

**Nothing sends the document to the model.** A generic-anchor query retrieves the
passages that describe a document, and questions retrieve the three nearest passages.
Measured on a 140-page policy: summarising sent 1.7% of it, in two API calls. There is
deliberately **no full-text fallback** — if the retrieved passages do not answer a
question, saying so is the answer.

**Batching is by token budget, not item count** (`EmbeddingBatches`). The API caps a
request at 100 items, but the free tier rejects on a per-minute token budget long
before that. Batching by count builds requests it refuses every time.

**Retention is a column, not a job.** `Document.live` scopes every read to
`expires_at`, so a document past its window is unreachable whether or not anything has
deleted it. `DeleteDocumentJob` and the sweep only free bytes. Purging is synchronous —
Active Storage's `purge_later` would leave the file on disk if that second job were lost.

**Safety is policy, not detection.** `PdfSafetyScanner` finds signals;
`PdfSafetyPolicy` decides what they mean, in one enumerable table. Scripts, launch
actions and attached programs are blocked; links and ordinary attachments are shown to
the reader. A real insurance policy carries a provenance attachment and ten legitimate
links — blocking on either would reject the most representative document available.

## Testing

- **No mocking library.** Minitest 6 dropped `Minitest::Mock`; there is no webmock. Every
  external seam is injected. `test_helper.rb` points `GeminiClient.transport_factory` at
  a lambda that *raises*, so a forgotten stub fails loudly instead of making a real
  billed call.
- **`stub_gemini(*responses) { |fake| ... }`** (`test/support/gemini_stubbing.rb`) swaps
  the transport for the block and restores it after. Build responses with the helpers
  beside it — `gemini_embeddings(n)`, `gemini_summary(...)`, `gemini_answer(...)` — rather
  than hand-writing 3072-float vectors or the `candidates/content/parts` nesting.
  `FakeGeminiTransport` also records requests, so tests assert on the payload sent.
- **Hostile PDFs are generated, not committed** (`test/support/hostile_pdfs.rb`, via
  `origamindee`). One builder per policy signal: a checked-in `malicious.pdf` is opaque,
  and a test asserting it gets blocked proves nothing about *why*. Real PDFs for
  extraction and retrieval live in `test/fixtures/files/`.
- **Tests run in parallel** with per-worker databases. They must not depend on
  macOS-only tools; CI is ubuntu.

## Working in this repo

Features follow the **ASDD** workflow, installed globally at
`~/.claude/skills/asdd/SKILL.md` and shared by every project here, driven by
`/feature-spec` → `/feature-plan` → `/feature-implement` → `/commit-message`. Read the
skill before starting a feature; the parts that catch people out:

- **Two hard approval gates** — a spec in `ai/feature-specs/<name>.md`, then a plan in
  `ai/plans/<name>.md`. Neither is assumed; both are approved in conversation.
- **Git is hands-off.** Never branch, commit, or push. Checkpoints are commit-sized units
  of work reported with their message, not commits to run — the user runs every git write.
- **Implement one checkpoint at a time**, verifying and reporting before starting the next.
- **Work lands through pull requests, and `main` auto-deploys to Render.** Branch before
  the first edit of a feature. A global hook warns when a file is edited on `main`, but it
  warns — it does not stop anything.
- **`R1.5`, `D3`, `R7.5` in comments are requirement and decision ids** from the feature
  spec that introduced the code. When a comment cites one, `ai/feature-specs/` explains
  what was being guaranteed and why — that is where the reasoning lives, not in git.

## Things that will bite

- **A missing Postgres schema fails silently.** `search_path` is `pdfrag,public`, and
  Postgres *skips* an entry that does not exist rather than erroring — so without the
  `pdfrag` schema the app creates its tables in `public`, beside every other app
  sharing the database, and says nothing. `db:ensure_schema` exists to make that
  impossible; `DatabaseNamespaceTest` exists to notice if it ever becomes possible again.
- **PDF actions hide in three places.** An `OpenAction` on the Catalog is a *direct*
  dictionary that `each_object` never yields, and annotation actions hang off each page.
  A scanner that walks only indirect objects finds nothing and accepts everything.
- **Stimulus controller state does not survive polling.** The processing screen replaces
  the page every few seconds, so elapsed time comes from a server-supplied timestamp.
  Anything held in `connect()` resets before it can fire.
- **`allow_browser versions: :modern`** returns 406 to older browsers.
- **Brakeman runs with `--exit-on-warn`** — any warning fails `bin/ci`.
- **Uploads and questions are rate limited per visitor** — five documents an hour,
  twenty questions a minute — and the limiter *fails closed*: if the counter store
  is unreachable the request is refused rather than admitted. See
  `FailClosedStore` for why Rails' own behaviour is the opposite.
- **`request.remote_ip` needs Cloudflare's ranges** to be the visitor rather than
  Render's edge. They are listed in `config/application.rb` with the date they
  were taken; if Cloudflare adds a range, every visitor behind it shares one
  rate-limit bucket again.

## Layout

```
ai/               feature-specs/ and plans/ — the reasoning behind the R# and D# ids
lib/              database_schema_namespace (the pdfrag schema), tasks/
app/services/     pdf_safety_{scanner,policy}, document_validator, pdf_extraction_service,
                  text_chunker, embedding_batches, chunk_retriever, document_summarizer,
                  question_answerer, gemini_client, processing_error
app/jobs/         ingest → embed_chunk_batch → summarize; delete + sweep for retention
app/models/       document, document_chunk, message
test/support/     gemini_stubbing, fake_gemini_transport, hostile_pdfs
```
