# Plan: encrypted-pdfs

Spec: `ai/feature-specs/encrypted-pdfs.md` — D1–D4 resolved, no open questions.

## Confirmed Decisions

- **D1** Load the OpenSSL legacy provider process-wide — the documents this app exists to read are RC4.
- **D2** `prompt_password: -> { "" }` — Origami otherwise reads `STDIN` inside Puma.
- **D3** Password-protected → `Locked`, not `Damaged` — the class and its copy already exist.
- **D4** A missing provider fails the **image build**, not boot — a boot failure downs the whole site over encryption.

## Approach

- Every claim below was driven through the real classes in a spike, not assumed.
- `OpenSSL::Provider.load("legacy")` **adds** a provider; AES stayed available after it, so Rails' own AES-GCM cookies and credentials are untouched.
- The stdin prompt is the trap: unreachable today only because RC4 raises first, so loading the provider is what exposes it.
- Empty string from `prompt_password` is not just a guard — Origami's `retry unless passwd.empty?` makes it re-raise `EncryptionInvalidPasswordError` cleanly, which is exactly the error D3 wants.
- We decrypt rather than pass `decrypt: false`: undecrypted, strings and streams stay ciphertext, so attachment names and JS bodies read as noise and a hostile file passes screening unread (R5).
- `open_pdf`'s rescue becomes a ladder — `EncryptionInvalidPasswordError` → `Locked`, other `Origami::EncryptionError` → `Locked`, `StandardError` → `Damaged` — every branch logging `e.class` and `e.message` first (R3).
- The initializer runs in every environment, so the suite exercises production's path and Sidekiq is covered alongside Puma.

Spike output, for the record:

```
RC4 before legacy   CipherError: EVP_CipherInit_ex: unsupported
RC4 after legacy    AVAILABLE
AES after legacy    AVAILABLE                          <- default provider intact
read rc4+js         OK pages=1 OpenAction=/JavaScript  <- screening still works
read password       Origami::EncryptionInvalidPasswordError
pdf-reader rc4      OK 1 pages
```

## Files Touched

- `config/initializers/openssl_legacy_provider.rb` — **new**; the load, plus why.
- `Dockerfile` — final-stage `RUN` provider check, after `COPY`, before `USER` (D4).
- `app/services/pdf_safety_scanner.rb` — `prompt_password`; the rescue ladder; logging.
- `test/support/hostile_pdfs.rb` — `rc4_pdf`, `rc4_javascript_pdf`, `password_protected_pdf`.
- `test/services/pdf_safety_scanner_test.rb` — the new cases.
- `test/services/pdf_extraction_service_test.rb` — `:37` swaps its injected `raising_reader` seam for the real fixture.
- `app/services/pdf_extraction_service.rb` — comment only; `:13` claims a fixture "we cannot produce", which the spike disproves.
- `CLAUDE.md` — one entry under "Things that will bite".

## Checkpoints

1. **Open encrypted PDFs.** Initializer, Dockerfile check, `prompt_password`, three fixtures, the tests that read them. `prompt_password` ships here, not later — this is the checkpoint that makes the stdin path reachable.
   → verify: an RC4 fixture scans clean and extracts its text; JavaScript inside an RC4 PDF is still blocked; `bin/rails test` green.
   *Commit: "Read PDFs encrypted with RC4"*

2. **Refuse honestly, and say why in the log.** Rescue ladder, logging, corrected comment, CLAUDE.md.
   → verify: a password-protected fixture raises `Locked`; the truncated fixture still raises `Damaged` with its test unmodified; the parser's message appears in the log.
   *Commit: "Tell a locked PDF apart from a damaged one"*

## Test Plan

- `OpenSSL::Cipher::RC4.new` does not raise — proves the initializer ran (AC1).
- An RC4 fixture, empty password, scans clean and extracts through `PdfExtractionService` (AC1).
- **JavaScript inside an RC4-encrypted PDF is still found and blocked** — the assertion that stops D1 becoming a way to smuggle a payload past screening (R5).
- An AES-encrypted fixture still scans clean — unchanged behaviour.
- A password-protected fixture raises `Locked` (AC3). Doubles as the stdin regression test: without D2 it raises `Errno::EOPNOTSUPP`, so it cannot pass by accident.
- `truncated_pdf` and `not_a_pdf` still raise `Damaged`, tests unmodified (AC2).
- A refusal logs the parser's class and message (AC4); no reader-facing string names RC4, OpenSSL or providers (AC5).
- Tooling: `bin/rails test`, `bin/rubocop`, `bin/brakeman` (AC6). Nothing here reaches Gemini, so no `stub_gemini`.

**Gaps**

- **Debian slim is unverified — there is no Docker on this machine.** The Dockerfile check is the mitigation and only pays off on the next deploy.
- Your actual insurance PDF is not in the repo; fixtures are RC4 files the suite generates. Confirming that file is manual, not a test.

**Manual (Phase 6)**: upload the insurance PDF locally, confirm it screens, reads and summarises; after deploy, upload it on pdf-rag.com — the Render build is where D4 gets its answer.

## Risks / Rollback

- RC4 and DES become available process-wide → accepted per D1; nothing else here asks OpenSSL for either, and the default provider stays loaded.
- Screening now decrypts attacker-controlled content before walking it → the rescue ladder still refuses anything unparseable; R1.6 unchanged.
- The provider may be absent on Render → fails the build, not the running site.
- Rollback is a revert of two commits — no migration, no schema, no data. Reverting checkpoint 1 alone restores today's behaviour exactly.

## Noticed, not touched

- `Dockerfile:70` says documents live "for the hour they live"; retention has been thirty minutes since `chat-ui-and-retention-countdown`.
