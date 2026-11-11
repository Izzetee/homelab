# apps

One directory per application, each a kustomization or a Helm values set that ArgoCD
syncs from `main`.

Conventions:

- Images are pinned `tag@digest` and available for `linux/amd64` and `linux/arm64`, or the
  pod is pinned to one architecture with a `kubernetes.io/arch` node selector.
- Secrets are `ExternalSecret` references by key name, never values.
- `kustomize build <dir> | kubeconform -strict` passes locally and in CI.

`_example/` is a smoke test for CI and Renovate and is removed as soon as the first real
application lands.
