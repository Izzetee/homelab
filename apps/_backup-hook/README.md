# Backup hook components (source only)

The components `single` and `affine` carry one local-config object, `BackupHookSource`, per application. It is never rendered. Its name,
namespace and pod template are copied from the application's backup CronJob by the replacements of `kustomization.yml`; the restore check
(`apps/_restore-check`) reads the CronJob's image, node selector, claim and user from it. List the component before `_restore-check/pg` or
`_restore-check/sqlite` in the application's `kustomization.yaml`. `affine` names its source CronJob because that directory holds a second
CronJob; the two components differ in nothing else.

This stage installs no hook Job, no ServiceAccount, no grant and no admission resource. A later change can add a Job to the same component.

## Hook mode of the producers

The backup scripts of the eight applications pick their mode from the pod name: `-presync-` hook mode, `-manual-` a manual copy
(`create job --from=cronjob/<name>`), neither a scheduled run. Every mode takes one `flock` on one plain file of the claim root before its
first set write or listing, and keeps it until it exits; a run that cannot get the lock in time exits 75. Hook mode refuses to run (exit 76,
nothing written) when its deadline plus a margin could reach the reserved window; it writes into `.presync/` of the claim. Every run
fails before it writes when an entry of its set name already exists, and a failed run removes only its own files. Pruning and the
termination message (the bare set name) come after the whole set is written and checked; a manual run never prunes.

## Self-test

Offline, needs `kustomize`, `yq`, `python3`, `dash`, `bash`: `python3 tools/backup-hooks/selftest.py` (`--only <cronjob>` limits the
runtime part). It renders the eight applications (no hook object, eight restore checks with a deny-only policy), compares the rendered
CronJob with its file, checks the lock order, and runs the scripts in hook, manual and scheduled mode against synthetic data with real file
locks from separate processes; the hook-mode pod is the CronJob's template with a `-presync-` pod name. It does not use the pinned images.
`python3 tools/restore-check/test.py static host` covers the restore checks (`engine` needs a local docker daemon).

## Restore check result

The restore container's termination message names the selected set of each class and one row total per class, for example
`nightly=<set> presync=<set|none> rows-nightly=<n> rows-presync=<n|none>`, readable without a log grant. The total counts database rows
(all user tables for PostgreSQL, the listed tables for SQLite); file, sidecar and asset counts are in the log lines only. A failed run's message is `FAIL <phase> <class>`. The producers'
termination message stays the bare set name.
