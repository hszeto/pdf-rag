---
description: Phases 3-6 of ASDD — implement an approved plan one checkpoint at a time, verifying each before handing it over to commit.
argument-hint: Plan md file
---

# /feature-implement $ARGUMENTS

Follow the `asdd` skill's phase structure. This command covers **Phase 3
(Implement)** through **Phase 6 (Manual Test Instructions)**. It does not write
commit messages — that is `/commit-message`, Phase 7.

Invoking this command **is** the user's approval of the plan. Do not ask again.

## 1. Locate the approved plan

`$ARGUMENTS` is a feature name, slug, or path identifying which plan to
implement. Search `ai/plans/` for a matching file.

If no matching plan exists, stop and tell the user — do not implement from a
spec alone, and never from an invented plan.

**Confirm it is a plan, not a spec.** These are easy to conflate — same slug,
adjacent directories. A plan lives in `ai/plans/` and its first line is
`# Plan: <name>`; a spec lives in `ai/feature-specs/` and its first line is
`# Feature Spec: <name>`. If `$ARGUMENTS` resolves to a spec — by path, or
because the file opens with `# Feature Spec:` — do **not** implement from it.
Look for the matching plan under `ai/plans/` by the same slug. If no plan
exists, stop and tell the user to run `/feature-plan` first. A spec says what
and why; it has no checkpoints, no file list, and no verification gates, so
implementing from one means inventing all three.

Read the plan *and* its spec before touching code. The plan's **Confirmed
Decisions** are settled; do not reopen them. If the plan turns out to be wrong
or incomplete once you are in the code, stop and say so rather than silently
improvising a different design.

## 2. Confirm the branch before writing anything

Check the current branch with `git branch --show-current`. This is read-only and
fine to run.

- **On `main` (or `master`)** — stop. Remind the user to create a branch and
  suggest the plan's slug verbatim as the name — no `feature/` prefix; the
  branch, the spec filename and the plan filename all share one identifier.
  Give them the exact command to run and wait for them to confirm they have
  switched. Do not start implementing on the default branch.
- **On a branch whose name has no evident relationship to this plan** — stop and
  ask whether it is the right branch before proceeding. An unrelated branch name
  usually means leftover state from other work, and mixing this feature into it
  is hard to unpick afterwards.
- **On a branch matching the plan's slug** — proceed without asking. A branch
  carrying a prefix or minor variation of the slug still counts as matching;
  only genuinely unrelated names warrant the question above.

**Never create, rename, delete or switch a branch.** Suggest the command and let
the user run it. This holds even when the user has just agreed a branch is
needed — agreeing it should exist is not permission for you to create it.

## 3. Implement ONE checkpoint, then stop

Work through the plan's checkpoints **one at a time, in order**. After each:

1. Run that checkpoint's verification gates from the plan's Test Plan.
2. Report what changed, what passed, and what the gates do *not* cover.
3. Provide the commit message for that checkpoint.
4. **Stop and wait.** The user commits before the next checkpoint begins.

Do not start checkpoint N+1 until the user says to. Running checkpoints
back-to-back leaves both sets of changes in one working tree and destroys the
checkpoint split — the user cannot commit them separately after the fact.

**Never run git.** No `git checkout -b`, no `git add`, no `git commit`, no
`git push`. Report readiness and hand over the message; the user runs it.
Reading state (`git status`, `git diff`) is fine.

## 4. Self-Verify (Phase 4) — per checkpoint, before reporting

Run this project's tests, linter, and build/typecheck. Confirm what each command
actually verifies rather than what it appears to — bundlers commonly strip types
without checking them, so a green build is not a green typecheck.

Never report a checkpoint as done on a red or skipped gate. If a gate does not
exist in this project, or cannot be run, say so explicitly rather than omitting
it.

## 5. Docs & Changelog (Phase 5) — after the last checkpoint

Update README/API docs if the change is user- or API-facing. Add a changelog
entry. If no changelog file exists yet, do not invent the convention silently —
ask whether to start one.

## 6. Manual Test Instructions (Phase 6)

Give concrete, copy-pasteable steps covering the plan's Test Plan cases. Be
explicit about what you verified yourself and what you could not — never imply a
visual check happened if no one looked at the screen.

## 7. Stop

Summarize, then hand off to `/commit-message` for the final message, summary and
PR description. Do not run it automatically.
