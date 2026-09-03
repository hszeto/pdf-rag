# Plan: insurance-helper-mvp

Spec: `ai/feature-specs/insurance-helper-mvp.md` (D1–D11 resolved, no open questions).

## Confirmed Decisions

Carried from the spec's Resolved Decisions; restated here as the constraints this plan
builds to.

| # | Decision |
|---|---|
| D1 | Redis cache store (dev/prod, DB 0), `Rails.cache` interface. **Already wired and verified.** |
| D2 | Test env uses `:memory_store`. **Already wired.** |
| D3 | Scanned PDFs deferred — friendly dead end below ~200 chars, no Gemini call |
| D4 | TTL 300s; banner at 3:00, wipe at 5:00 |
| D5 | Keep `allow_browser :modern`; rewrite the existing `public/406-unsupported-browser.html` |
| D6 | Synchronous Gemini call; Sidekiq is next phase — keep the call in a service object |
| D7 | `gemini-2.5-flash`, Developer API, key in credentials as `gemini_api_key`. **Verified live.** `thinkingBudget: 0` + `responseSchema` both confirmed working |
| D8 | Free tier → **synthetic/sample documents only**, no real member data |
| D9 | 15MB upload limit |
| D10 | Rails' built-in signed session; no `POST /sessions` |
| D11 | Grounding affordances visible on plan + chat screens |

Two decisions are already implemented (D1, D2) from the earlier Redis setup, so
Checkpoint 1 starts from working cache infrastructure.

---

## Approach

### Shape
Server-rendered ERB with Turbo and Stimulus — not an SPA. The repo is Propshaft +
importmap + Turbo + Stimulus + Tailwind v4, and no build step exists for a JS app. The
spec's suggested `javascript/<screen>` structure is replaced by ERB views plus three
small Stimulus controllers.

**One URL, state-driven.** `root` renders landing / processing / plan+chat / error based
on the session's `status`. This makes expiry trivial (no session → landing) and avoids
`GET /sessions/:id/plan_info` needing an id in the path, which D10 makes redundant since
the signed cookie already carries it.

```
root            "sessions#show"     landing | plan+chat | error, per status
POST   /document                    upload → validate → extract → analyze
POST   /messages                    a Q&A turn
POST   /heartbeat                   refresh TTL
DELETE /session                     explicit wipe
```

### Cache representation
`SessionCache` stores a **plain Hash**, not a marshalled custom object. A marshalled
class breaks on code reload in development and across a deploy while old entries are
still live — a real hazard when the cache is the only datastore. Reads wrap the hash in
an `InsuranceSession` ActiveModel value object (per CLAUDE.md's guidance to use Active
Model, since there's no Active Record).

```ruby
SessionCache.find(id)   # → InsuranceSession | nil
SessionCache.create     # → InsuranceSession
SessionCache.write(session)   # re-writes with a fresh 300s TTL
SessionCache.touch(id)  # refresh TTL only
SessionCache.destroy(id)
```

Every write resets the TTL, so R1.3's "refresh on interaction" falls out of normal use
rather than needing a separate code path.

### Gemini client, and why it takes an injected transport
`GeminiClient` accepts its HTTP transport as a constructor argument defaulting to a thin
`Net::HTTP` wrapper. This is forced by tooling, not preference: **Minitest 6 removed
`Minitest::Mock`**, and the project has no webmock/vcr/mocha. Injection is the only way
to test the client without adding a gem or making live API calls in CI. It also satisfies
D6 — a service object a Sidekiq job can wrap later without restructuring.

Two calls, both with `thinkingConfig: { thinkingBudget: 0 }` and a `responseSchema`
(both verified working against the live API):

- `#analyze_document(text:)` → one call returning `is_insurance_document`,
  `document_type`, `structured_fields`, `plain_summary`
- `#answer(question:, context:, history:)` → returns the reply plus `found_in_summary`,
  which drives R6.4's single full-text retry

**`maxOutputTokens` must leave headroom for thinking even at budget 0** — the verified
gotcha is that thinking tokens count against that ceiling, and too low a value returns an
empty candidate that looks like a bug rather than a config error.

### Error handling
A single `ProcessingError` hierarchy with a `user_message` maps every failure to spec
copy: `NotAPdf`, `TooLarge`, `Locked`, `Damaged`, `Unreadable` (D3's scanned case),
`NotInsurance`, `ServiceUnavailable`. Controllers rescue one type and render one error
partial with a retry control, satisfying R7.5's "never a dead end" in one place.

---

## Files Touched

**Config**
- `config/routes.rb` — the five routes above
- `config/initializers/filter_parameter_logging.rb` — add document/question params (R9.3)
- `config/environments/{development,test,production}.rb` — **already done** (D1/D2)

**Services** (`app/services/`, new dir — autoloaded, all of `app/` is)
- `session_cache.rb` — cache read/write/touch/destroy, 300s TTL
- `insurance_session.rb` — ActiveModel value object over the cached hash
- `document_validator.rb` — size, `%PDF-` magic bytes, extension
- `pdf_extraction_service.rb` — pdf-reader, error mapping, near-empty detection
- `gemini_client.rb` — both calls, injected transport, schemas
- `gemini_client/net_http_transport.rb` — default transport
- `processing_error.rb` — error hierarchy with user-facing copy

**Controllers**
- `app/controllers/application_controller.rb` — `SessionScoped` include, error rescue
- `app/controllers/concerns/session_scoped.rb` — load-or-nil session, touch TTL
- `app/controllers/sessions_controller.rb` — `show`, `heartbeat`, `destroy`
- `app/controllers/documents_controller.rb` — `create`, rate-limited
- `app/controllers/messages_controller.rb` — `create`

**Views** (`app/views/`)
- `layouts/application.html.erb` — replace `container mx-auto mt-28 flex` with the
  large-type, high-contrast shell
- `sessions/show.html.erb` + partials: `_landing`, `_processing`, `_plan`, `_chat`,
  `_error`, `_idle_banner`, `_grounding_note`
- `messages/create.turbo_stream.erb` — append the turn

**JS** (`app/javascript/controllers/`)
- `idle_controller.js` — 3:00 banner / 5:00 wipe / heartbeat throttled to 10s
- `upload_controller.js` — processing screen, 20s "taking longer" message, double-submit guard
- `chat_controller.js` — example-question buttons, scroll on new turn
- delete `hello_controller.js` (generator leftover)

**Assets**
- `app/assets/tailwind/application.css` — `@theme` tokens for type scale and contrast
  (Tailwind v4 is CSS-first; there is no `tailwind.config.js` to edit)

**Static**
- `public/406-unsupported-browser.html` — rewrite copy for this audience (D5)

**Tests** — `test/services/`, `test/controllers/`, `test/integration/`,
`test/fixtures/files/` (all but the last are new dirs)

**Docs**
- `README.md` — Redis prerequisite, credentials setup, D8 synthetic-documents warning
- `CHANGELOG.md` — **does not exist yet**; create it (ASDD Phase 5 requires an entry)

---

## Checkpoints

Each is commit-sized and independently verifiable. One at a time — verify, report, wait
for the user to commit before starting the next.

1. **Session plumbing.** `SessionCache`, `InsuranceSession`, `SessionScoped`, routes,
   `sessions#show` rendering a bare landing view, heartbeat + destroy. Cache config is
   already in place, so this checkpoint is pure app code.
   *Verifies:* AC 1–6.

2. **Upload validation + PDF extraction.** `DocumentValidator`, `PdfExtractionService`,
   `ProcessingError`, `documents#create` storing `full_text` and status `uploaded`.
   No Gemini yet. Test fixtures generated here.
   *Verifies:* AC 7–10.

3. **Gemini analysis call.** `GeminiClient` + transport, `analyze_document`, wired into
   `documents#create`; `is_insurance_document: false` discards the upload.
   *Verifies:* AC 11, 13.

4. **Plan info screen.** Layout overhaul, plan card, `null` → "Not found in your
   document", grounding attribution (R7.6/D11).
   *Verifies:* AC 12, 14.

5. **Chat loop.** `messages#create`, `answer`, the single full-text fallback, chat UI
   with example questions.
   *Verifies:* AC 15–18.

5b. **Extraction page cap (D12).** `PdfExtractionService` reads at most 20 pages. Added
    after a real 140-page policy measured 15.8s of extraction and ~106k tokens.
    *Verifies:* extraction time and payload size stay bounded regardless of document
    length; the nine fields still extract.

5c. **Background analysis with Sidekiq (D6 revised).** Sidekiq gem and config, an
    `AnalyzeDocumentJob` taking only the session id, `analyzing` status, and R7.2's
    processing screen with polling, rotating messages and the 20-second "taking a
    little longer" message. Extraction stays on the request; only the Gemini call moves.
    *Verifies:* R7.2, and that a slow analysis no longer blocks a Puma thread.

6. **Idle UX.** `idle_controller.js`, banner at 3:00, wipe at 5:00, throttled heartbeat.
   *Verifies:* AC 19–21.

7. **Errors + hardening.** All error screens with retry, `rate_limit` with a friendly
   response (Rails 8.1 raises `TooManyRequests` by default — must be handled), log
   filtering, R3.6 cache-write failure, 406 page rewrite.
   *Verifies:* AC 22–24.

8. **Accessibility, copy, docs.** Font-size and contrast audit, plain-language pass,
   README, CHANGELOG.
   *Verifies:* AC 25 and the copy requirements in R7.

---

## Test Plan

### Tooling that actually exists
`bin/rails test` (Minitest, parallel workers), `bin/rubocop`, `bin/brakeman
--exit-on-warn`, `bin/bundler-audit`, `bin/importmap audit`, all sequenced by `bin/ci`
via `config/ci.rb`. Capybara + Selenium are installed but system tests are **commented
out of `bin/ci`** and only run in `.github/workflows/ci.yml`.

### Tooling that does NOT exist — and the consequence
- **No mocking or stubbing library at all.** No webmock, vcr, or mocha, and **Minitest
  6.0.6 has dropped `Minitest::Mock`** (verified: `require "minitest/mock"` raises
  `LoadError`; there is no `mock.rb` in the gem). `Object#stub` is therefore also gone.
  → Every seam that needs faking must be **injected**, not stubbed. This is why
  `GeminiClient` takes a transport argument. If the user would rather add `webmock`,
  that changes this design; otherwise injection is load-bearing, not stylistic.
- **No PDF *writing* library.** Fixtures are generated with macOS `cupsfilter`
  (verified: produces a valid `%PDF-1.3` that `pdf-reader` extracts 57 chars of text
  from). Generation is a one-time step; the resulting files get committed.
- **No way to generate an encrypted PDF locally** — no `qpdf`, `gs`, or `pdftk`. A
  hand-crafted `/Encrypt` trailer fails as `MalformedPDFError` before reaching the
  encryption check, so it does not exercise the real path.
  → The `EncryptedPDFError` → "locked" mapping is unit-tested with an injected raising
  double. **Confirming that a genuinely password-protected PDF hits that branch requires
  either `brew install qpdf` to build a real fixture, or manual verification.** Flagging
  rather than silently claiming coverage.

### Tests to add
**`test/services/`**
- `session_cache_test.rb` — write/read round-trip; TTL is 300s; every write refreshes it;
  expiry via `travel_to`; `find` on an unknown id returns nil; destroy is immediate.
- `document_validator_test.rb` — valid PDF; JPEG renamed `.pdf` rejected on magic bytes;
  zero-byte file; 15MB boundary either side.
- `pdf_extraction_service_test.rb` — text extraction; near-empty → `Unreadable` (D3);
  `EncryptedPDFError` → `Locked` and `MalformedPDFError` → `Damaged`, both via injected
  raising doubles (see caveat above).
- `gemini_client_test.rb` — payload assertions against a fake transport: request carries
  `thinkingBudget: 0` and a `responseSchema`; the key travels as the `x-goog-api-key`
  **header, never in the URL**; `analyze_document` parses a canned success; malformed
  JSON → `ServiceUnavailable`, not a raw exception; HTTP 429/5xx/timeout each map to
  `ServiceUnavailable`.
  **The cost-control assertion (AC 15) lives here:** `answer` must not include
  `full_text` on the normal path, and the fallback must fire at most once.

**`test/controllers/` and `test/integration/`**
- Full happy path: upload → plan screen shows all nine fields → ask a question → answer
  appended to history.
- Non-insurance PDF → error screen, upload discarded, exactly one Gemini call.
- Expired session mid-question → landing state, not a 500.
- Request with a forged/unknown session id → landing state, never another session's data.
- Rate limit exceeded → friendly response, not an unhandled `TooManyRequests`.
- No file remains on disk after success and after failure (AC 10).

**Manual verification (not automatable here)**
- Contrast ratios and rendered font sizes (AC 14) — browser devtools.
- The 3:00 banner and 5:00 wipe in real elapsed time; automated tests use `travel_to`,
  which does not exercise the client-side JS timers.
- Screen-reader announcement of the idle banner.
- A real password-protected PDF, unless `qpdf` is installed.
- One live Gemini call against a **synthetic** insurance document (D8) to sanity-check
  extraction quality — automated tests never hit the network.

---

## Risks / Rollback

**Product risk**
- **Hallucinated benefit figures are the highest-harm failure.** A confidently wrong
  copay is worse than no answer. Mitigated by R5.3 ("return null, never guess"),
  low temperature, `responseSchema`, and D11's visible "confirm with your plan" framing —
  but not eliminated. Worth checking against a real (synthetic) document at Checkpoint 3
  before building the chat UI on top of it.
- **D8 depends on discipline, not a control.** Nothing in the code stops someone
  demoing with a real insurance document on the free tier. The README warning is the
  only guard; a pilot needs paid billing enabled first.

**Technical risk**
- **Superseded:** the original "~3 concurrent uploads saturate Puma" risk understated
  the problem. A real 140-page policy spent 15.8s in `pdf-reader` before any API call.
  Addressed by the page cap (D12) and by moving analysis to Sidekiq (D6 revised).
- **A failed cache write makes an upload vanish** — the user sees success, then an
  instantly empty session. R3.6 covers surfacing it; easy to overlook because the
  configured `error_handler` swallows Redis errors by design.
- **Brakeman runs with `--exit-on-warn`**, so any warning fails `bin/ci`. File upload
  handling and rendering user-supplied text are the likely triggers; may need a
  documented ignore entry.
- **Tailwind v4 is CSS-first** — there is no `tailwind.config.js`. Type scale and color
  tokens go in `@theme` inside `app/assets/tailwind/application.css`.
- **`gemini-2.5-flash` was verified today**, but model availability shifts. The client
  should fail loudly with an operator-facing message if the model 404s.

**Process risk**
- **The user's editor has twice overwritten this spec from a stale buffer.** Reload spec
  and plan files before editing them, or answers and decisions get silently lost.

**Rollback**
Every checkpoint is additive except three touched files: the layout, the parameter-
filtering initializer, and the three environment configs (already committed separately as
Redis wiring). Reverting a single checkpoint's commit restores a working app, since no
checkpoint after 1 is depended on by the ones before it. There are no migrations and no
database, so rollback is purely code — nothing to unwind in persisted state.

---

## Resolved: `.env`

`.env` held only `REDIS_URL` and was never actually loaded (`dotenv` is a transitive
kamal dependency with `require: false`). **The user deleted it on 2026-09-01.** The app
reads `ENV["REDIS_URL"]` when set and otherwise falls back to
`redis://localhost:6379/0`, so local development needs no env file at all — verified
working after deletion. `REDIS_URL` remains the deployment knob; no dotenv gem is
needed, and nothing further is owed here.
