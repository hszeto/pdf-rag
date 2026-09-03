# PdfRag

Upload a PDF, get a short summary of what it is, and ask questions answered from the
parts of it that matter. Documents are kept for one hour and then removed.

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

## Running it

Visit <http://localhost:3000>, add a PDF, and wait while it is read. A 140-page document
takes a couple of minutes: about twelve seconds to extract, then embedding in batches.
The page updates itself as it goes.

`http://localhost:3000/sidekiq` shows the queue while developing. It is mounted in
development only — it exposes job arguments and has no authentication in front of it.

## Retention

Documents, their passages and their uploaded files are removed one hour after upload.
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

## A caution about the free tier

The Gemini free tier's daily request cap is exhausted by embedding roughly one large
document. That is enough to build and test with, and not enough to demo reliably.
Enabling billing on the same project raises it with no code change.

## Tests

```bash
bin/ci                  # everything: rubocop, audits, brakeman, tests
bin/rails test
bin/rails test:system   # needs Chrome; not part of bin/ci
```

No test reaches the network. Any unstubbed call to the language model raises, so a
forgotten stub fails loudly rather than quietly making a real, billed request with
someone's document in it.
