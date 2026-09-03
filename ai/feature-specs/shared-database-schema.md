# Feature Spec: shared-database-schema

## Summary

Move every table this app owns into a dedicated Postgres schema, `pdfrag`, so it
can live in one shared Render database alongside other prototype apps without
colliding with them. Isolation comes from Postgres rather than from a naming
convention: no table is renamed, no model changes, no migration is edited.

## Why a schema rather than a table prefix

The original request was a `pdfrag_` prefix on every table. A schema achieves the
same isolation with materially less work and fewer ways to get it wrong.

The decisive point is coverage. This app owns **eight** tables, not the three the
models declare:

| Table | Owner |
|---|---|
| `documents`, `document_chunks`, `messages` | this app |
| `active_storage_blobs`, `active_storage_attachments`, `active_storage_variant_records` | Active Storage |
| `schema_migrations`, `ar_internal_metadata` | Rails |

`schema_migrations` is the sharp edge. Two Rails apps sharing one migration
ledger each see the other's version numbers as already-run, so `db:migrate` can
conclude there is nothing to do. `ar_internal_metadata` holds the environment
name and is what makes `db:drop` refuse in production — shared, one app's guard
reads another app's row.

A prefix reaches all eight only if every one is remembered, in this app and in
every future migration. A schema covers them because Postgres puts them there.

## Findings

All of the following was measured against a scratch database, not assumed.

**A single `schema_search_path` does the entire job.** Running the existing,
unmodified migrations against `postgres://…/db?schema_search_path=pdfrag,public`
produced:

```
 schemaname |           tablename
------------+--------------------------------
 pdfrag     | active_storage_attachments
 pdfrag     | active_storage_blobs
 pdfrag     | active_storage_variant_records
 pdfrag     | ar_internal_metadata
 pdfrag     | document_chunks
 pdfrag     | documents
 pdfrag     | messages
 pdfrag     | schema_migrations
```

Eight of eight, including the two Rails-internal tables. Nothing in `app/`,
`db/migrate/` or the models was touched.

**`public` must stay on the search path.** The `vector` extension installs into
`public`, and extensions are not schema-relocatable once created. With
`search_path` set to `pdfrag` alone, `CREATE TABLE t (v vector(3))` fails —
the type cannot be resolved. With `pdfrag,public` it succeeds and the table still
lands in `pdfrag`. The trailing `,public` is load-bearing, not decoration.

**The schema must exist before the first migration.** Rails does not issue
`CREATE SCHEMA` on its own during `db:migrate`.

**`db/schema.rb` changes shape.** Dumping under the new search path rewrites 14
lines:

```ruby
  create_schema "pdfrag"

  enable_extension "public.vector"      # was: "vector"

  create_table "pdfrag.documents", …    # was: "documents"
```

The schema name becomes part of the committed schema file. This is the one real
cost of the approach and the main thing to decide about (Q3).

## Requirements

- R1. All eight tables live in the `pdfrag` schema in every environment —
  development, test, CI and production.
- R2. No table is renamed. No model declares `table_name`. No existing migration
  is edited.
- R3. The search path is configured in one place and includes `public`, so
  pgvector resolves.
- R4. A fresh database reaches a working schema with documented commands and no
  hand-written SQL beyond creating the schema itself.
- R5. Parallel test databases each get the schema; the suite runs unchanged.
- R6. `bin/ci` passes: 202 tests, rubocop, brakeman.
- R7. No application behaviour changes. Retention, screening, retrieval and chat
  are untouched.
- R8. Deployment documentation states how the schema is created on Render and
  what happens if it is missing.

## Non-Goals

- Renaming tables or adding prefixes. Superseded by this approach.
- Migrating existing data. Documents live one hour and there are no accounts, so
  nothing in any environment is worth preserving across the move.
- Isolating the other apps sharing the database. Each is responsible for its own
  schema; this spec covers only this app's side.
- Multi-tenancy or per-user row scoping. This separates *applications*, not users.
- Sharing the `vector` extension deliberately with co-tenants — it is
  database-wide by nature and simply left in `public`.
- Deploying to Render. This covers the change deployment requires, not the deploy.

## Edge Cases

- **The schema does not exist yet.** `db:migrate` fails on the first
  `create_table`. The failure should be legible rather than a bare Postgres
  error, and the fix documented in one line.
- **`public` dropped from the search path.** Every pgvector column breaks with an
  unresolved-type error that does not obviously point at `search_path`. Worth a
  test asserting the configured path, so a future edit that "tidies" it fails
  loudly in CI instead of at runtime.
- **Existing local databases were migrated into `public`.** Once the search path
  changes, Rails looks for `pdfrag.schema_migrations`, finds nothing, and treats
  the database as un-migrated. Development and test databases must be dropped and
  recreated — cheap here, but it must be stated.
- **Parallel test workers.** The suite runs one database per worker
  (`database.yml:14`). Each is built from `schema.rb`, which now begins
  `create_schema "pdfrag"`, so each should self-create — but this must be
  verified rather than assumed, since it is the difference between a green suite
  and eight identical failures.
- **A connection pooler in transaction mode.** `search_path` is per-connection
  state; a pooler that reuses backends across transactions can lose it. Render's
  standard Postgres connection is direct, but if a pooler is ever introduced this
  breaks in a way that looks like missing tables.
- **`bin/rails retention:sweep`** touches `ActiveStorage::Blob` directly
  (`sweep_expired_documents_job.rb:36`). It resolves through the same search
  path, but it is the one place the app queries an Active Storage table itself
  and deserves an explicit check.
- **A co-tenant app enables `vector` first.** Harmless — `CREATE EXTENSION IF NOT
  EXISTS` is what Rails emits, and the extension is shared by design.

## Acceptance Criteria

- AC1. `schema_search_path` is `pdfrag,public`, set in one place in
  `config/database.yml` and inherited by all environments.
- AC2. From an empty database plus `CREATE SCHEMA pdfrag`, `bin/rails db:migrate`
  succeeds and all eight tables report `schemaname = 'pdfrag'`.
- AC3. `public` contains no application table — only the `vector` extension.
- AC4. A test asserts the live connection's `schema_search_path` includes both
  `pdfrag` and `public`, so removing either fails CI.
- AC5. `bin/rails test` passes with the same 202 runs, 0 failures, under parallel
  workers.
- AC6. `db/schema.rb` is regenerated, contains `create_schema "pdfrag"`, and every
  `create_table` is schema-qualified.
- AC7. `bin/rubocop` and `bin/brakeman --exit-on-warn` stay clean.
- AC8. An end-to-end upload → ingest → embed → summarise → question run works
  against the relocated schema, verified manually against the 140-page policy.
- AC9. `README.md` documents the schema, the required `CREATE SCHEMA` step, and
  why `public` stays on the search path.

## Resolved Decisions

No questions remain open. Answered 2026-09-03.

**D1. The Render user can create a schema.** Verified against
`dpg-d08s0s95pdvs739qvet0-a`: `can_create_schema = t`, `can_create_database = t`,
as `general_postgres_db_user` on `general_postgres_db`.

The same check found the database **already occupied by another Rails app** in
`public`: `ar_internal_metadata`, `schema_migrations`, `slack_users`, and eleven
`solid_queue_*` tables. `schema_migrations` and `ar_internal_metadata` are taken.
Deploying this app into `public` would have merged its migration ledger with that
app's — the failure this spec exists to prevent, observed rather than predicted.

**D2. A schema, not a separate database** — even though `can_create_database` is
also true. Render injects a `DATABASE_URL` pointing at `general_postgres_db`, so a
separate database would mean overriding the connection path in every app and
holding a database the platform's dashboard and backups do not track. A schema
needs only `schema_search_path` alongside the URL Render already supplies.
Backups are moot here in any case — nothing outlives an hour.

**D3. The schema is named `pdfrag`**, matching the `PdfRag` module.

**D4. `db/schema.rb` stays; the churn is accepted.** The dump gains
`create_schema "pdfrag"` and schema-qualifies every table — a one-time 14-line
diff. `structure.sql` would capture extension placement more exactly, but
`schema.rb` stays readable in review, which matters more on an app this size.

**D5. The schema is created idempotently, not once by hand.** A prototype
database is exactly the kind that gets rebuilt without ceremony, so creation must
be self-healing wherever migrations run.

**D6. The schema name is hardcoded, not configurable.** An environment variable
would let one image run twice against one database, which is not a need here, and
it would contradict D4 by making `schema.rb`'s literal `pdfrag.` wrong for any
other value.
