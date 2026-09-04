---
description: Phase 0 + Phase 1 of ASDD — orient in the codebase, then write a feature spec for approval.
argument-hint: Feature description
---

# /feature-spec $ARGUMENTS

Follow the `asdd` skill's phase structure. This command covers **Phase 0 (Orient)**
and **Phase 1 (Feature Spec)** only. Do not proceed to planning or implementation.

## 1. Orient (Phase 0)

Read `CLAUDE.md` if it exists, plus the existing code relevant to this
requirement — don't assume patterns from memory; confirm them by reading the
actual files.

## 2. Write the feature spec (Phase 1)

Requirement: "$ARGUMENTS"

Write the spec to `ai/feature-specs/<name>.md`, where `<name>` is a short
kebab-case slug derived from the requirement.

**Keep it scannable.** Bullets, not paragraphs. One line per bullet. A whole
spec should fit on one screen — if it doesn't, the feature is too big to spec
in one file. Omit any section that would be empty; don't pad it with filler.

Use this template:

```markdown
# Feature Spec: <name>

## Summary
<1-2 sentences: what this does and who it's for>

## Requirements
- <one line each, testable>

## Non-Goals
- <one line each>

## Edge Cases
- <case> → <expected behavior>

## Acceptance Criteria
- <one line each, checkable as done/not done>

## Open Questions
- <question — one line, answerable without a paragraph back>
```

If you have genuine ambiguity about requirements, put it in **Open Questions**
rather than guessing — do not invent acceptance criteria to fill the section.

Tell the user they can answer inline in the spec file, directly under each
question, or in chat. The spec file is preferred — it's the durable record and
survives a lost session. `/feature-plan` re-reads it before planning, so answers
left there will be picked up; mentioning it in chat is still helpful if you want
them acted on sooner.

## 3. Stop

After writing the file(s), stop. Tell the user the path(s) and summarize the
Open Questions (if any). Do not run `/feature-plan` automatically — wait for
explicit approval.
