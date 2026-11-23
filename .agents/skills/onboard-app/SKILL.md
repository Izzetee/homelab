---
name: onboard-app
description: Onboard a new application into the cluster by one pull request that merges only under the owner's go: image pin, namespace, AppProject destination, Application, default-deny network policy, store values, LAN name, optional public test name. Use when asked to deploy a new third-party or dev project.
---

# onboard-app

One pull request. A new application is not merged through the door's application allowlist: it merges only under the owner's go that names it as
`#<n> @ <40-hex reviewed head>` (skill `publish`). Prepare it completely and ask for that go.

## Steps

1. **Image**: `name:tag@sha256:<digest>` and both platforms (`docker buildx imagetools inspect`). A single-architecture image needs a
   `kubernetes.io/arch` node selector and a one-line reason in the manifest. **Version:** the newest stable release (no beta, next, release
   candidate or early-access line) unless the owner names a version; a chart pin follows the same rule. Run `ci/check-newest.sh origin/main`
   on the committed branch: every new pin needs its own `OK newest` line. A `FAIL`, a `WARN` or no line for a pin (Renovate does not read every
   pin) needs a recorded manual lookup (registry or chart index: newest stable and its date) or the owner's named version; say which in the PR.
2. **Namespace** in `networking/namespaces.yaml` with the label `pod-security.kubernetes.io/enforce: restricted`. No `homelab.io/public` label: the
   opt-in is its own line of the go, after the Access application exists (step 8).
3. **AppProject**: add the namespace as a destination of project `apps` (no secrets) or `apps-store` (reads secrets from the store) in
   `apps/platform/argocd/project.yaml`.
4. **Application** `apps/_argocd/<app>.yaml` (project `apps` or `apps-store`, source path `apps/tools/<app>`, `automated` sync with `selfHeal`, no prune
   of stateful data). Copy a neighbour of the same kind.
5. **Directory** `apps/tools/<app>/`: Deployment or StatefulSet (restricted pod security: non-root, read-only root file system, dropped
   capabilities, resource requests), Service, a `kustomization.yaml`, and a `default-deny` CiliumNetworkPolicy that allows DNS and exactly the
   flows the app needs. Probes on every container.
6. **Secrets** (skill `secrets`): a generated value is created with `homelab-bao put-generated <app> <name> <key>` at `secret/apps/<app>/<name>`
   after the owner's go and before the merge (not before the PR); the app reads it through an `ExternalSecret` (`secretStoreRef`: `ClusterSecretStore` `openbao`, key `apps/<app>/<name>`). Add the namespace to the
   conditions of the `ClusterSecretStore` and to `apps/platform/openbao/config/namespaces.txt`. A value only the owner has is entered with
   `put-entered` by the owner at a terminal; ask. An **object-storage bucket** (Garage): the key and the bucket are an entry in `apps/platform/garage/buckets.json` in this pull request; they are created by the
   operations tooling as a named step of the go after the merge (never from the pull request), and the app reads the key pair through an `ExternalSecret` like any other value.
7. **Route**: an `HTTPRoute` for `<app>.lan.chill-town.de` on the `lan` listener (`sectionName: lan`), exact hostname.
8. **Public test name** (only when asked): the Access application (the identity provider as its only login method, one group as the allow policy)
   is created first, as a named step of the go in the operations tooling (and verified there before the opt-in). Do not run `tools/cf-access.sh` for it. The opt-in (`homelab.io/public-dns` annotation, namespace label) is its own line of the go, `opt-in <host> in #<n> @ <40-hex reviewed head>`,
   merged only after the Access application exists. Verify an unauthenticated request gets 302 or 403.
9. **Stateful apps**: a CNPG `Cluster` with `local-path` storage plus a dump CronJob that follows the pattern of the existing apps (non-empty dump, sha256, count); a restore drill is part of the
   acceptance (skill `backup-restore`).

## Verify

`kustomize build apps/tools/<app> | kubeconform -strict`, the image check, `homelab-door --dry-run <branch>`. After the merge: the Application is
`Synced` and `Healthy`, the LAN name answers 200, the `ExternalSecret` is `Ready` (its status only; no value is read).

## Rollback

Revert the pull request. A pure `git revert` of exactly the commits the go merged is covered by that go (skill `publish`); any other rollback needs a new go. The store value stays as a create-only value; removing it is the owner's. Removing an app is skill `offboard-app`.

Then write the changelog entry (skill `wiki-changelog`).
