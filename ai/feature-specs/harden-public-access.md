# Feature Spec: harden-public-access

## Summary

Two changes that must land before the URL is shared: stop documents being
findable by counting, and cap what one visitor can spend. Both touch the same two
controller lookups, so they share a branch — but they are separate concerns and
land as separate commits.

**Order: unguessable URLs first, rate limiting second.** The leak is exploitable
now; rate limiting only caps spend. Doing the URL change first also means the
limiter is written once against the final routes.

## Context from the codebase (Phase 0 findings)

### Finding 1 — documents are findable by counting

`DocumentsController#load_document` is the whole of the access control:

```ruby
@document = Document.live.find_by(id: params[:id])
```

No ownership check exists anywhere — no `session[`, no `cookies[`, no
`current_user`. `MessagesController#create` looks up the same way. Ids are
sequential; the five most recent are 37, 38, 39, 40, 41.

Anyone can walk the range and read every live document — summary, scan notes and
the whole question-and-answer history — for the thirty minutes it exists.

Two things limit the blast radius: `Document.live` scopes reads to `expires_at`,
and the app never serves the uploaded PDF itself (no blob link appears in any
view). The leak is the extracted content, not the file.

### Finding 2 — the primary key should not become a UUID

Six job call sites pass `document.id` across the Sidekiq queue
(`ingest_document_job:13`, `embed_chunk_batch_job:27,33`,
`summarize_document_job:10,19`, `delete_document_job:11`), both child tables carry
`bigint document_id`, and Active Storage references documents polymorphically.
Changing the primary key would touch all of it to solve a problem that exists
only in *public* URLs.

UUIDv7 was considered and rejected: its first 48 bits are a millisecond timestamp
in the clear, so documents created seconds apart share a prefix and every URL
announces its own creation — and therefore expiry — time. It is an index-locality
format, not a secrecy one.

### Finding 3 — `request.remote_ip` is the wrong identity here

Render fronts every service with Cloudflare, and production logs show Rails
treating the edge as the client:

```
Started GET "/" for 172.68.174.106     ← Rails thinks this is the visitor
"remote_addr":"184.23.124.45, 172.68.174.106, 10.28.65.0"   ← the real chain
```

`172.68.174.106` is Cloudflare (172.64.0.0/13); `184.23.124.45` is the visitor.
Rails walks `X-Forwarded-For` right-to-left discarding trusted proxies, and its
default list covers private ranges but not Cloudflare's.

**Consequence:** limiting by `remote_ip` today would put every visitor behind one
edge in a single bucket. One abuser would lock out everybody arriving through
that data centre — the limiter becomes the attack. No trusted-proxy configuration
exists anywhere in `config/`.

### Finding 4 — Rails' limiter fails open, silently

`rate_limiting` does `count = store.increment(...)` then `if count && count > to`.
The production cache is Redis with an `error_handler` that logs and swallows
(`production.rb:52`), so a failed increment returns `nil` and the check is
skipped. The free Key Value tier compounds it: `allkeys-lru` (warned about in the
deploy logs) can evict a counter mid-window.

### Finding 5 — the resource picture has inverted

Gemini Tier 1 gives embedding 3K RPM / 1M TPM / **unlimited** daily requests. At
measured prices — `gemini-embedding-001` $0.15/1M, `gemini-2.5-flash` $0.30/$2.50
— ingesting a 138-page document costs about **1.4¢** and a question about **0.1¢**.

The model is no longer scarce; the free Render instance is. 0.1 CPU and 512 MB
shared by Puma and Sidekiq, with `MAX_BYTES` still at 15 MB and screening parsing
the whole PDF inside the web request.

Four places still describe the old free-tier constraint as current:
`README.md:153-155`, `CLAUDE.md:130`, `embedding_batches.rb:4-8`,
`embed_chunk_batch_job.rb:14-15`.

`ActionController#rate_limit` is available on Rails 8.1.3.1, so no gem is needed.

## Resolved Decisions

### Unguessable URLs

- **D1 — `has_secure_token`, not a UUID.** 24-character base58, ~140 bits. The
  integer primary key stays, so jobs, both foreign keys and Active Storage are
  untouched.
- **D2 — Only the two request paths change.** Jobs keep passing the integer id;
  the token is a public identifier, not an internal one.
- **D3 — Old integer URLs are not redirected.** Documents live thirty minutes, and
  a redirect would keep the enumerable path working.
- **D4 — Existing rows are backfilled** in the migration.
- **D5 — Tokens in request logs are accepted, not suppressed.** A token in the
  path is a working key for its remaining minutes, but only to someone with Render
  dashboard access — who can open the app anyway. Suppressing the path costs
  debuggability against a threat already inside the account.
- **D6 — An unknown token keeps the current "That document has been removed"
  message.** One less signal to someone probing, and `RetentionTest` stays
  untouched.

### Rate limiting and resources

- **D7 — Uploads: 5 per hour. Questions: 20 per minute.** Per visitor. Generous
  for a reader, tedious for a script. Chosen to protect 512 MB and 0.1 CPU rather
  than the bill.
- **D8 — Identify the visitor via `config.action_dispatch.trusted_proxies`,** not
  a vendor header. Cloudflare is Render's edge, not an account we control, so the
  fix belongs in Rails. It corrects every request log as well as the limiter.
  Cost: Cloudflare's ranges are a published list with an upstream owner.
- **D9 — Fail closed, with a message.** If the counter store is unavailable the
  request is refused and the reader told, rather than silently granted an
  unbounded allowance. On a free Key Value instance this will sometimes refuse for
  reasons unrelated to abuse; accepted deliberately.
- **D10 — `MAX_BYTES` drops from 15 MB to 8 MB.** Screening parses the whole file
  in the web request on a box shared with Sidekiq.
- **D11 — The stale free-tier documentation is corrected here.**

## Requirements

### R1 — Documents are not findable by counting

- R1.1 A document's URL contains an unguessable token, not its primary key.
- R1.2 The token is generated on create and is unique.
- R1.3 Existing documents get a token when the migration runs.
- R1.4 `document_path(document)` uses the token without each call site changing.
- R1.5 Nested message routes use the token too.
- R1.6 A request for a document by its primary key no longer finds it.
- R1.7 Jobs continue to pass and look up the integer id.
- R1.8 An unknown or expired token behaves as an unknown id does today (D6).
- R1.9 Retention is unaffected — `Document.live`, `remove!` and the sweep behave
  as they do now.

### R2 — Limit the requests that cost money

- R2.1 `DocumentsController#create` is rate-limited (D7).
- R2.2 `MessagesController#create` is rate-limited more loosely (D7).
- R2.3 Reading a document is never limited — the processing screen polls it every
  few seconds, and reading costs nothing.

### R3 — Identify the visitor, not the proxy

- R3.1 The limiter buckets by the actual client, not the Cloudflare edge.
- R3.2 The mechanism cannot be spoofed by a header a visitor sets themselves.
- R3.3 If the client cannot be determined, the request is still counted against
  something rather than escaping the limit.
- R3.4 IPv6 clients are bucketed by prefix rather than by exact address, since a
  single subscriber is typically given a whole /64.

### R4 — Refuse honestly

- R4.1 A refused request gets a reader-facing message in the app's voice, not a
  bare 429.
- R4.2 The response uses 429 so automated clients see it correctly.
- R4.3 A refusal renders correctly for a Turbo Stream request as well as HTML.
- R4.4 A refusal caused by the store being unavailable is logged distinguishably
  from a genuine limit hit (D9).

### R5 — Fit the resources actually available

- R5.1 `MAX_BYTES` becomes 8 MB (D10).
- R5.2 Limits are chosen against Tier 1's headroom, not the free tier's.

### R6 — Documentation matches reality

- R6.1 The four places describing the Gemini free tier as current are corrected.
- R6.2 The rate limits and their reasoning are written where an operator will
  find them.

## Non-Goals

- Accounts, sessions, or any reader identity. The app deliberately has none.
- CAPTCHA or bot detection.
- `Rack::Attack` or any gem — Rails ships `rate_limit`.
- Changing the primary key, the foreign keys, or Active Storage.
- Signing or encrypting the token — unguessable is the goal, not verifiable.
- Changing models. Both are already the cheapest options available.
- Render plan changes, object storage, splitting the worker.
- Rate-limiting Sidekiq jobs. Only request paths are in scope.
- Billing alerts in Google Cloud — necessary, but not something this repo can do.

## Edge Cases

**Unguessable URLs**

- A document created before the migration must still be reachable after it.
- Token collision on insert — vanishingly unlikely, but the column should be
  uniquely indexed so the database refuses rather than serving the wrong document.
- Every existing test building a path from a document object silently starts using
  tokens; any hardcoding an integer breaks, and should.
- The `?asked=` parameter carries a message id, usable only within a document the
  reader can already open. Not a second leak, but it should not become one.
- Turbo Stream targets use `dom_id(message)` and must not change.

**Rate limiting**

- Shared IPs — an office, school or carrier NAT puts many real people behind one
  address, and they will throttle each other.
- A queued job still spends after the limit hits: the cap bounds arrivals, not
  work already accepted.
- `EmbedChunkBatchJob` retries up to 5 times, so one upload can produce several
  times its expected API calls.
- Counter eviction under `allkeys-lru` can grant a fresh allowance mid-window.
- The test environment uses `:memory_store` per parallel worker, so tests must set
  up and tear down their own counter state.
- A limit hit during the processing screen's polling must not break the wait.

## Acceptance Criteria

- AC1 `document_path(document)` contains the token, not the primary key.
- AC2 Fetching a document by its primary key responds as an unknown document does.
- AC3 Fetching by token returns the document, and asking a question via the nested
  token route works.
- AC4 A document created before the migration is reachable by token afterwards.
- AC5 The token column is uniquely indexed.
- AC6 Every job test passes unmodified — nothing crossing the queue changed.
- AC7 Retention tests pass unmodified.
- AC8 Exceeding either limit returns 429 with a reader-facing message, rendering
  correctly for both HTML and Turbo Stream.
- AC9 Two requests from different visitors behind the same proxy count separately.
- AC10 A spoofed client-identity header does not evade the limit.
- AC11 Reading a document, and the processing screen's polling, are never limited.
- AC12 With the counter store unavailable, requests are refused with a message,
  and that case is covered by a test.
- AC13 No reader-facing string mentions Gemini, quotas or rate limits as our
  problem — consistent with how `QuotaExhausted` is worded.
- AC14 `bin/rails test`, `bin/rails test:system`, `bin/rubocop` and Brakeman pass.

## Open Questions

None outstanding. All were answered and promoted to Resolved Decisions above.

Note for the reviewer: D9 is the only decision that trades availability for
safety. Failing closed means the app refuses uploads whenever the cache is merely
unwell, which on a free Key Value instance will happen for reasons unrelated to
abuse.
