# Feature Spec: insurance-helper-mvp

## Summary

A no-login, single-session web app where an older adult uploads one PDF insurance
document, sees the key plan facts (copays, deductible, plan name, service phone) in a
large-type, plain-language layout, and can ask follow-up questions answered only from
that document. All session data lives in an expiring cache with a 5-minute idle TTL and
is wiped automatically; nothing is persisted to disk or a database.

---

## Context from the codebase (Phase 0 findings)

These are confirmed by reading the repo, not assumed. They constrain the requirements
below and drive several Open Questions.

- **No database, no Active Storage.** `active_record/railtie` and
  `active_storage/engine` are commented out in `config/application.rb:7-8`; no adapter
  gem in the `Gemfile`. Uploads can only be handled in-memory from the
  `ActionDispatch::Http::UploadedFile` tempfile. This *supports* the privacy goal but
  means there is no fallback store if the cache is unavailable.
- **Cache stores were not usable for this feature as generated** — now fixed, see D1/D2.
  Development was `:memory_store`, test was `:null_store` (which silently discards every
  write and would have failed every session test), and production's `cache_store` was
  commented out. All three are now configured.
- **Redis was not installed locally** — now installed (Homebrew 8.10.1) and running via
  `brew services`. The `redis` gem (6.0.0) was already in the `Gemfile` as the Action
  Cable adapter default. `config/cable.yml` establishes the `REDIS_URL` convention and
  claims **DB 1**, so the cache store uses **DB 0**.
- **Puma runs one worker by default** (`config/puma.rb`, `WEB_CONCURRENCY` unset) with
  3 threads. `:memory_store` therefore works in single-process development, but breaks
  the moment a second worker exists.
- **Rate limiting is already available without a new gem.** Rails 8.1 ships
  `ActionController::RateLimiting#rate_limit` (actionpack 8.1.3.1). Note its default
  `with:` **raises `TooManyRequests`** rather than returning a bare 429, so a friendly
  handler is needed. `rack-attack` (suggested in the source requirement) is not needed.
- **`ApplicationController` sets `allow_browser versions: :modern`**
  (`app/controllers/application_controller.rb:3`), which returns **406 to older
  browsers**. This directly conflicts with the stated audience; resolved in D5.
- **No HTTP client gem.** No faraday/httparty/http. `Net::HTTP` (stdlib) is available.
- **Frontend stack is Hotwire, not an SPA.** Propshaft + importmap + Turbo + Stimulus +
  Tailwind, with `pin_all_from "app/javascript/controllers"`. Server-rendered ERB with
  Turbo Frames/Streams and Stimulus controllers is the idiomatic fit; the source
  requirement's "javascript/ screens" structure is not.
- **`pdf-reader` 2.16.0** raises `PDF::Reader::EncryptedPDFError` (a subclass of
  `UnsupportedFeatureError`) and `PDF::Reader::MalformedPDFError`. It *can* decrypt
  standard-security PDFs that have an empty user password, so "encrypted" and "needs a
  password to open" are not the same case.
- **Logging does not filter this feature's data.**
  `config/initializers/filter_parameter_logging.rb` filters `:passw, :email, :secret,
  :token, …` but not an uploaded document or a user's typed question — both of which
  can contain PHI.
- **CSP is entirely commented out** (`config/initializers/content_security_policy.rb`).
- Current layout wraps content in `container mx-auto mt-28 px-5 flex`
  (`app/views/layouts/application.html.erb`), which is not the large-type,
  high-contrast shell this feature needs.
- Working branch is `mvp`. `ai/feature-specs/` and `ai/plans/` exist and are empty.
  There is no `CHANGELOG.md` yet (Phase 5 will need one created).

---

## Resolved Decisions

All open questions are answered. The original Q&A is preserved verbatim in
**Answered Questions (record)** at the end of this document.

**D1 — Cache store.** Redis, installed via Homebrew (8.10.1), running under
`brew services`. `Rails.cache` is the interface; `SessionCache` wraps it.
- development + production: `:redis_cache_store` → `ENV["REDIS_URL"]` when set,
  otherwise `redis://localhost:6379/0`. Redis **DB 0**; `config/cable.yml` already claims
  **DB 1**. There is no `.env` file and no dotenv gem — local development runs entirely
  on the fallback, and `REDIS_URL` is a deployment-only knob.
- Pool size tracks `RAILS_MAX_THREADS` (3), matching Puma's thread count.
- An `error_handler` logs Redis failures. Consequence: on an outage, reads return `nil`,
  which renders as "your document was removed" — acceptable. A failed *write* means an
  upload appears to succeed then instantly vanishes; R3.6 covers surfacing that.
- Wired and verified 2026-09-01. `bin/setup` and the README need Redis as a prerequisite.

**D2 — Test cache store.** `:memory_store`, not Redis. `:null_store` silently discarded
writes and would have failed every session test. Memory store keeps `bin/ci` free of an
external service, and parallel test workers are separate processes, so each gets an
isolated store. TTL semantics are equivalent for the expiry assertions.

**D3 — Scanned PDFs: deferred.** Below the ~200-char threshold the app shows a friendly
"we couldn't read the words in this document" error with a retry, and makes no Gemini
call. Accepted consequence: a photographed insurance card saved as a PDF is a dead end
in the MVP. Listed in Non-Goals; first candidate for the next phase alongside D6.

**D4 — Idle timing: banner at 3:00, wipe at 5:00.** Cache TTL is **300 seconds**,
refreshed on every interaction. The banner gives a 2-minute warning rather than the
original 1-minute one.

**D5 — Browser support.** Keep `allow_browser versions: :modern` and rely on Rails 8.1's
built-in behavior, which already renders `public/406-unsupported-browser.html` — a file
that already exists in this repo. Work is a copy rewrite for this audience, not code.

**D6 — Background processing with Sidekiq. Revised 2026-09-02.**

*Originally:* the Gemini call ran synchronously, with Sidekiq deferred to the next
phase, on the understanding that documents were 3,000–10,000 tokens and the only slow
part was a 5–20s API call.

*What changed:* a real policy document (Sample Medical Policy NY IEX 2026) measured
**140 pages, ~106,000 tokens**, and `pdf-reader` took **15.8 seconds** of CPU-bound work
to extract it — before any API call. Three concurrent uploads would have stopped the
server answering anything, heartbeats included, so idle timers would fire on active
readers. The synchronous design was reasonable for the documents the spec described and
is not reasonable for the documents that actually arrive.

*Now:*
- **Extraction stays synchronous** but is bounded by a page cap (D12), which brings it to
  roughly 2.3 seconds regardless of how long the document is.
- **The Gemini analysis call moves to a Sidekiq job.** It is the unbounded part — 2s on a
  small document, far longer on a large one, and subject to upstream slowness and
  retries.
- The job receives only the session id. The document text is already in the cache, so no
  file bytes pass through the queue and nothing touches disk (R3.5 still holds).
- Session status gains `analyzing`, between `uploaded` and `extracted`.
- **R7.2's processing screen stops being optional.** With analysis off the request, the
  reader needs to be told the document is being read, which is what the spec asked for
  anyway.

Sidekiq uses the Redis already required by D1, on a separate database from the cache
(DB 0) and Action Cable (DB 1).

**D12 — Extraction is capped at 20 pages.** Measured on the 140-page policy: 20 pages
takes 2,286ms and yields ~13,200 tokens, against 19,528ms and ~106,000 tokens for the
whole document — 8.5x faster and 8x cheaper. `Deductible` and `Copayment` both first
appear on page 4, so every field the plan screen shows lives inside the cap.

Accepted consequence: a question about something only in the later pages cannot be
answered. The app already handles that honestly — it says the document does not cover it
and gives the plan's phone number — which is the right failure for this audience.
Revisit with retrieval over `full_text` only if real usage shows fallback questions are
both frequent and about deep content.

**D7 — Gemini client. Verified working 2026-09-01.** Model `gemini-2.5-flash` via the
Gemini Developer API:
`POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`.
API key is in **Rails encrypted credentials** as `gemini_api_key` (confirmed present and
working); pass it as the `x-goog-api-key` header, not a `?key=` query param, so it never
lands in a URL or access log. HTTP via `Net::HTTP` (stdlib) — no new gem needed.
Confirmed by live calls:
- The model name and endpoint resolve; `modelVersion` echoes back `gemini-2.5-flash`.
- **It is a thinking model by default.** A trivial 2-token reply spent 15 thinking
  tokens (21 total). `generationConfig.thinkingConfig.thinkingBudget: 0` disables it and
  dropped the same call to 6 total tokens. This is a live lever for the §8 cost goal.
  Gotcha to avoid: thinking tokens count against `maxOutputTokens`, so a low
  `maxOutputTokens` with thinking on can consume the whole budget and return an empty
  response.
- **Structured output works.** `responseMimeType: "application/json"` plus a
  `responseSchema` returned clean, directly parseable JSON with no code fence and no
  prose wrapper. This is how R5.1 should request its JSON — it largely removes the
  "model returned prose or a fenced block" failure mode rather than parsing around it.

**Settled during implementation (2026-09-02):** thinking stays **off for extraction
too**. Measured against live calls with `thinkingBudget: 0`: the full synthetic
Summary of Benefits returned all nine fields correctly, and a deliberately sparse
document returned the one field it contained and `null` for the other eight rather
than inventing plausible values. Accuracy did not need a thinking budget, so the
cheaper setting stands for both call types.

**D8 — API tier: free tier for the MVP.** Chosen deliberately after the tradeoff was
raised twice. Google's free-tier terms permit using submitted content to improve their
products, including human review. **Therefore the MVP must be demoed and tested with
synthetic or sample insurance documents only — no real member data.** Switching to paid
billing removes the restriction with no code change (same key, endpoint, and model), and
must happen before any pilot with real documents. See R9.5.

**D9 — Upload size limit: 15MB**, enforced in Rails and at the proxy/web-server layer, so
oversized bodies are rejected before being fully buffered.

**D10 — Session id transport: Rails' built-in signed `session` cookie.** It is already
signed and `httpOnly`, so `POST /sessions` is dropped from the endpoint list; a session is
established lazily on first visit. Removes an endpoint and hand-rolled cookie signing.

**D11 — Grounding affordances are in scope.** The plan and chat screens carry visible
"based on your document" attribution plus a standing prompt to confirm details with the
plan's customer service number. Driven by liability concern, and pairs with R5.3's
"return null, never guess" instruction.

---

## Requirements

### R1 — Session lifecycle
- R1.1 A session is created on first visit, identified by a non-guessable opaque id.
- R1.2 Session state is stored in an expiring cache under a namespaced key
  (`insurance_session:<session_id>`) with a **300-second TTL** (D4).
- R1.3 The TTL is refreshed on every user-initiated interaction (upload, question,
  heartbeat, plan-info fetch).
- R1.4 When the key expires or is deleted, all document text, extracted fields, summary,
  and chat history for that session are gone; the user is returned to the landing screen.
- R1.5 The session id is the only access boundary. A request carrying an unknown or
  expired id gets the "your document was removed" landing state, never an error trace
  and never another session's data.
- R1.6 An explicit delete endpoint wipes the session immediately.

### R2 — Cached session shape
The cached value holds:
`session_id`, `status` (`uploaded` | `extracted` | `error`), `structured_fields`,
`plain_summary`, `full_text`, `chat_history`, `created_at`, `last_active_at`.

`structured_fields` keys: `member_name`, `plan_type`, `plan_name`, `insurance_id`,
`copay_primary_care`, `copay_specialist`, `deductible`, `plan_year`,
`customer_service_phone`. Any field not found in the document is `null`.

### R3 — Upload and validation (`DocumentValidator`)
- R3.1 Accept exactly one file per session.
- R3.2 Reject files whose first bytes are not the `%PDF-` magic header. Extension and
  client-supplied content type are checked but never trusted alone.
- R3.3 Reject files over the 15MB limit (D9) before reading
  them into memory.
- R3.4 Reject PDFs that cannot be opened without a password, with a distinct message
  from "damaged".
- R3.5 The uploaded bytes are never written to a persistent location by the app; the
  multipart tempfile is deleted as soon as processing finishes or fails.
- R3.6 If the cache write fails (e.g. Redis unavailable), the user sees a real error
  rather than an apparently-successful upload that instantly vanishes (D1).

### R4 — Text extraction (`PdfExtractionService`)
- R4.1 Extract text with `pdf-reader`, reading at most the first 20 pages (D12).
- R4.2 If extracted text is below a "near-empty" threshold (~200 chars), the document
  is scanned/image-only: show the "we could not read the words in this document" error
  with a retry, and make no Gemini call (D3). Vision fallback is deferred.
- R4.3 Store the extracted text as `full_text` in the session cache.
- R4.4 Rescue `PDF::Reader::EncryptedPDFError` and `PDF::Reader::MalformedPDFError`
  separately and map them to the "locked" and "damaged" user messages respectively.

### R5 — Classification, extraction, and summary (`GeminiClient`, one call)
- R5.1 One Gemini call per upload returns JSON with `is_insurance_document`,
  `document_type`, `structured_fields`, and `plain_summary`.
- R5.2 If `is_insurance_document` is false, discard the upload, set status `error`, and
  show the "doesn't look like insurance" screen. No further calls are made.
- R5.3 The prompt explicitly instructs: return `null` for any field not present; do not
  guess, infer, or estimate.
- R5.4 `plain_summary` is written in plain language with no insurance jargon.
- R5.5 Temperature is low (0.1–0.2) and the response is requested as structured JSON.
- R5.6 A malformed or unparseable model response is treated as a processing error with a
  retry, not a crash.

### R6 — Q&A (`GeminiClient`, per message)
- R6.1 Each turn sends `plain_summary` + the last ~6 turns of history + the question.
  The full PDF is never re-sent on the normal path.
- R6.2 The system prompt enforces: short sentences, plain language, warm tone, and
  answering **only** from the provided context.
- R6.3 When the answer is not in the provided context, the model says so and points the
  user at `structured_fields.customer_service_phone` (when present).
- R6.4 Fallback: if the response flags that the summary did not cover the question
  (e.g. `found_in_summary: false`), re-issue that one question **once** against
  `full_text`. At most one fallback per question.
- R6.5 Both the user's question and the assistant's answer are appended to
  `chat_history` in the cache.

### R7 — Screens (server-rendered ERB + Turbo + Stimulus)
- R7.1 **Landing**: one large button, "Add Your Insurance Document", plus reassuring
  subtext about automatic deletion. No mention of "AI", "upload", "session", or other
  technical vocabulary anywhere in user-facing copy.
- R7.2 **Processing**: spinner with rotating friendly messages; after 20 seconds, an
  additional "this is taking a little longer than usual" message.
- R7.3 **Plan info**: card layout, one fact per row, in the order Name, Plan Type, Plan
  Name, Insurance ID, Primary Care Copay, Specialist Copay, Deductible, Plan Year,
  Customer Service Phone. Body text ≥ 18px, key numbers ≥ 24px, contrast meeting WCAG AA.
  `null` fields render as "Not found in your document", never blank or omitted.
- R7.4 **Chat**: prompt "What would you like to know about your plan?", 3–4 tappable
  example questions, large-text bubbles with clear user/assistant distinction, no
  "typing…" affectation.
- R7.6 **Grounding**: the plan and chat screens carry visible "based on your document"
  attribution and a standing prompt to confirm details with the plan’s customer service
  number (D11).
- R7.5 **Errors**: every error state pairs its message with a retry control — never a
  dead end. Copy per the source requirement (not a PDF / not insurance / locked or
  damaged).

### R8 — Idle expiry UX
- R8.1 At 3:00 idle, a non-blocking top banner: "Still there? We’ll remove your document
  in 2 minutes to keep it private." (D4)
- R8.2 At 5:00 idle, the client clears its state and returns to the landing screen with
  "Your document has been removed to keep your information private. Add it again
  anytime."
- R8.3 User activity pings the heartbeat endpoint, throttled to at most once per 10
  seconds.
- R8.4 Client-side and server-side expiry agree: the banner and redirect are driven by
  the same 300s budget the cache TTL uses (D4).

### R9 — Security and privacy
- R9.1 The session id rides Rails built-in signed `session` cookie, which is already
  signed and `httpOnly` (D10). `secure` is set in environments served over HTTPS. There
  is no `POST /sessions` endpoint; a session is established lazily on first visit.
- R9.2 Uploads are rate-limited per IP, with a friendly response rather than a raw 429
  error page.
- R9.3 Document text, extracted fields, and user questions must not be written to the
  Rails log (parameter filtering and/or explicit scrubbing).
- R9.4 The app states plainly, in the UI, that documents are removed automatically.
- R9.5 The README/handoff notes state that this MVP is **not HIPAA-compliant
  infrastructure**. Because the MVP runs on the Gemini free tier, whose terms permit
  using submitted content for product improvement (D8), the MVP must be demoed and
  tested with **synthetic or sample documents only**. Paid billing must be enabled
  before any pilot with real member data.

---

## Non-Goals

- User accounts, login, or any persistence across sessions.
- More than one document per session.
- Non-PDF uploads (images, Word, HTML).
- Editing or correcting extracted fields.
- Multi-language support.
- Native mobile app (responsive web only).
- HIPAA-grade compliance infrastructure, BAAs, or audit logging.
- Ruby-side OCR (Tesseract or similar).
- Scanned/image-only PDFs, including Gemini vision fallback (deferred, D3).
- Background job processing; the Gemini call runs synchronously (deferred to Sidekiq, D6).
- A `POST /sessions` endpoint; Rails’ built-in session covers it (D10).
- Any SQL database or Active Storage integration.
- Streaming/token-by-token chat responses.

---

## Edge Cases

**Upload / file**
- Zero-byte file, or a file with a `.pdf` extension that is actually a JPEG/Word doc →
  magic-byte check rejects it with the "we can only read PDF files" message.
- A PDF that opens but has near-zero extractable text (scanned insurance card photo
  saved as PDF) → friendly "could not read the words" dead end in the MVP, per D3.
- A PDF encrypted with an *empty* user password — `pdf-reader` opens these fine, so it
  must not be misreported as "locked".
- A PDF that requires a real password → "locked", distinct from "damaged".
- A very long document (100+ pages) whose `full_text` is large enough to be an
  expensive or over-limit fallback call.
- A second upload attempt in a session that already has a document.
- Upload arrives after the session already expired mid-form.

**Model / API**
- Gemini returns valid JSON but with `is_insurance_document: true` and every
  `structured_fields` value `null` (e.g. a generic insurance brochure with no member
  data) → plan screen shows all "Not found in your document" rows, chat still works.
- Gemini returns prose instead of JSON, or JSON wrapped in a code fence — largely
  mitigated by `responseSchema` (D7), but still handled defensively.
- Gemini API times out, rate-limits (429), or returns 5xx → friendly retryable error,
  and the session is not left stuck in `uploaded` forever.
- Missing or invalid API key at boot → a clear operator-facing failure, not a confusing
  end-user error.
- The model answers from world knowledge instead of the document (grounding failure) —
  the highest-risk correctness case, since a wrong copay figure is actively harmful.
- The fallback path triggers on nearly every question because the summary is too thin,
  quietly destroying the cost model.
- `customer_service_phone` is `null`, so the "call this number" fallback advice has no
  number to give.

**Session / timing**
- User reads the plan card silently for 5 minutes without clicking or scrolling (a short
  page produces no scroll events) → document wiped mid-read. See Open Question Q4.
- User has two browser tabs open on the same session; one is idle, one is active.
- Heartbeat fires while the browser tab is backgrounded or the laptop is asleep.
- Cache eviction under memory pressure removes the session before its TTL.
- A question is submitted at the exact moment the session expires.
- Extraction is still running when the idle timer fires.
- Browser back button after expiry shows a cached plan screen with no live session
  behind it.

**Concurrency / infrastructure**
- Two Puma workers with a per-process memory cache would split sessions across
  processes; a user's second request could land on a worker that has never seen them.
- Gemini calls of 5–20s occupying Puma's 3 threads (see Open Question Q6).

**Accessibility / audience**
- A user on an older browser currently receives a blank 406 from
  `allow_browser versions: :modern` (Open Question Q5).
- Browser zoom at 150–200% must not break the card or chat layout.
- Screen-reader users need the idle banner announced, not just visually shown.

---

## Acceptance Criteria

**Session and expiry**
1. Visiting the root path yields a session id in an `httpOnly` cookie, and a cache entry
   that reports a TTL of ≤ 300 seconds.
2. Any interaction (upload, question, heartbeat) resets the cached TTL back to 300
   seconds; a test can assert the refreshed TTL.
3. 300 seconds after the last interaction, the cache key is gone and a request with that
   session id renders the landing screen with the "document has been removed" message —
   not a 404, exception, or empty plan screen.
4. `DELETE` on the session removes the cache entry immediately; a subsequent plan-info
   request renders the removed-document state.
5. A request carrying a session id that never existed is handled identically to an
   expired one.
6. Automated tests covering the above pass in the test environment — which requires the
   test cache store to no longer be `:null_store`.

**Validation**
7. A JPEG renamed to `report.pdf` is rejected with the "we can only read PDF files"
   message and a visible retry control.
8. A file over the size limit is rejected with a friendly message and never fully read
   into memory.
9. A password-protected PDF produces the "locked" message; a truncated/corrupt PDF
   produces the "damaged" message; the two are distinguishable in tests.
10. After any upload — success or failure — no file from the request remains on disk.

**Extraction and display**
11. Uploading a valid insurance PDF results in exactly **one** Gemini call, and the
    session reaches status `extracted`.
12. The plan screen renders all nine fields in the specified order, with every `null`
    value shown as "Not found in your document".
13. A non-insurance PDF (e.g. a restaurant menu) produces the "doesn't look like an
    insurance document" screen, the upload is discarded, and no further Gemini calls are
    made for that document.
14. Body copy computes to ≥ 18px and copay/deductible values to ≥ 24px; the palette
    passes WCAG AA contrast.

**Q&A**
15. Asking a question sends `plain_summary` + at most the last 6 turns + the question —
    verifiable by asserting the outbound payload never contains `full_text` on the
    normal path.
16. A question whose answer is not in the summary triggers **at most one** fallback call
    carrying `full_text`; a second fallback for the same question never occurs.
17. When the answer isn't in the document at all, the reply says so and offers the
    customer service number when one was extracted.
18. Chat history persists across turns within a session and disappears entirely when the
    session expires.

**Idle UX**
19. With no interaction, the banner appears at 3:00 and the redirect-to-landing happens
    at 5:00.
20. Continuous user activity keeps the session alive indefinitely, with heartbeat
    requests throttled to no more than one per 10 seconds.
21. Dismissing/acknowledging the banner resets both the client timer and the server TTL.

**Privacy and abuse**
22. Document text, extracted field values, and user questions do not appear in
    `log/*.log` after a full upload-and-chat run.
23. Exceeding the upload rate limit returns a friendly, styled message rather than an
    unhandled `TooManyRequests` error page.
24. Nothing from the session is written to any file, database, or persistent store.

**Project health**
25. `bin/rubocop`, `bin/brakeman`, and `bin/rails test` pass (i.e. `bin/ci` is green).

---

## Answered Questions (record)

All of these are resolved; the decisions they produced are in **Resolved Decisions**
above, which is the authoritative list. Kept verbatim as the record of what was asked
and answered.

### Follow-ups (asked after the first round of answers)

**F1 — Q4 timing: confirm the split.** You wrote "add to 5 minutes. 3 + 2." I read that
as **banner at 3:00, document wiped at 5:00** — i.e. a 2-minute warning instead of the
original 1-minute one. The other possible reading is banner at 5:00 and wipe at 7:00.
Which is it?
**Answer:** banner at 3:00, document wiped at 5:00

**F2 — Q9 was about plumbing, not pricing.** You answered "i like free. use free," but
Q9 asked how the session id reaches the browser: (a) a custom `session_id` cookie plus a
`POST /sessions` endpoint, as the original requirement specified, or (b) Rails' built-in
signed `session` cookie, which is already `httpOnly` and needs no creation endpoint. I
described (b) as giving us the id "for free," so you may have meant that — but confirm.
My recommendation is (b): less code, one fewer endpoint, signing handled by Rails.
**Answer:** b

**F3 — Gemini free tier vs. paid tier, given the document contents.** Your Q7 answer
picks the Gemini Developer API (`generativelanguage.googleapis.com`), which is fine and
needs no code change either way. The open point is billing tier:
- On the **free tier**, Google's terms permit using submitted content to improve their
  products, including human review.
- On the **paid tier**, that does not apply. Same endpoint, same model, same key — you
  enable billing on the project and nothing in the code changes.

The uploads here contain member names and insurance IDs, and your Q10 answer was
"i don't want to get sue." Which tier should the spec record?
**Answer:** use Free. it's just MVP

---

**Q3 — Scanned PDFs: support in MVP or defer?** Sending the raw PDF to Gemini's vision
input is more code, a different request shape, and a much larger payload — but without
it, a photographed insurance card saved as a PDF (a *very* likely input from this
audience) hits a dead end. Support it now, or show "we couldn't read the text in this
document" and defer?
**Answer:** defer for now

**Q4 — Is 3 minutes of idle actually right for this audience?** The target user reads
slowly, and the plan card is a short page that generates no scroll events. Passive
activity detection can plausibly wipe a document out from under someone who is simply
reading it. Options: keep 3:00 with the explicit "I'm still here" button; lengthen the
window (e.g. 10 minutes idle, still ephemeral); or treat the page being visible as
activity (periodic heartbeat while the tab is focused). The last option keeps the
privacy story but removes the mid-read wipe.
**Answer:** hmmm... add to 5 minutes. 3 + 2.

**Q5 — `allow_browser versions: :modern`.** As configured, an older browser gets a blank
406 — the worst possible outcome for this audience, since they'd see nothing at all.
Relax it for this app, or keep it and add a friendly "your browser is too old" page?
**Answer:** add a friendly "your browser is too old" page

**Q6 — Synchronous or background processing for the Gemini extraction call?** A 5–20s
call holds one of Puma's 3 threads. Synchronous is far simpler and fine for a demo;
background (Active Job) needs an adapter and polling, and the default async adapter
loses jobs on restart. Is this a demo for a handful of concurrent users, or does it need
to survive a real pilot's traffic?
**Answer:**  a demo for a handful of concurrent users. really need this is sidekiq in next phrase. remember this.

**Q7 — Gemini access and data handling.** Three parts: (a) which model? (b) where does
the API key live — Rails encrypted credentials or `ENV`? (c) which endpoint — the Gemini
Developer API or Vertex AI? This third part matters for §9: consumer/free-tier Gemini
API terms may permit using submitted content to improve the product, which is a poor fit
for documents containing member names and IDs. Do you already have a key and a preferred
tier?
**Answer:** gemini-2.5-flash is a good start. Rails encrypted credentials. https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent. I have a key.

**Q8 — Upload size limit.** The source requirement suggests 15MB. Confirm, and note that
without a size cap enforced at the web-server layer, a large body is already buffered
before Rails can reject it.
**Answer:** 15MB

**Q9 — Session id transport.** The source requirement specifies a custom `session_id`
cookie plus a `POST /sessions` endpoint. Rails' own `session` is already a signed,
`httpOnly` cookie and would give us the id for free without a creation endpoint. Follow
the requirement's explicit endpoint list, or use Rails' built-in session and drop
`POST /sessions`?
**Answer:** i like free. use free.

**Q10 — Grounding verification.** The most dangerous failure is a confident, wrong copay
figure. Do you want the MVP to display source-grounding affordances (e.g. "based on your
document" attribution, or a visible disclaimer to confirm with the plan's phone number),
or is the system prompt's grounding instruction sufficient for this stage?
**Answer:**  display source-grounding affordances. i don't want to get sue
