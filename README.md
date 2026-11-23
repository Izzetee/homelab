# homelab

> A small, opinionated platform for self-hosted apps — Kubernetes on bare metal and Proxmox, run entirely through Git,
> operated by humans and AI agents with one rule: **nothing changes outside a reviewed pull request.**

[![ci](https://github.com/Izzetee/homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/Izzetee/homelab/actions/workflows/ci.yml)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-ef7b4d)
![K3s](https://img.shields.io/badge/K3s-multi--arch-ffc61c)
![Cilium](https://img.shields.io/badge/CNI-Cilium-8061a9)
![Renovate](https://img.shields.io/badge/deps-Renovate-1a1f6c)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

## What this is

The complete, declarative description of a homelab: virtual machines, the Kubernetes cluster on them, every platform
component and every application. The repository is the single source of truth — a merge to `main` is a deployment.

```text
 commit ─▶ pull request ─▶ CI gates (ci-ok) ─▶ merge to main ─▶ ArgoCD sync ─▶ cluster
                 ▲                                                             │
                 └──────── Renovate opens update PRs ◀── registries / charts ◀─┘
```

The repository is **public and holds no secret value** — not in files, not in history, not in examples. Secrets are
referenced by name only and materialised in the cluster by the External Secrets Operator from OpenBao.

## Stack

| Layer | Building blocks |
|---|---|
| **Compute** | Proxmox VE VMs provisioned with **OpenTofu**, Raspberry Pi 4 nodes — one **K3s** cluster, mixed `amd64` / `arm64` |
| **Bootstrap** | **k3s-ansible** + own roles (node prep, labels, taints); everything after the first boot is GitOps |
| **Networking** | **Cilium** (eBPF, L2 announcements, LB IPAM, `CiliumNetworkPolicy` default-deny), **Gateway API** with Cilium's gateway, **Hubble** |
| **Edge** | **cert-manager** (DNS-01), **external-dns**, **cloudflared** tunnel, **Blocky** as LAN resolver |
| **GitOps** | **ArgoCD** app-of-apps, AppProjects per tier, sync waves |
| **Identity** | **Authentik** (OIDC/SSO for every app with a login), configured as code with blueprints |
| **Secrets** | **OpenBao** (Raft, HA) + **External Secrets Operator**; only names in Git |
| **Data** | **CloudNativePG** (PostgreSQL 18), **Garage** (S3), NFS CSI, local-path for databases |
| **Observability** | **kube-prometheus-stack**, **Loki** + **Alloy**, **Tempo**, blackbox and SNMP exporters, alerts to chat |
| **Supply chain** | **Renovate** (classes, minimum release age, automerge only for low-risk updates), images pinned `tag@digest`, multi-arch checks |

## Repository layout

```text
.
├── apps/
│   ├── _argocd/         ArgoCD Applications and AppProjects (app-of-apps root)
│   ├── platform/        cluster services: cilium, gateway, argocd, cert-manager, openbao, external-secrets,
│   │                    cloudnative-pg, garage, blocky, cloudflared, external-dns, hubble-ui, storage, …
│   ├── identity/        authentik and its database
│   ├── observability/   prometheus stack, loki, alloy, tempo, exporters, rules and dashboards
│   └── tools/           user-facing apps, one directory each (manifests, network policy, backup job, README)
├── networking/          LB pools, L2 announcement policy, cluster-wide network policies
├── ansible/             k3s-ansible inputs and node roles (values only from the environment)
├── tofu/                VM module and environments (state never lives here)
├── docs/                architecture notes, decisions, lessons learned, runbooks
├── tools/               operator and agent tooling: store helper, publishing door, Access tool, changelog
├── .agents/skills/      agent skills (Agent Skills format): onboard-app, change-app, bump-image, backup-restore, …
├── ci/                  CI helper scripts (render, newest-release check, image checks)
└── .github/workflows/   one CI workflow on GitHub-hosted runners
```

Every application under `apps/tools/<app>/` follows the same contract: pinned multi-arch images, restricted Pod
Security, a default-deny network policy, a `README.md`, and — for stateful apps — a database or volume backup job with
a restore path.

## Quality gates

Every pull request runs one workflow; a single aggregate check, **`ci-ok`**, gates the merge:

- secret scanning (gitleaks with custom rules for secret-named keys, literal values and ciphertext) — also on history
- YAML and workflow linting (`yamllint`, `actionlint`)
- manifest rendering and validation (`kustomize build`, `helm template`, `kubeconform -strict` with CRD schemas)
- image checks: digest pinned, every architecture present, newest stable release for new pins
- `ansible-lint`, `tofu fmt` / `tofu validate`

Branch protection: linear history, no force pushes, merges only with a green `ci-ok`.

## How changes are made

Most changes are prepared by an **agent team** (planner, implementer, reviewers, verifier) working from the skills in
[`.agents/skills/`](.agents/skills/) and the rules in [`AGENTS.md`](AGENTS.md):

1. plan → independent review → implementation in a branch
2. publication through the **door** (`tools/door`): text rules, secret scan and identity checks before every push
3. one owner go per change, naming each pull request by number and reviewed head commit
4. merge only at that head; ArgoCD rolls it out; the change is recorded in a changelog

Routine dependency updates flow through Renovate; low-risk classes merge automatically after their minimum release
age, everything else goes through the same review path.

## Docs

| Where | What |
|---|---|
| [`AGENTS.md`](AGENTS.md) | the rules for every contributor and agent — start here |
| [`docs/README.md`](docs/README.md) | architecture overview and runbook index |
| [`docs/decisions.md`](docs/decisions.md) | decisions and their reasons |
| [`docs/lessons.md`](docs/lessons.md) | what broke and what we learned |
| `apps/**/README.md` | per-component notes |

## License

[Apache-2.0](LICENSE)
