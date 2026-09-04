# Plan: harden-public-access

Spec: `ai/feature-specs/harden-public-access.md` (D1–D11 resolved, no open
questions).

## Confirmed Decisions

- **D1** `has_secure_token`, not a UUID — the integer primary key stays.
- **D2** Only the two request paths change; jobs keep the integer id.
- **D3** No redirect from old integer URLs.
- **D4** Existing rows backfilled in the migration.
- **D5** Tokens in request logs are accepted, not suppressed.
- **D6** An unknown token keeps the "That document has been removed" message.
- **D7** Uploads 5/hour, questions 20/minute, per visitor.
- **D8** Visitor identified via `config.action_dispatch.trusted_proxies`.
- **D9** Fail closed, with a message, when the counter store is unavailable.
- **D10** `MAX_BYTES` 15 MB → 8 MB.
- **D11** Stale free-tier documentation corrected here.

## Approach

### The error object carries its own status

`ApplicationController#render_processing_error` renders 422 unconditionally, and
`MessagesController` has a second rescue rendering `documents/show`. A rate-limit
refusal has to be **429** (AC8) through both.

Rather than special-casing in two handlers, `ProcessingError` gains a `status`
alongside its existing `user_message` — defaulting to `:unprocessable_entity`,
overridden to `:too_many_requests` by the new subclasses. Both handlers then read
`error.status`. This is the pattern the class already uses: the comment on it says
"every failure the pipeline can raise already carries the words the user should
see", and the status is the same kind of fact.

Two new errors: one for hitting a limit, one for the counter store being
unavailable (D9), so R4.4's "logged distinguishably" falls out of the type.

Because `MessagesController` rescues locally and re-renders `documents/show`, the
Turbo Stream case (AC8) needs the same `formats: [:html]` treatment already used
there for failures.

### Failing closed without abandoning Rails' limiter

`rate_limiting` treats a `nil` from `store.increment` as "no limit" — that is the
fail-open behaviour D9 rejects. Verified: `increment` returns `1` on a *missing*
key, so `nil` unambiguously means the store failed, never "first request".

So the store is wrapped rather than the limiter replaced:

```ruby
# raises instead of returning nil, so a broken cache refuses rather than admits
rate_limit(..., store: FailClosedStore.new(Rails.cache))
```

That keeps `rate_limit`'s key construction, instrumentation and `within` handling,
and changes only the one behaviour we disagree with.

### Identifying the visitor

`config.action_dispatch.trusted_proxies` gets Cloudflare's published ranges plus
the defaults, so `request.remote_ip` resolves past Render's edge. Fetched at
implementation time from `cloudflare.com/ips-v4` and `/ips-v6` — 15 IPv4 CIDRs
today — and committed with the date and source in a comment, since the list has an
upstream owner and can drift (see Risks).

This fixes every request log as well as the limiter, which is why it was chosen
over reading `CF-Connecting-IP`.

For R3.4, the limiter's `by:` masks IPv6 to its /64 prefix. A subscriber is
typically given a whole /64, so limiting per exact address would let one person
rotate freely.

### The token

`has_secure_token` (verified: 24 characters, base58, e.g. `ZdWugCmezLoDRcWTe1vKbVCG`)
plus `to_param`. Verified no test hardcodes a document id in a path, so every
existing `document_path(document)` call site moves to tokens untouched.

The migration adds the column nullable, backfills, then adds the unique index and
`null: false` — so an existing row is never briefly unreachable.

### The size limit and its copy

`ProcessingError::TooLarge` hardcodes "smaller than 15 MB". D10 changes the
constant, so the copy derives from `DocumentValidator::MAX_BYTES` instead — the
same treatment `Document::RETENTION` already gets in the retention note, and for
the same reason.

## Files Touched

- `db/migrate/*_add_token_to_documents.rb` — **new**; column, backfill, unique index.
- `app/models/document.rb` — `has_secure_token`, `to_param`.
- `app/controllers/documents_controller.rb` — look up by token; rate limit.
- `app/controllers/messages_controller.rb` — look up by token; rate limit; status.
- `app/controllers/application_controller.rb` — render with `error.status`.
- `app/services/processing_error.rb` — `status`; two new errors; `TooLarge` copy.
- `app/services/document_validator.rb` — `MAX_BYTES` to 8 MB.
- `app/services/fail_closed_store.rb` — **new**; raises instead of returning nil.
- `app/services/rate_limit_key.rb` — **new**; IPv6 /64 masking.
- `config/environments/production.rb` — `trusted_proxies`.
- `test/` — model, both controllers, limiter, key masking, store wrapper.
- `README.md`, `CLAUDE.md`, `embedding_batches.rb`, `embed_chunk_batch_job.rb` — D11.
- `CHANGELOG.md`.

## Checkpoints

1. **Unguessable URLs.** Migration, `has_secure_token`, `to_param`, both lookups.
   Jobs untouched. Verify AC1–AC7 — including that every job and retention test
   passes *unmodified*, which is the evidence D2 held.
   *Commit: "Route documents by an unguessable token"*

2. **See the real visitor.** `trusted_proxies` with Cloudflare's ranges, and
   `RateLimitKey` for IPv6 masking. No limiting yet — this checkpoint is only
   about `request.remote_ip` becoming correct, which is independently verifiable
   and independently useful.
   *Commit: "Resolve the client IP past Render's edge"*

3. **Rate limiting.** `FailClosedStore`, the two new errors, `status` on
   `ProcessingError`, both handlers, both `rate_limit` calls.
   *Commit: "Limit what one visitor can spend"*

4. **Fit the resources, and correct the record.** `MAX_BYTES` to 8 MB with derived
   copy, the four stale free-tier passages, CHANGELOG.
   *Commit: "Size the upload limit for the box it runs on"*

## Test Plan

Tooling: `bin/rails test`, `bin/rails test:system` (Chrome, **not** in `bin/ci`),
`bin/rubocop`, `bin/brakeman`. No mocking library; `stub_gemini` for any path that
would reach the model.

**Verified: the test environment's cache is `MemoryStore`, per parallel worker.**
Rate-limit tests therefore need no Redis and are safe in CI — but each test must
use a distinct client IP or clear the store, because counters otherwise leak
between tests in the same worker.

**Token (checkpoint 1)**
- `to_param` returns the token; `document_path` contains it and not the id.
- Fetching by primary key responds exactly as an unknown document does.
- Fetching by token returns the document; the nested message route works.
- A row created without a token (simulating pre-migration) is reachable after
  backfill.
- The unique index exists and a duplicate token is refused by the database.
- **Every job test and every retention test passes unmodified** — the evidence
  that nothing crossing the queue changed.

**Client IP (checkpoint 2)**
- With `X-Forwarded-For: <client>, <cloudflare>, <render>`, `remote_ip` is the
  client — using a real Cloudflare address from the committed list.
- A client-supplied `X-Forwarded-For` prepended by a spoofer does not win (AC10).
- IPv6 addresses in the same /64 produce one key; different /64s produce two.

**Rate limiting (checkpoint 3)**
- The 6th upload in an hour is refused with 429 and a reader-facing message.
- The 21st question in a minute is refused, in HTML and as a Turbo Stream.
- Two different client IPs behind the same proxy are counted separately (AC9).
- Reading a document is never limited, however many times (AC11).
- With a store that returns `nil`, the request is refused rather than admitted,
  and the error type differs from a genuine limit hit (AC12, R4.4).

**Size and docs (checkpoint 4)**
- An 8 MB+ file is refused and the message names the current limit, derived from
  the constant rather than repeating it.

**Gaps stated plainly**
- Cloudflare's list is a point-in-time copy; no test can detect upstream drift.
- Fail-closed is tested with an injected failing store, not a genuinely
  unreachable Redis.
- `bin/ci` does not run system tests.

**Manual verification (Phase 6)**
Upload a document and confirm the URL carries a token; try the neighbouring
integer and confirm it is not found; upload six times and confirm the sixth is
refused; check Render's logs show the real client IP rather than a Cloudflare one.

## Risks / Rollback

- **D9 trades availability for a spending ceiling.** A free Key Value instance
  that is merely unwell will refuse uploads. This is the decision most likely to
  be regretted; reverting it is a one-line change to use `Rails.cache` directly.
- **Cloudflare's ranges drift.** If they add a range we do not have,
  `remote_ip` silently reverts to the edge address and every visitor shares a
  bucket again. It degrades to over-throttling rather than to spoofable, and the
  committed comment should say when the list was taken.
- **`to_param` changes URLs everywhere at once.** Any test hardcoding an id
  breaks — verified none do, but a missed call site would 404 rather than misbehave.
- **The backfill runs on production data.** It is additive and reversible; the
  column can be dropped without touching anything else.
- **8 MB refuses documents that work today** when the box is idle. Deliberate.
- **Rollback** is per checkpoint. Checkpoint 1 needs a migration rollback; 2–4 are
  code-only.
