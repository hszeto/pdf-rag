---
name: asdd
description: AI Spec Driven Development workflow for this project. Use whenever the user invokes /feature-spec, /feature-plan, /feature-implement, or /commit-message, or asks to build a feature "the spec-driven way." Governs the phase structure — Orient, Feature Spec, Plan, Implement, Self-Verify, Docs & Changelog, Manual Test, Summary & Handoff.
user-invocable: false
---

# ASDD — AI Spec Driven Development

A spec-first workflow: nothing gets implemented without an approved spec and an
approved plan first. Two hard approval gates. Everything else follows from that.

## Phase structure

0. **Orient** — read `CLAUDE.md` (if present) and skim the existing codebase's
   conventions before writing anything. Don't assume patterns from memory;
   confirm them against the actual files.
1. **Feature Spec** → `ai/feature-specs/<name>.md`. Genuine ambiguity goes in
   **Open Questions** rather than being guessed at — don't invent acceptance
   criteria to fill a section. Stop for approval.
2. **Plan** (via `/feature-plan`) → `ai/plans/<name>.md`. Open Questions must be
   answered first — in the spec file or in conversation — and are promoted to
   **Resolved Decisions** in the spec before planning begins. Never plan on
   assumed answers. Stop for approval.
3. **Implement** (via `/feature-implement`) in checkpoints, **one at a time** —
   verify a checkpoint, report it with its commit message, then stop and wait
   for the user to commit before starting the next. Running checkpoints
   back-to-back leaves both sets of changes in one working tree and destroys the
   split. Pause on real ambiguity to ask rather than guess. Do not commit; see
   Principles.
4. **Self-Verify** — run tests, linter, and build/typecheck. Confirm what each
   command actually verifies rather than what it appears to; bundlers commonly
   strip types without checking them, so a green build is not a green
   typecheck. Must be green before moving on. If any of these don't exist in
   this project, say so explicitly in the plan's Test Plan section rather than
   silently skipping verification.
5. **Docs & Changelog** — update README/API docs if the change is user- or
   API-facing. Add a changelog entry every time, regardless of whether docs
   changed.
6. **Manual Test Instructions** — concrete, copy-pasteable steps to see the
   feature working.
7. **Summary & Handoff** — summary, and hand off to `/commit-message` for the
   actual commit message and PR description.

## Principles

- **Write short.** Spec and plan files are working documents someone has to
  read and approve, not prose. Bullets over paragraphs, one line per bullet,
  no restating what an earlier section already said. A spec or plan that
  doesn't fit on one screen is a signal the feature should be split, not a
  reason to keep writing. Leave a section out rather than padding it.
- The approval gates after Phase 1 and Phase 2 are non-negotiable —
  implementation never begins without explicit sign-off on both the spec and
  the plan.
- Status headers (e.g. "Status: Draft/Approved") are intentionally excluded
  from spec/plan files — approval happens in conversation, not by editing a
  field in the doc. Resolved Decisions are not an exception: they record what
  was decided, not whether the doc is approved.
- **Git is hands-off.** Never create, switch, rename or delete branches, and
  never commit — no `git checkout`, `git checkout -b`, `git branch`,
  `git branch -d`, `git commit`, or `git push`. Reading state (`git status`,
  `git diff`, `git branch --show-current`) is fine. Work on whatever branch is
  already checked out. If on `main`, ask whether that is on purpose or a branch
  is wanted, and suggest a name — but let the user create it; agreeing a branch
  should exist is not permission to create it. Checkpoints are commit-sized
  units of work, not commits to run: report each as ready and hand over its
  message. The user runs every git write themselves.
- A feature branch is worth preferring even when working solo, but creating it
  is the user's call — suggest it, don't run it.
- When exploring the codebase or researching an approach, do it dynamically
  at runtime (read the actual files) rather than relying on hardcoded
  assumptions about structure.
