# Architecture

How the pieces fit together.

```text
OpenTofu ──► Proxmox VMs ──► k3s-ansible ──► K3s cluster ──► ArgoCD ──► applications
                                            │
                                            ├── Cilium: pod network, load balancer, Gateway API
                                            ├── cert-manager: certificates
                                            ├── External Secrets: secrets from an external store
                                            ├── CloudNativePG: PostgreSQL clusters
                                            └── Grafana, Mimir, Loki, Tempo, Alloy: observability
```

- **Provisioning.** OpenTofu creates the virtual machines on the Proxmox hosts; Ansible
  prepares the nodes and installs K3s with the k3s-ansible collection. Single-board
  computers join as agents for stateless workloads.
- **Delivery.** ArgoCD syncs an app-of-apps from `main`. Every application is a directory
  under `apps/`.
- **Secrets.** The repository holds references only (`ExternalSecret`); values live in an
  external secret store and never in Git.
- **Dependencies.** Renovate proposes updates of images, charts, Ansible collections,
  OpenTofu providers and GitHub Actions through pull requests; CI gates every change.

Runbooks (upgrades, restores, disaster recovery) are added with the components they cover.
