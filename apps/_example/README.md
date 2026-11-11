# _example

Smoke test for CI and Renovate: one kustomization with a Deployment of zero replicas that
runs a digest-pinned, multi-architecture image. CI renders it, validates the manifests and
checks the image digest and platforms; Renovate proposes updates of the tag and digest.

Removed as soon as the first real application lands.
