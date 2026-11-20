# Architecture

A small K3s cluster managed as code. This page names the parts and how they fit; `decisions.md` has the reasons, `lessons.md` the technical lessons.

- **Nodes**: Ubuntu VMs on two Proxmox hosts (created by OpenTofu from a pinned cloud image, only in the pool for this cluster) and Raspberry Pi agents. K3s is installed
  and upgraded with k3s-ansible. One server with embedded etcd; the control plane can grow later.
- **Networking**: Cilium (kube-proxy replacement, load-balancer address pool announced on the LAN, network policies). The Gateway API replaces an ingress controller: a `Gateway`
  with a `lan` listener (wildcard certificate for the LAN names) and a second `Gateway` for the tunnel, with one plain-HTTP listener that only namespaces labelled public may attach to.
- **Exposure**: public names go through a Cloudflare Tunnel; LAN names are plain DNS records below the LAN zone. Admin interfaces are LAN-only. Public test names need an Access application first.
- **GitOps**: ArgoCD syncs an app-of-apps from `main`; projects limit what each group of applications may create. Renovate opens dependency updates; CI runs on GitHub-hosted runners only.
- **Secrets**: External Secrets Operator reads a self-hosted OpenBao through a `ClusterSecretStore`; manifests hold only references. Agents and the owner reach the store through a short-lived login and a helper.
- **Identity**: Authentik; applications use OIDC (declared as blueprints) and the store has an OIDC login for the tools.
- **Data**: CloudNativePG on node-local storage with dump jobs; SQLite apps with file backups; an S3 object store (Garage) for consumers that need one.
- **Observability**: Prometheus, Loki, Tempo, Alloy and a stateless Grafana (dashboards as code).
- **Applications** live in `apps/tools/<app>/`; platform, identity and observability in their own directories.

Tools for working here are in `tools/` and described by the skills in `.agents/skills/`.
