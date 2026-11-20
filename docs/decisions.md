# Decisions

One line each: what was decided and why.

- **GitOps with ArgoCD**: one app-of-apps from `main`, automated sync with self-heal. Why: the repository is the single description of the cluster.
- **CI on GitHub-hosted runners only**: no self-hosted runner on a public repository. Why: a fork pull request could otherwise run code on the LAN.
- **K3s via k3s-ansible, nodes by OpenTofu**: flannel, kube-proxy, servicelb, traefik and the network-policy controller are disabled, secrets encryption on. Why: Cilium and the Gateway replace those parts.
- **Cilium as CNI** with kube-proxy replacement and L2 announcements. Why: one component for networking, policies and the gateway on a single LAN.
- **Gateway API, no ingress controller**: apps authenticate through their own OIDC. Why: the Gateway API is native to Cilium; there is no forward-auth, so identity lives in the app.
- **Exposure model**: public through one Cloudflare Tunnel to the `tunnel` listener of its own gateway, LAN names through DNS records for a wildcard zone and a DNS-01 wildcard certificate, admin UIs LAN-only. Why: no router port forwards and one place to judge exposure.
- **External Secrets with OpenBao**: references in Git, values in the store, Kubernetes auth for the operator. Why: nothing secret in a public history, no long-lived store token in the cluster.
- **Authentik for identity** with blueprints for the OIDC clients. Why: users and groups already exist there; clients are declared as code.
- **Storage**: CloudNativePG on node-local storage with dumps, bulk data on NFS, SQLite apps with file backups; no database files on NFS. Why: databases need local latency and a restore path that does not depend on the NAS.
- **Observability stack**: Prometheus, Loki, Tempo, Alloy, a stateless Grafana. Why: dashboards and alerts are code, nothing to restore.
- **Raspberry Pis are agents** with a node-class label and taint; images are multi-arch or pinned to one architecture. Why: mixed architecture must be explicit.
- **Renovate** for images, charts, collections and providers, no automerge of guardrail files, collections or providers. Why: reviewable updates without a self-hosted updater.
- **Garage as the S3 store**: one node, keys created in the secret store first. Why: small footprint, native metrics, keys importable from the store.
- **Publishing through one door** that checks every push and merges only inside one application directory; the owner merges everything else. Why: an agent's mistake or an injected instruction must not reach the platform.
