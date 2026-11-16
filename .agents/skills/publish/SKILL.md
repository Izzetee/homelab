---
name: publish
description: Publish a change: install and check the door, dry-run, push, open and edit a pull request, merge inside one app directory, hand everything else to the owner, and the leak runbook. Use whenever something is pushed, opened or merged in this repository.
---

# publish

## The door

`homelab-door` is the only way to push, to write pull request text and to merge. Run it as `homelab-bao run github,door-scan -- homelab-door <mode>` (add `cloudflare-access` when a route is opted in).

- `homelab-door install` once per clone (launcher, pre-push hook, identity, credential helper), then `homelab-door doctor`: every line `OK`.
- `homelab-door --dry-run <branch>`: every check on the range, nothing pushed. Fix every `FAIL` line.
- `homelab-door <branch>` pushes; `--rebased` only on a pull request branch after a rebase. Never `main`.
- `homelab-door pr <branch> <title-file> <body-file>` and `pr-edit <n> <title-file> <body-file>`: checked text only, no values, no private names.
- `homelab-door merge <n>`: only a change inside one existing `apps/tools/<app>/` after `ci-ok`; it prints `NEXT changelog homelab#<n>`.
- `homelab-door --check-tree` judges the whole tree.

## Everything else: the owner merges

Give the owner the pull request, the reviewed head sha and this command: `gh pr merge <n> --rebase --match-head-commit <reviewed sha>`. Never use the UI buttons.

## Leak runbook

A value in a commit, branch, PR text or comment is public. Stop. Tell the owner which credential it is (by name, never the value); rotating it at its source comes first. Only then close the PR and delete the branch.

## After every merge

The checklist item: **changelog entry written, operations pages updated** (skill `wiki-changelog`).
