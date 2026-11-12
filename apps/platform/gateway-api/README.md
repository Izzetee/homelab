# Gateway API CRDs

The standard-channel CRDs and the safe-upgrades admission policy of Gateway API v1.6.3, read by ArgoCD straight from
the upstream repository at the commit of that release tag (`config/crd/standard`, the same files the release manifest
`standard-install.yaml` is built from). The cluster bootstrap applies the release manifest (checked against its sha256)
before ArgoCD exists; ArgoCD takes over the same version without a diff.

The Application is `apps/_argocd/gateway-api.yaml`. A version change moves the commit there and the release URL and
checksum in `ansible/cilium.yml` together.
