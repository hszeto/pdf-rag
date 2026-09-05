# Feature Spec: encrypted-pdfs

## Summary

RC4-encrypted PDFs — common in insurance, banking and government documents — are
refused as "damaged" when they are perfectly readable. Origami asks OpenSSL for
RC4, OpenSSL 3 keeps RC4 in a legacy provider that is not loaded, and the scanner
turns any error into `Damaged`.

## Findings

- Reproduced: `EVP_CipherInit_ex: unsupported (… RC4 …)` from `pdf_safety_scanner.rb:47`.
- `OpenSSL::Provider.load("legacy")` makes RC4 available — verified locally, **not** on Render.
- `pdf-reader` reads the same file fine (30 pages, 116k chars) — it implements RC4 in Ruby.
- Origami **does** take `decrypt: false` at read time (`parsers/pdf.rb:30`) — an earlier
  finding here said otherwise and was wrong. We still decrypt: an undecrypted walk reads
  encrypted strings and streams, so attachment names and JavaScript bodies become noise
  and a hostile file would pass screening unread.
- **Origami prompts on `STDIN` for a password** (`parsers/pdf.rb:32-36`). Under Puma that
  is a request blocking on a terminal read. Masked today only because RC4 fails first.
- `open_pdf` rescues `StandardError` and discards `e.message` — nothing logs why.
- `ProcessingError::Locked` already exists and is raised by extraction, never by screening.

## Requirements

- R1 A PDF encrypted with an empty user password is accepted and read.
- R2 A PDF that genuinely cannot be parsed is still refused (R1.6 holds: cannot inspect ≠ safe).
- R3 The underlying parser error is logged, never shown to the reader.
- R4 A PDF needing a real password is refused as `Locked`, not `Damaged`.
- R5 Screening still runs on every accepted document — no document skips it.

## Non-Goals

- Accepting password-protected PDFs by prompting for a password.
- Replacing Origami, or scanning without decrypting.
- Changing what the scanner looks for once it can parse.

## Edge Cases

- RC4 PDF, empty password → accepted, screened, read.
- AES-encrypted PDF (already supported by OpenSSL) → unchanged, accepted.
- PDF needing a real password → `Locked`, not `Damaged`.
- Truly corrupt file → `Damaged`, as now.
- Legacy provider unavailable on the container → the image fails to build (D4).
- Fixtures are buildable after all: `pdf.encrypt(cipher: "rc4", ...)` produces both the
  empty-password and the password-protected case, so neither needs an injected seam.

## Acceptance Criteria

- AC1 An RC4-encrypted fixture with an empty password passes screening and extraction.
- AC2 A corrupt fixture is still refused as `Damaged`.
- AC3 A password-protected fixture is refused as `Locked`.
- AC4 The parser's own message appears in the log for every refusal.
- AC5 No reader-facing string mentions RC4, OpenSSL or providers.
- AC6 `bin/rails test`, `bin/rubocop` and Brakeman pass.

## Resolved Decisions

- **D1** Load `OpenSSL::Provider.load("legacy")` process-wide. RC4 and DES become available
  to the whole process; accepted, because the documents this app exists to read are
  encrypted with RC4.
- **D2** Pass `prompt_password: -> { "" }` so Origami never reaches for `STDIN`.
- **D3** A PDF needing a real password is refused as `Locked`, with copy saying it is
  password protected — not `Damaged`.
- **D4** The provider's absence is caught **when the image is built**, not at boot and not
  per upload. A `RUN` check fails the Docker build, so Render reports it as a failed deploy
  rather than serving a site that quietly refuses encrypted files. Revises the earlier
  edge case that called for failing at boot: a boot failure takes the whole site down for
  documents that have nothing to do with encryption.
