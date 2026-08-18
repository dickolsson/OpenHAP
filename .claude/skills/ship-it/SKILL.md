---
name: ship-it
description:
  Open a pull request for the current branch, wait for CI, fix any failures, and
  merge once green. Use when asked to ship, open and merge a PR, or land the
  current work.
---

# Ship It

## Objective

Land exactly the work done in this session on `main` via a pull request.

## Scope

Ship only what this session produced — nothing more:

- If the work was a plan, the PR contains only the `plans/` documents (and any
  documentation edits made for it).
- If the work was the implementation of a plan phase, the PR contains that
  phase's changes.

If the branch carries unrelated changes, stop and ask before including them.

## Workflow

1. Commit and push any remaining work: run `make check`, then group the changes
   into Conventional Commits as the root `CLAUDE.md` describes.
2. Open a PR from the current branch to `main`, titled like its main commit,
   with a short body summarizing the change.
3. Watch the PR's CI checks.
4. If a check fails: diagnose, fix, run `make check` locally, push, and watch
   again. Repeat until green.
5. When all checks are green, merge the PR and report the merge.
