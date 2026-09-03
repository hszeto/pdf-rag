# Changelog

Notable changes to this project.

## Unreleased

### Added — any-PDF retrieval

Replaces the insurance-specific application on the `mvp` branch.

- **Any PDF**, screened for hostile content before it is stored. Scripts, launch
  actions and attached executables are refused; links and ordinary attachments are
  shown to the reader instead of blocking, because genuine documents are full of both.
- **Retrieval instead of sending the document.** Passages are chunked with overlap,
  embedded into Postgres with pgvector, and only the relevant few are used to summarise
  or answer. Measured on a 140-page policy: 1.7% of the document sent, in two calls.
- **Summaries** built from a generic-anchor query for the passages where a document
  explains itself.
- **Questions** answered from the three nearest passages, with citations to where in
  the document each answer came from. There is no full-text fallback.
- **One-hour retention**, enforced by a column that every read scopes to as well as by
  a deletion job, plus a sweep for orphaned files.

### Changed

- Application renamed from `InsuranceHelper` to `PdfRag`.
- Active Record and Active Storage enabled; the app previously had no database.
- PDF extraction is no longer capped at 20 pages — retrieval replaced the cap.
- A daily API quota is now reported as such rather than as a passing problem.

### Removed

- The insurance-specific session cache, plan screen, and five-minute expiry. All of it
  remains on the `mvp` branch.
