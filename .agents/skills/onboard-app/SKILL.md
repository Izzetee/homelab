---
name: onboard-app
description: Onboard a new application into the cluster by one pull request that the owner merges: image pin, namespace, AppProject destination, Application, default-deny network policy, store values, LAN name, optional public test name. Use when asked to deploy a new third-party or dev project.
---

# onboard-app

One pull request, merged by the owner (a new application is never agent-merged). Prepare it completely; do not merge it.

## Steps

1. **Image**: `name:tag@sha256:<digest>` and both platforms (`docker buildx imagetools inspect`). A single-architecture image needs a
   `kubernetes.io/arch` node selector and a one-line reason in the manifest.
2. **Namespace** in `networking/namespaces.yaml` with the label `pod-security.kubernetes.io/enforce: restricted`. No `homelab.io/public` label: the
   owner adds it together with an Access application (step 8).
3. **AppProject**: add the namespace as a destination of project `apps` (no secrets) or `apps-store` (reads secrets from the store) in
   `apps/platform/argocd/project.yaml`.
4. **Application** `apps/_argocd/<app>.yaml` (project `apps` or `apps-store`, source path `apps/tools/<app>`, `automated` sync with `selfHeal`, no prune
   of stateful data). Copy a neighbour of the same kind.
5. **Directory** `apps/tools/<app>/`: Deployment or StatefulSet (restricted pod security: non-root, read-only root file system, dropped
   capabilities, resource requests), Service, a `kustomization.yaml`, and a `default-deny` CiliumNetworkPolicy that allows DNS and exactly the
   flows the app needs. Probes on every container.
6. **Secrets** (skill `secrets`): a generated value is created with `homelab-bao put-generated <app> <name> <key>` at `secret/apps/<app>/<name>`
   before the PR; the app reads it through an `ExternalSecret` (`secretStoreRef`: `ClusterSecretStore` `openbao`, key `apps/<app>/<name>`). Add the namespace to the
   conditions of the `ClusterSecretStore` and to `apps/platform/openbao/config/namespaces.txt`. A value only the owner has is entered with
   `put-entered` by the owner at a terminal; ask.
7. **Route**: an `HTTPRoute` for `<app>.lan.chill-town.de` on the `lan` listener (`sectionName: lan`), exact hostname.
8. **Public test name** (only when asked): run `homelab-bao run cloudflare-dns,cloudflare-access -- tools/cf-access.sh <host>` first (it creates the
   Access application `k3s-access-<host>`); only then the owner opts the route in (`homelab.io/public-dns` annotation, namespace label). Verify an
   unauthenticated request gets 302 or 403.
9. **Stateful apps**: a CNPG `Cluster` with `local-path` storage plus a dump CronJob that follows the pattern of the existing apps (non-empty dump, sha256, count); a restore drill is part of the
   acceptance (skill `backup-restore`).

## Verify

`kustomize build apps/tools/<app> | kubeconform -strict`, the image check, `homelab-door --dry-run <branch>`. After the owner's merge: the Application is
`Synced` and `Healthy`, the LAN name answers 200, the `ExternalSecret` is `SecretSynced`, `kubectl get secret` shows the key name only (never the value).

## Rollback

Revert the pull request (the owner merges it). The store value stays as a create-only value; removing it is the owner's.

Then write the changelog entry (skill `wiki-changelog`).
