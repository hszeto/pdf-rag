# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`PdfRag` — upload a PDF, have it screened for hostile content, chunked and embedded
into Postgres, then ask questions answered from the passages that matter rather than
from the whole document. Documents are kept for **one hour**, then removed.

The `mvp` branch holds a superseded insurance-specific version of this app. It is a
working reference, not dead code — several services here came from it unchanged.

## Commands

```bash
bin/setup              # install deps, clear logs/tmp, then exec bin/dev
bin/dev                # foreman: server + tailwind watch + sidekiq worker

bin/ci                 # setup, rubocop, bundler-audit, importmap audit, brakeman, tests
bin/rubocop
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
bin/rails test                        # all non-system tests
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
- **`gemini_api_key` in Rails encrypted credentials.** Models: `gemini-2.5-flash` for
  generation, `gemini-embedding-001` (3072 dimensions) for vectors.

## Architecture

**The pipeline.** Upload → validate → **screen** → store → ingest → embed → summarise.
Screening runs *on the request*, before Active Storage stores anything, because a
refused document must never be written anywhere. It costs ~2s on a 140-page file,
almost entirely PDF parsing. Everything after that is Sidekiq.

**Nothing sends the document to the model.** A generic-anchor query retrieves the
passages that describe a document, and questions retrieve the three nearest passages.
Measured on a 140-page policy: summarising sent 1.7% of it, in two API calls. There is
deliberately **no full-text fallback** — if the retrieved passages do not answer a
question, saying so is the answer.

**Batching is by token budget, not item count** (`EmbeddingBatches`). The API caps a
request at 100 items, but the free tier rejects on a per-minute token budget long
before that. Batching by count builds requests it refuses every time.

**Retention is a column, not a job.** `Document.live` scopes every read to
`expires_at`, so a document past its hour is unreachable whether or not anything has
deleted it. `DeleteDocumentJob` and the sweep only free bytes. Purging is synchronous —
Active Storage's `purge_later` would leave the file on disk if that second job were lost.

**Safety is policy, not detection.** `PdfSafetyScanner` finds signals;
`PdfSafetyPolicy` decides what they mean, in one enumerable table. Scripts, launch
actions and attached programs are blocked; links and ordinary attachments are shown to
the reader. A real insurance policy carries a provenance attachment and ten legitimate
links — blocking on either would reject the most representative document available.

## Things that will bite

- **A missing Postgres schema fails silently.** `search_path` is `pdfrag,public`, and
  Postgres *skips* an entry that does not exist rather than erroring — so without the
  `pdfrag` schema the app creates its tables in `public`, beside every other app
  sharing the database, and says nothing. `db:ensure_schema` exists to make that
  impossible; `DatabaseNamespaceTest` exists to notice if it ever becomes possible again.
- **No mocking library.** Minitest 6 dropped `Minitest::Mock`; there is no webmock. Every
  external seam is injected. `test_helper.rb` makes any unstubbed Gemini call raise, so a
  forgotten stub fails loudly instead of making a real billed call.
- **PDF actions hide in three places.** An `OpenAction` on the Catalog is a *direct*
  dictionary that `each_object` never yields, and annotation actions hang off each page.
  A scanner that walks only indirect objects finds nothing and accepts everything.
- **Stimulus controller state does not survive polling.** The processing screen replaces
  the page every few seconds, so elapsed time comes from a server-supplied timestamp.
  Anything held in `connect()` resets before it can fire.
- **`allow_browser versions: :modern`** returns 406 to older browsers.
- **Brakeman runs with `--exit-on-warn`** — any warning fails `bin/ci`.
- **Tests run in parallel** with per-worker databases. They must not depend on
  macOS-only tools; CI is ubuntu.
- **The Gemini free tier's daily cap** is exhausted by embedding roughly one large
  document. This blocked verification repeatedly during development.

## Layout

```
lib/              database_schema_namespace (the pdfrag schema), tasks/
app/services/     pdf_safety_{scanner,policy}, pdf_extraction_service, text_chunker,
                  embedding_batches, chunk_retriever, document_summarizer,
                  question_answerer, gemini_client, processing_error
app/jobs/         ingest → embed_chunk_batch → summarize; delete + sweep for retention
app/models/       document, document_chunk, message
```
