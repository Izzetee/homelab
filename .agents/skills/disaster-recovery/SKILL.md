---
name: disaster-recovery
description: Recovery order and checks after losing nodes, the secret store or the cluster, and what only the owner can provide. Use when a node, the store or the control plane is gone or damaged. Reads and checks only; destructive or host-level steps are the owner's.
---

# disaster-recovery

Never act on a Proxmox host, VM 100 or a guest outside VMIDs 220-229. Recovery of nodes and of the cluster itself is run by the owner from the private operations tooling; your part is to read, check, and state what is missing.

## Order and checks

1. **Nodes**: all expected nodes `Ready` (`kubectl get nodes`); a Raspberry Pi node carries the class label and taint of its node class.
2. **K3s control plane**: the API answers; the etcd snapshots exist (ask the owner where).
3. **Cilium**: pods ready on every node, the gateway has its address and `Programmed`.
4. **ArgoCD**: the root Application and its children are `Synced`/`Healthy`.
5. **Secret store**: the three `openbao` pods are `Ready`, each labelled `openbao-initialized=true` and `openbao-sealed=false`, exactly one `openbao-active=true` (`kubectl -n openbao get pods -L openbao-initialized,openbao-sealed,openbao-active`); the `ClusterSecretStore` is `Ready`. With Prometheus up, `vault_core_unsealed` is 1 for three pods. Never exec into a store pod. Unseal and recovery material are the owner's.
6. **External Secrets**: every `ExternalSecret` is `SecretSynced`.
7. **Databases and apps**: CNPG clusters healthy, then the apps; verify each by checking that a known record exists, without printing it (skill `backup-restore`).
8. **LAN network**: every `cilium-l2announce-<namespace>.<service>` lease in `kube-system` of a Service with a load-balancer address (pools: `networking/lb-pool.yaml`) has a `Ready` node as holder and a `renewTime` under one minute old; a lease of a deleted Service is skipped. The LAN address probe metric `homelab_lan_vip_up` is 1 for every check and its last run is under 10 minutes old, and `HomelabLanVipDown` is not firing. From a LAN host outside the cluster the LAN resolver answers the blocklist canary name with `0.0.0.0` and a public name with an address. The resolver answers only after its lists load (up to three minutes after a cold start); clients use their second resolver until then, which is no failure.

## The store's CA

The store's internal CA certificate is also kept as a public ConfigMap (`apps/platform/openbao/ca-public.yaml`) for the route's backend check. When the CA is
renewed (about every ten years) that file is replaced by the same extraction; the owner does it.

## What needs the owner

Recovery material, snapshot locations, Proxmox or host work, any restore into production.
