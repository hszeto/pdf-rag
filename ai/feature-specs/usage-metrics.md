# Feature Spec: usage-metrics

## Summary

A record of how much the app is being used — uploads, their sizes, and a sense of how
many distinct people — served as an opaque number on a health-style endpoint, in the
manner of `ai-rephrase.com/health` returning `{"status":"ok 70"}`.

The figures are public. That is accepted: a bare count carries no meaning to anyone
who does not already know what it counts, and it costs no authentication, no dashboard
and no new attack surface on an app that currently has none.

It runs against the grain of three existing decisions, which is what this spec has to
resolve rather than ignore:

- **Documents are deleted after thirty minutes**, and the page promises "your document
  and related data will be deleted". Anything kept has to be defensible against that
  sentence.
- **`byte_size` and `filename` live on the Active Storage blob**, which the retention
  sweep destroys. Sizes must be copied at upload time or they are gone.
- **`RateLimitKey` deliberately never writes an address to the database** — "not an
  identity in any meaningful sense … held only in the cache". Counting people by IP
  would reverse a decision that was made on purpose.

## Requirements

- R1 The number of documents uploaded is recorded, with enough time resolution to see a trend.
- R2 The byte size of each upload is recorded at upload time, before the blob is destroyed.
- R3 Some measure of distinct visitors is recorded.
- R4 The response is a bare run of numbers — no labels, no units, no key.
- R5 Metrics outlive the document they describe — the retention sweep must not remove them.
- R6 No stored row identifies a person, a filename, or anything about a document's contents.
- R7 The retention promise shown to readers stays true after this ships.

## Non-Goals

- A stats page, a dashboard, or any authentication.
- Retaining filenames, titles, document text, summaries or questions.
- Third-party analytics, or any request leaving the app.
- User accounts, sessions or login for ordinary visitors.

## Edge Cases

- Upload refused by screening (hostile, locked, damaged) → counted as a refusal, not an upload.
- Upload refused by the rate limiter → counted as a refusal.
- Document deleted or swept → its metric row remains; nothing links back to the document.
- One visitor uploads five files → one visitor, five uploads.
- Same visitor across midnight → two hashes, so two visitors. Accepted: D3 trades exactness for unlinkability.

## Acceptance Criteria

- AC1 The endpoint reports: uploads, distinct visitors, refusals, and average and maximum size.
- AC2 The response body names nothing: no field called "uploads", "visitors" or "bytes".
- AC3 A metric row survives `retention:sweep` and `DeleteDocumentJob`.
- AC4 No column holds an IP, filename, token or document text — asserted by a test.
- AC5 Every existing retention test passes unmodified.
- AC6 `bin/rails test`, `bin/rubocop` and Brakeman pass.

## Resolved Decisions

- **D1** A public endpoint returning an opaque number, not an authenticated dashboard.
  Obscurity, chosen knowingly: the cost of being wrong about a counter is nil, and the
  cost of a login on this app is real.
- **D2** It lives beside `/up` rather than replacing it — `/up` is Rails' health check and
  Render polls it.
- **D3** Visitors are counted by a **daily-rotating salted hash of the IP**: countable,
  not reversible, and not linkable across days. The address itself is never stored.
- **D4** The endpoint exposes **average and maximum** size, never a per-file list. A list
  would let someone upload a file and watch their own byte size appear, which is the one
  part of this that would not be meaningless to a stranger.
- **D5** Refusals are counted **separately** from accepted uploads — hostile, locked and
  rate-limited attempts never become documents, and folding them together would hide
  both numbers.
- **D6** The retention copy is **unchanged**. What survives is a size, a timestamp and an
  unlinkable daily hash — nothing that identifies the reader or their document, so
  "your document and related data will be deleted" stays true (R7).

### Stored versus exposed

D4 constrains the **response**, not the table. Rows may carry a per-upload byte size —
that is how an average and a maximum get computed at all. The rule is that the endpoint
publishes aggregates and the row stays private.

### On the table growing forever

Every other record here expires; these do not, by design. At this app's rate limit —
five uploads per visitor per hour — a row per upload is a few thousand rows a year, so
no ceiling is needed yet. Worth revisiting only if the app ever gets busy enough that
the count itself is interesting.
