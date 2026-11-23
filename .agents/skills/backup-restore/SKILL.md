---
name: backup-restore
description: Take a manual backup of a stateful application, prove a dump, run a restore drill in the operations tooling, and know when a production restore needs the owner. Use before risky changes to stateful apps and when asked to test a restore.
---

# backup-restore

## Manual backup

Create a Job from the app's dump CronJob: `kubectl -n <ns> create job --from=cronjob/<name> <name>-manual-<UTC>` and wait for `Complete`. Check the set it wrote: the dump is
non-empty, its sha256 file exists, the count matches the app. A failed or empty set is a stop. Where the sets are copied and how long they are
kept is the owner's: ask when needed.

## Restore drill (safe)

The drill runs off the cluster in the operations tooling: the set the manual backup just wrote is restored into a scratch database without network, and the tooling compares the
restored tables with the live database. Ask for it as one named step of the go, on that set, and record its result line (the set, the tables restored and the live count). A result that does not name the fresh set proves nothing. Never create a scratch namespace in the cluster and never point a scratch database at production data stores or the production secret path.

## Production restore

Only with the owner's go for that exact restore. Scale the app to zero first, restore, scale up, verify health, counts and that one known record exists (a count or yes/no, never the row), and report the sizes.

## Never

No backup or dump leaves the cluster to a laptop; no dump content is printed (it holds values).

Then the changelog entry and the matching `operations` page (skill `wiki-changelog`).
