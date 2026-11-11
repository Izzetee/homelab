# AGENTS.md

Rules for everyone who changes this repository, people and agents alike.

## What this repository is

The public, complete definition of the homelab: Ansible (k3s-ansible), OpenTofu for
Proxmox virtual machines, ArgoCD applications, networking and docs. Applies (OpenTofu,
Ansible) run from a private operations repository against a pinned commit of this one;
ArgoCD reads `main`. Nothing here pushes into the cluster.

## Hard rules

1. **No secret values, no ciphertext.** Not in files, commit messages, branch names, pull
   request text or comments, and not in examples. No SOPS, age or sealed-secret blobs, no
   kubeconfigs, no OpenTofu state or `*.tfvars`, no raw inventory data, no backups.
2. **Secrets by reference only.** Kubernetes secrets are `ExternalSecret` (and
   `ClusterSecretStore`) references by key name. Secret inputs to Ansible and OpenTofu come
   only from the environment or from files outside the repository.
3. **Images are pinned `tag@digest`** and multi-arch (`linux/amd64` and `linux/arm64`),
   unless the workload is pinned to one architecture on purpose with a `kubernetes.io/arch`
   node selector. CI checks both.
4. **Changes go in by pull request only.** Merges are API **rebase** merges after the
   required check `ci-ok` is green. Never use the GitHub UI merge, revert, "Update branch",
   web edit or web conflict resolution buttons: they create commits with identities the
   history must not contain.
5. **GitHub-hosted runners only.** Never register a **self-hosted** runner, never add
   Actions secrets, variables, environments or deploy keys, never use `pull_request_target`
   or `workflow_run`, never upload artifacts or use caches (both are public here).
6. **Never bypass push protection**, never use `--no-verify`, never rewrite the history of
   `main`.
7. **A leaked value is public.** Rotate it at its source first; only then close the pull
   request, delete the branch and clean up. Rewriting history does not remove it.
8. **Public text rule.** Files, commit messages, branch names, pull request titles and
   bodies, and comments must not name private repositories, ticket or decision IDs, internal
   network ranges, personal email addresses other than the commit identities, or describe
   the security posture of the lab (apps without login, exposure findings, how access and
   credentials are handled, backup locations or schedules).

## Conventions

- Workflows: `permissions: {}` on top, `contents: read` per job, actions pinned to a full
  commit SHA, tools run from images pinned by digest, no `${{ github.event.* }}` inside
  `run:` (pass values through `env:`). Changes to `.github/`, `ci/`, `.gitleaks.toml`,
  `renovate.json` and `CODEOWNERS` are guardrail changes and need the owner's approval.
- Renovate opens the dependency pull requests; it never merges guardrail files, Ansible
  collections or OpenTofu providers automatically.
- One directory per application under `apps/`; keep manifests small and validated by
  `kustomize build | kubeconform -strict`.

## Layout

See [README.md](README.md). `ansible/`, `tofu/`, `apps/`, `networking/` and `docs/` are
added by pull requests; `ci/` holds the helper scripts of the CI workflow.
