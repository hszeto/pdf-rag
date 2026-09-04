# PdfRag

Upload a PDF, get a short summary of what it is, and ask questions answered from the
parts of it that matter. Documents are kept for thirty minutes and then removed.

The document itself is never sent to a language model. It is split into overlapping
passages, each embedded into Postgres, and only the few passages relevant to a question
are used to answer it. On a real 140-page policy, generating a summary sent **1.7%** of
the document in two API calls — and a five-page document costs the same two.

## Getting set up

You need PostgreSQL, Redis, and a Gemini API key.

```bash
brew install postgresql@14 redis
brew services start postgresql@14
brew services start redis
```

**pgvector** provides the vector column type. Homebrew's bottle is built for
postgresql@17 and @18, so on postgresql@14 it has to be compiled against your own
`pg_config`:

```bash
curl -sL https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.6.tar.gz | tar xz
cd pgvector-0.8.6 && make PG_CONFIG=$(which pg_config) && make install PG_CONFIG=$(which pg_config)
```

The `vector` extension itself is enabled by a migration, so nothing needs creating by
hand — including in each parallel test database.

**The API key** goes in Rails encrypted credentials as `gemini_api_key`:

```bash
bin/rails credentials:edit
```

Then:

```bash
bin/setup     # installs gems, creates and migrates the databases, starts everything
```

`bin/dev` runs the web server, the Tailwind watcher and a Sidekiq worker together.

## Sharing a database

Every table this app owns lives in a Postgres schema called `pdfrag` rather than in
`public`, so the app can share one database with other applications. That covers its
own three tables, Active Storage's three, and Rails' `schema_migrations` and
`ar_internal_metadata` — the last two being the reason a schema was chosen over a
`pdfrag_` table prefix. Two Rails apps sharing one migration ledger each read the
other's versions as already-run, and `db:migrate` can conclude there is nothing to do.

The search path is set once, in `config/database.yml`:

```yaml
schema_search_path: pdfrag,public
```

**`public` is load-bearing.** The `vector` extension may live there — whoever creates
it first decides — and a search path without `public` leaves every embedding column
unable to resolve its type.

The schema is created automatically: `db:ensure_schema` is hooked onto `db:migrate`
and `db:prepare`, and `db/schema.rb` begins with `create_schema "pdfrag"` for the
load path. Nothing needs creating by hand.

That automation is not convenience. **A missing schema does not raise** — Postgres
skips an entry in `search_path` that does not exist and falls through to the next one,
so the app would quietly create its tables in `public`, beside whatever else is there.
Measured:

```
SET search_path TO pdfrag,public; CREATE TABLE documents (id int);
  => public.documents
```

Two things follow. **Deploying needs an explicit migrate step** — `bin/docker-entrypoint`
is a bare `exec`, so nothing prepares the database on boot. And **a connection pooler in
transaction mode would break this**, because `search_path` is per-connection state; a
pooler that reuses backends across transactions can lose it, which looks like missing
tables while quietly reading `public`.

## Running it

Visit <http://localhost:3000>, add a PDF, and wait while it is read. A 140-page document
takes a couple of minutes: about twelve seconds to extract, then embedding in batches.
The page updates itself as it goes.

`http://localhost:3000/sidekiq` shows the queue while developing. It is mounted in
development only — it exposes job arguments and has no authentication in front of it.

## Retention

Documents, their passages and their uploaded files are removed thirty minutes after upload.
Two things enforce that:

- **`expires_at`**, which every read scopes to, so an expired document is unreachable
  whether or not anything has deleted it yet
- **`DeleteDocumentJob`**, scheduled at upload, which frees the bytes

Because a queue can lose a job, run the sweep periodically from cron or a platform
scheduler:

```bash
bin/rails retention:sweep
```

It removes expired documents and purges orphaned files.

## Safety screening

Every upload is inspected structurally before it is stored. Scripts that run on open,
instructions to launch another program, and attached executables are refused, and the
file is never written anywhere.

Links and ordinary attachments are **not** blocked. They are shown to you instead, as
plain text rather than clickable links. Genuine documents are full of both — a real
insurance policy carries a provenance attachment and ten legitimate links to government
and insurer websites — so refusing them would reject exactly the documents this is for.

## Deploying to Render

`render.yaml` is a Blueprint: in the Render dashboard, **New → Blueprint**, point it at
this repository, and supply `RAILS_MASTER_KEY` when prompted. It creates a web service,
a Postgres instance and a Key Value instance, all on free plans.

**Puma and Sidekiq run in the same service**, started together by `bin/render-start`.
That is forced by the file store: Render cannot share a disk between services, and
uploads live on local disk for their hour, so a separate worker would run
`IngestDocumentJob` on a filesystem where the PDF does not exist. Moving Active Storage
to S3-compatible object storage is what would let the two split apart.

**Migrations run at boot**, in `bin/render-start`, rather than in a pre-deploy command —
those are paid-only. It is safe because a free service is single-instance and nothing
races it. On a paid plan with more than one instance, move `db:prepare` into
`preDeployCommand` and take it out of the script.

Two free-tier consequences are worth knowing before you rely on the URL:

- **The database expires 30 days after creation**, with 14 days' grace before deletion.
- **The service spins down after 15 minutes** of no traffic and takes about a minute to
  wake, which the processing screen will sit through.

Neither costs you data that was meant to survive: documents are gone after thirty minutes by
design, and an ephemeral filesystem that discards uploads on restart only enforces that
sooner. `Document.live` scopes every read to `expires_at`, so an expired document is
unreachable even though no cron job runs the sweep — cron is paid-only too, and the
commented-out block in `render.yaml` is there for when it is not.

## Limits

Two ceilings, both per visitor, both counted in the cache:

- **Five documents an hour.** Uploading is the expensive request — it embeds every
  chunk, and screens the whole file in the web process first.
- **Twenty questions a minute.** A question costs one embedding and one generation.

Generous for someone reading a document, tedious for a script. The app has no
accounts, so an address is the only thing to count against; `RateLimitKey` masks
IPv6 to its /64, because a subscriber is handed the whole block.

**The limiter fails closed.** Rails treats an unreachable counter store as "no
limit", which would switch rate limiting off exactly when the cache is unwell.
`FailClosedStore` refuses instead. The cost is real: a sick cache refuses
legitimate uploads, and on a free Key Value instance that will happen for reasons
unrelated to abuse.

Identifying the visitor needs Cloudflare's IP ranges, listed in
`config/application.rb`. Render fronts every service with Cloudflare, so without
them `request.remote_ip` is the edge and every visitor shares one bucket. The list
has an upstream owner — if it drifts, the failure is over-throttling rather than
anything exploitable.

Uploads are capped at 8 MB (`DocumentValidator::MAX_BYTES`), sized for a 512 MB
container that parses the whole PDF in the web process.

## Tests

```bash
bin/ci                  # everything: rubocop, audits, brakeman, tests
bin/rails test
bin/rails test:system   # needs Chrome; not part of bin/ci
```

No test reaches the network. Any unstubbed call to the language model raises, so a
forgotten stub fails loudly rather than quietly making a real, billed request with
someone's document in it.
