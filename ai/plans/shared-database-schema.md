# Plan: shared-database-schema

## Confirmed Decisions

From the spec's Resolved Decisions, all settled:

- **D1.** The Render user can create schemas (`can_create_schema = t`). The target
  database already holds another Rails app in `public`, including
  `schema_migrations` and `ar_internal_metadata`.
- **D2.** A Postgres schema, not a separate database, despite
  `can_create_database` also being true.
- **D3.** The schema is named `pdfrag`.
- **D4.** `db/schema.rb` stays; its 14-line churn is accepted over `structure.sql`.
- **D5.** The schema is created idempotently wherever migrations run, not once by
  hand.
- **D6.** The schema name is hardcoded.

## Research findings

Measured during planning, not assumed. Two change the shape of the work.

**`schema_search_path` in `database.yml` survives Render's `DATABASE_URL`.**
With the setting in the `default:` anchor and `DATABASE_URL` supplying only the
connection, the live connection reported `SHOW search_path` → `pdfrag, public`.
So one line in `database.yml` covers production without touching the URL Render
injects. This was the main open risk and it is clear.

**A missing schema fails silently, and dangerously.** With
`search_path = pdfrag,public` and no `pdfrag` schema, Postgres does not error —
it skips the missing entry and uses the next one:

```
SET search_path TO pdfrag,public; CREATE TABLE documents (id int);
  → public.documents
```

So if schema creation is ever skipped, the app deploys straight into `public`,
colliding with the Slack app already there, with no error to notice. **This is the
central risk of the change**, and it drives two things below: creation must be
guaranteed rather than documented, and there must be a guard that fails loudly
rather than a comment asking people to be careful.

**GitHub Actions cannot currently run the test job.** `.github/workflows/ci.yml`
has no `services: postgres`, no pgvector, and no `db:prepare` — the Postgres
migration never reached it (lines 68–91; the Redis service is commented out at
71–76). This is pre-existing and unrelated to this change, but it means "CI is
green" cannot be a completion signal. Treated as out of scope below, and called
out rather than quietly worked around.

**`bin/docker-entrypoint` does not run migrations.** It is a bare `exec "${@}"`,
so nothing prepares the database on container boot. Whatever creates the schema
must therefore run from an explicit deploy step, not be assumed to happen.

## Approach

Four changes, one of which is the whole feature and three of which exist to stop
it failing silently.

**1. Set the search path in one place.** `schema_search_path: pdfrag,public` in
the `default: &default` anchor of `config/database.yml`, inherited by
development, test and production. `public` is load-bearing — the `vector`
extension lives there and cannot be relocated, so dropping it breaks every
embedding column.

**2. Guarantee the schema exists wherever migrations run.** A rake task,
`db:ensure_schema`, issuing `CREATE SCHEMA IF NOT EXISTS pdfrag`, hooked onto
`db:migrate` and `db:prepare` via `Rake::Task#enhance`. Platform-independent, so
it covers local, CI and Render alike rather than being a Render-specific deploy
command — which satisfies D5 more completely than a `render.yaml` hook would.

The ordering hazard to watch: `enhance` runs the prerequisite *before* the task,
and `db:prepare` may need to create the database first. The task must tolerate a
missing database by no-opping rather than raising, letting `db:prepare` proceed to
create it and load `schema.rb` — which itself begins `create_schema "pdfrag"`.
This is the fiddliest part of the change and gets its own checkpoint.

**3. Guard against the silent-fallback failure.** Two layers, because the failure
mode is invisible:

- `db:ensure_schema` verifies after creating, raising if `pdfrag` is absent from
  `pg_namespace` — turning a silent fallback into a failed deploy.
- A test asserts the live connection's search path names `pdfrag` first and
  `public` second, so a future edit that "tidies" either one fails in CI rather
  than at runtime.

**4. Regenerate `db/schema.rb`** under the new search path, accepting the
schema-qualified names per D4.

Nothing in `app/`, `db/migrate/` or the models changes. That is the point of the
approach and should stay true through implementation — if a model or migration
starts needing edits, something has gone wrong.

## Files Touched

- `config/database.yml` — add `schema_search_path: pdfrag,public` to the
  `default:` anchor.
- `lib/tasks/db_schema.rake` — **new.** `db:ensure_schema` plus the `enhance`
  hooks onto `db:migrate` and `db:prepare`.
- `db/schema.rb` — regenerated; gains `create_schema "pdfrag"`,
  `enable_extension "public.vector"`, and schema-qualified table names.
- `test/integration/database_namespace_test.rb` — **new.** Asserts the search
  path and that every application table resolves to the `pdfrag` schema.
- `README.md` — document the schema, why `public` stays on the path, and the
  local reset required.
- `CLAUDE.md` — add to "Things that will bite": the silent fallback to `public`
  when the schema is missing.

Explicitly **not** touched: `app/`, `db/migrate/`, `config/environments/*`,
`Dockerfile`, `bin/docker-entrypoint`.

## Checkpoints

None. The change is one config line, one rake task, one test and a regenerated
dump — small enough to do in a single pass, and reversible with `git checkout`.
Staged approval gates would cost more than the work.

Two ordering constraints stand in for them, because both are easy to skip and
each is the difference between the change working and only appearing to:

**The guard is proven deliberately, against a database with no `pdfrag` schema.**
Building everything at once and finding it works proves nothing — the schema may
simply have existed already. The guard must be watched failing before it is
trusted, since the failure it exists to catch is silent by nature.

**`db:prepare` is tested against a database that does not yet exist.** The
`enhance` hook runs before the task, so getting it wrong breaks setup on a fresh
machine while working everywhere it was developed.

Everything else — the `database.yml` line, the rake task, the namespace test, the
local reset, the regenerated `db/schema.rb`, `README.md` and `CLAUDE.md` — can be
done in any order and is verified by the test plan below.

Finish with the manual end-to-end run: upload → screen → ingest → embed →
summarise → question against the 140-page policy, plus `bin/rails
retention:sweep`, which is the one place the app queries an Active Storage table
directly.

## Test Plan

**New — `test/integration/database_namespace_test.rb`:**

- The connection's `schema_search_path` is exactly `pdfrag,public`.
- `SHOW search_path` on the live connection names `pdfrag` before `public`.
- The `pdfrag` schema exists in `pg_namespace` — the assertion that would have
  caught the silent fallback.
- Every application table — `documents`, `document_chunks`, `messages`, and the
  three Active Storage tables — resolves to `schemaname = 'pdfrag'` via
  `pg_tables`.
- `schema_migrations` and `ar_internal_metadata` are in `pdfrag`, not `public`.
- No application table exists in `public`.

**Existing suite:** all 202 runs must pass unchanged, under
`parallelize(workers: :number_of_processors)` (`test/test_helper.rb:10`). No test
should need editing; if one does, the change has leaked further than intended.

**Manual, because no tooling covers it:**

- `db:prepare` against a non-existent database.
- `db:migrate` against an existing database whose schema was dropped.
- The end-to-end document run in checkpoint 5, since every Gemini seam is stubbed
  in tests and the real pipeline is only exercised by hand.

**Tooling that exists:** `bin/rails test`, `bin/rubocop`, `bin/brakeman
--exit-on-warn`, `bin/ci`. All must stay green.

**Tooling that does not:** GitHub Actions cannot run the test job (no Postgres
service). Local `bin/ci` is the completion signal for this work.

## Risks / Rollback

**Silent fallback to `public` — the one that matters.** If the schema is missing,
Postgres writes to `public` without complaint, colliding with the Slack app
already there. Mitigated by creation being automatic (checkpoint 1) and by the
guard failing loudly (checkpoint 2). Worth stating plainly: if only one thing
from this plan survives review, it should be the guard.

**Parallel test workers may not self-create the schema.** `schema.rb` begins
`create_schema "pdfrag"`, so they should. If they do not, the fallback is to
extend `db:ensure_schema` to `db:test:prepare`. Failure is loud — eight identical
errors, not a subtle bug.

**A connection pooler would break this.** `search_path` is per-connection state,
and a pooler in transaction mode can lose it — which would look like missing
tables while quietly reading `public`. Render's standard Postgres connection is
direct. Worth a line in the README so it is not discovered the hard way later.

**`enhance` ordering on `db:prepare`.** Getting this wrong makes database setup
fail on fresh machines while working everywhere it was tested. Checkpoint 1
verifies it against a database that does not exist.

**Rollback is cheap.** Remove the `database.yml` line, delete the rake task and
test, restore `db/schema.rb` from git, and recreate the local databases. Nothing
in `app/` or `db/migrate/` changed, so there is no code to unwind, and no data
anywhere is worth preserving. On Render, the `pdfrag` schema can be dropped
outright.

## Out of scope

- **Fixing GitHub Actions.** The test and system-test jobs have never had a
  Postgres service since the pgvector migration. Real, pre-existing, and worth
  its own change — mentioning it here so it is a decision rather than an
  oversight.
- **The co-tenant Slack app's exposure.** It sits in `public` with generic table
  names and has the same collision risk with whatever is deployed next. Not this
  app's to fix, but it will want its own schema eventually.
- **Creating a `render.yaml`.** Deployment configuration is a separate concern;
  this plan only ensures the schema step is idempotent wherever it runs.
