---
name: change-app
description: Change an existing application inside its own directory under apps/tools and merge it yourself after CI. Use for config, replicas, resources, probes, routes of the same app. Not for new applications or anything outside the directory.
---

# change-app

Allowed on your own merge: every changed path lies inside `apps/tools/<app>/` of one application that already exists with its Application. Anything else
(Application, project, namespace, store conditions, platform, networking, docs, tools) is prepared as a pull request for the owner.

## Steps

1. Edit only files inside `apps/tools/<app>/`. A new hostname other than the app's own `<app>.lan.chill-town.de` needs the owner. An `ExternalSecret` reads only
   the app's own namespace path or `apps/<app>/...`.
2. Stateful change (database, volume, schema, image with a migration): take a manual backup first (skill `backup-restore`).
3. `kustomize build apps/tools/<app> | kubeconform -strict` and the image check.
4. Branch, commit, `homelab-door --dry-run <branch>`, then `homelab-door <branch>`, `homelab-door pr <branch> <title-file> <body-file>`.
5. After `ci-ok` is green: `homelab-door merge <n> --expect-head <reviewed sha> --dry-run`, then the same without `--dry-run`. If it prints `FAIL merge <n> owner`, the change is outside the allowlist: tell the owner and wait.
6. Watch ArgoCD: the Application is `Synced`/`Healthy`, `kubectl rollout status` finishes, the app answers.

## Rollback

A revert pull request (inside the directory it is merged by the rule of step 5: `homelab-door merge <n> --expect-head <reviewed sha>`; a revert the owner's go covers follows skill `publish`). For a stateful change restore from the backup of step 2 only with the owner's go.

Then the changelog entry (skill `wiki-changelog`); a door merge prints `NEXT changelog homelab#<n>`.
