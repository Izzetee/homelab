# apps

One directory per application, each a kustomization or a Helm values set that ArgoCD
syncs from `main`.

Conventions:

- Images are pinned `tag@digest` and available for `linux/amd64` and `linux/arm64`, or the
  pod is pinned to one architecture with a `kubernetes.io/arch` node selector.
- Secrets are `ExternalSecret` references by key name, never values.
- `kustomize build <dir> | kubeconform -strict` passes locally and in CI.

Layout:

- `root.yaml` is the root app-of-apps. It deploys the Applications in `_argocd/` (one file each, ordered by
  `argocd.argoproj.io/sync-wave`: -3 Gateway API CRDs, -2 Cilium, -1 cert-manager, csi-driver-nfs, CloudNativePG and the
  storage classes, 0 load balancer pool and L2 policy, certificate issuers and the gateway, 1 cloudflared and ArgoCD itself).
  The Application health check in `platform/argocd/values.yaml` makes the root wait for a wave before it creates the next.
- `platform/<name>/` holds the values file of a chart, or the manifests of an application that is not a chart.
- The load balancer pool and the L2 policy live in `../networking/`.
- Namespaces carry an explicit Pod Security `enforce` label: `restricted` everywhere (including `cilium-secrets`, which the Cilium chart creates and which holds no pod) except `csi-driver-nfs`
  (`privileged`: the node plugin mounts volumes through host paths) and `kube-system` (exempt cluster-wide: Cilium).
- Automated sync is added by a later pull request, after every Application was synced once by hand.

Removing the platform. The child Applications have no deletion finalizer, so deleting the root with a cascade or
without removes only the Application objects, never their workloads, and a child deleted without a cascade is left
behind with its objects. Work from the top while ArgoCD still runs:

1. `argocd app delete --core root --cascade=false`: the children stay.
2. Workload children, in reverse wave order, each with `argocd app delete --core <app> --cascade` and waiting until it is
   gone before the next: `cloudflared`; then `gateway`, `cert-manager-issuers`, `networking`; then `cert-manager`,
   `csi-driver-nfs`, `cloudnative-pg` (first make sure no Certificate, no PVC of the NFS class and no database cluster
   still depends on them).
3. Without a cascade (`--cascade=false`): `storage` (the StorageClasses and the `Retain` volumes stay), `gateway-api`
   and every CRD-only part (the CRDs stay), and `cilium` (it is the node network; removing it is part of resetting the
   nodes).
4. Only when every Application above is gone: `argocd app delete --core argocd --cascade=false`, then
   `helm uninstall argocd -n argocd` (the release is `argocd`, the chart `argo-cd`).
5. CRDs, StorageClasses, `Retain` volumes and their data stay until they are removed by hand, and only after no object of
   that kind is left.
