# Plan: usage-metrics

Spec: `ai/feature-specs/usage-metrics.md` — D1–D6 resolved, no open questions.

## Confirmed Decisions

- **D1** Public endpoint, opaque numbers, no auth — the cost of being wrong about a counter is nil.
- **D3** Visitors counted by a daily-rotating salted hash of the IP.
- **D4** Average and maximum size in the response; per-upload sizes stay in the table.
- **D5** Refusals counted separately from accepted uploads.
- **D6** Retention copy unchanged.

## Approach

- One table, `usage_events`: `kind` ("upload" / "refusal"), `byte_size` (null for refusals),
  `visitor_hash`, `created_at`. No foreign key to `documents` — the row must outlive it (R5).
- **Record in `DocumentsController#create`, not in `ApplicationController`'s `rescue_from`.**
  That handler happens to see only upload refusals today because `MessagesController`
  rescues locally, but a future change there would silently start counting questions as
  refused uploads.
- `rescue ProcessingError => e; record; raise` inside `create` — the rescue body runs
  *before* the `ensure` that closes the tempfile, so the size is still readable there.
- `VisitorHash.for(ip)` = HMAC-SHA256 of `RateLimitKey.for(ip)`, keyed by
  `secret_key_base` plus the current date. Reuses the existing IPv6 /64 masking, so one
  subscriber is one visitor; no new secret to manage, and the key changes at midnight.
- The endpoint is `/health`, beside Rails' `/up`, returning
  `{"status":"ok <uploads> <visitors> <refusals> <avg_mb> <max_mb>"}` — one string, no keys.
- Recording never breaks an upload: the insert is wrapped and a failure is logged, not raised.

## Files Touched

- `db/migrate/*_create_usage_events.rb` — **new**; table plus indexes on `created_at` and `visitor_hash`.
- `app/models/usage_event.rb` — **new**; `record_upload`, `record_refusal`, and the aggregates.
- `app/services/visitor_hash.rb` — **new**; the daily HMAC.
- `app/controllers/documents_controller.rb` — record on both the success and refusal paths.
- `app/controllers/health_controller.rb` — **new**; the endpoint.
- `config/routes.rb` — `get "health"`.
- `test/` — model, hash, controller recording, retention survival, endpoint.
- `CHANGELOG.md`.

## Checkpoints

1. **Record what happens.** Migration, `UsageEvent`, `VisitorHash`, and both call sites in
   `DocumentsController`. Nothing is exposed yet.
   → verify: an accepted upload writes one `upload` row carrying the byte size; a refused
   one writes a `refusal` row and no upload row; `retention:sweep` and `DeleteDocumentJob`
   leave both intact; no column holds an IP, filename, token or text.
   *Commit: "Record uploads and refusals without recording who"*

2. **Expose the numbers.** `HealthController`, the route, the response format.
   → verify: the body is a bare run of numbers with no labels; the figures match the rows;
   `bin/rails test`, `bin/rubocop`, `bin/brakeman` green.
   *Commit: "Report usage as a number only I can read"*

Say the word and these collapse into one — the split exists only because checkpoint 1
carries a migration, so its rollback differs from checkpoint 2's.

## Test Plan

- `VisitorHash`: same IP same day → same value; different day → different; different IP →
  different; two IPv6 addresses in one /64 → one value; the output never contains the address.
- **Recording:** a successful upload writes exactly one row, `kind: "upload"`, with the
  real byte size. A hostile PDF writes `kind: "refusal"` and no upload row. A rate-limited
  request writes a refusal.
- **Survival (AC3):** create a document, record, then run `DeleteDocumentJob` and
  `retention:sweep` — both rows still present, and `Document.count` is zero.
- **AC4 asserted structurally:** `UsageEvent.column_names` contains no `ip`, `filename`,
  `title`, `token` or `text` column. A column added later fails this test.
- **Endpoint (AC2):** the body matches `/\A\{"status":"ok( \d+(\.\d+)?)+"\}\z/` — no field
  is named, which is the criterion rather than an eyeballed string.
- Every existing retention test passes unmodified (AC5).
- Tooling: `bin/rails test`, `bin/rubocop`, `bin/brakeman`. No Gemini, no system tests.

## Risks / Rollback

- **An insert on the upload path could break uploading** → wrapped and logged, never
  raised; a test drives a failing insert and asserts the upload still succeeds.
- **A public endpoint running aggregates invites scraping** → cached for 60s in
  `Rails.cache`; the queries are counts over a small table either way.
- **These rows never expire**, unlike everything else here → accepted in the spec; a few
  thousand rows a year at the current rate limit.
- **Midnight splits a visitor in two** → inherent to D3's unlinkability, recorded as an
  accepted edge case.
- **Rollback:** checkpoint 2 is code-only. Checkpoint 1 needs a migration rollback, and
  the table drops cleanly since nothing references it.
