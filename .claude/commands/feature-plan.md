---
description: Phase 2 of ASDD — research and write an implementation plan for an approved feature spec.
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

Use this template:

```markdown
# Plan: <name>

## Confirmed Decisions
<the spec's resolved questions, restated as decisions — or "none raised">

## Approach
<how this will be implemented, key design decisions>

## Files Touched
- <path> — <what changes>

## Checkpoints
1. <checkpoint>
2. ...

## Test Plan
- <specific tests/cases to add or run, or note what tooling doesn't exist
  and what needs manual verification instead>

## Risks / Rollback
- ...
```

## 4. Stop

After writing the file(s), stop and wait for approval. Do not begin
implementation until the user explicitly approves the plan.
