---
name: backup-restore
description: Take a manual backup of a stateful application, prove a dump, run a restore drill in a scratch namespace, and know when a production restore needs the owner. Use before risky changes to stateful apps and when asked to test a restore.
---

# backup-restore

## Manual backup

Create a Job from the app's dump CronJob: `kubectl -n <ns> create job --from=cronjob/<name> <name>-manual-<UTC>` and wait for `Complete`. Check the set it wrote: the dump is
non-empty, its sha256 file exists, the count matches the app. A failed or empty set is a stop. Where the sets are copied and how long they are
kept is the owner's: ask when needed.

## Restore drill (safe)

Ask for the drill as one named step of the go
(scratch only) and record its result line and counts.

1. A scratch namespace (`<app>-restore`, restricted, default-deny network policy, no route, no public label).
2. A scratch CNPG cluster with the same major version, then restore the dump into it (`pg_restore`), run `ANALYZE`, compare table counts with the live database and check that one known record exists (by key, as a count or yes/no, without printing the row).
3. Remove the scratch namespace and its volumes when done. Never point a scratch app at production data stores or the production secret path.

## Production restore

Only with the owner's go for that exact restore. Scale the app to zero first, restore, scale up, verify health, counts and that one known record exists (a count or yes/no, never the row), and report the sizes.

## Never

No backup or dump leaves the cluster to a laptop; no dump content is printed (it holds values).

Then the changelog entry and the matching `operations` page (skill `wiki-changelog`).
