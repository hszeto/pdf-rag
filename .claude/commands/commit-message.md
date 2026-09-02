---
description: Phase 7 of ASDD — generate a commit message, summary, and PR description from the current diff.
---

# /commit-message

## 1. Read the repo state

Run these directly (all read-only):

```
git branch --show-current
git status --short
git diff
git diff --staged
git log --oneline -10
```

**`git diff` does not show untracked files.** Check `status --short` for `??`
entries and read those files, or every new file in the change will be missing
from the message — which is usually the most important part of a feature.

If the project has more than one repo, resolve an absolute path to each and use
`git -C <abs-path> …`. Do not assume the shell's working directory: implementation
usually leaves it inside a subdirectory, so bare relative repo paths fail.

## 2. Write the message

1. If there are no changes at all — staged, unstaged, or untracked — say so and
   stop.
2. Write a self-contained commit message (conventional-commit style:
   `type(scope): summary`) based on the diff and the untracked files.
3. Finish with:
   - **Summary** — plain-language recap of what was built.
   - **PR description** — using the commit message as the title, with a short
     body covering what changed and why, how it was verified, and plainly what
     was *not* verified.

## 3. Hand over — never run it

Do not run `git add`, `git commit`, or `git push`. Draft the message and give the
user the exact commands to run. Every git write is theirs.
