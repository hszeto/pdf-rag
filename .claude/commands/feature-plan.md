---
description: Phase 2 of ASDD — research and write an implementation plan for an approved feature spec.
argument-hint: feature-spec md file
---

# /feature-plan $ARGUMENTS

Follow the `asdd` skill's phase structure. This command covers **Phase 2 (Plan)**
only. Do not begin implementation.

## 1. Locate the approved spec

`$ARGUMENTS` is a feature name or note identifying which spec to plan for.
Search `ai/feature-specs/` for a matching file.

If no matching approved spec exists, stop and tell the user — do not plan from
an unapproved or invented spec.

Before planning, re-read the spec's **Open Questions** — every spec, if the
feature spans more than one. If any are unanswered — in the file and in this
conversation — stop and ask. Do not plan on assumed answers.

Once answered, promote the section to **Resolved Decisions**: restate each as
the decision made, keeping the rationale, and confirm none remain open. Editing
the spec is the only write this command makes outside `ai/plans/`. If a spec has
no Open Questions section, or it is already resolved, proceed.

## 2. Research

Explore the actual code relevant to this feature (don't rely on memory of the
codebase). Confirm assumptions against `CLAUDE.md` if present, and check what
test/lint/build tooling actually exists in this project before assuming it.

## 3. Write the plan

Write to `ai/plans/<name>.md`, matching the spec's slug.

**Keep it scannable.** Bullets, not paragraphs. One line per bullet — if a
design decision needs more, state the decision in one line and the reason in
one more, then move on. No restating the spec. Omit any section that would be
empty.

Use this template:

```markdown
# Plan: <name>

## Confirmed Decisions
- <decision> — <one-line reason>
  <or: "none raised">

## Approach
- <key design decision, one line each — 3-6 bullets>

## Files Touched
- <path> — <what changes>

## Checkpoints
1. <one commit-sized unit of work, one line>
2. ...

## Test Plan
- <specific test/case to add or run>
- <or: tooling that doesn't exist + what to verify manually instead>

## Risks / Rollback
- <risk> → <mitigation or how to undo>
```

## 4. Stop

After writing the file(s), stop and wait for approval. Do not begin
implementation until the user explicitly approves the plan.
