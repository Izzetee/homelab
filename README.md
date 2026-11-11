# homelab

My homelab for hosting and learning, defined as code: Proxmox virtual machines with
OpenTofu, a K3s cluster with k3s-ansible, Cilium networking, ArgoCD GitOps for the
applications, and Renovate for dependency updates.

The repository is public. It holds **no secret value**: not in files, not in history, not
in examples. Secrets are referenced by name only (`ExternalSecret`); the rules for
contributors and agents are in [AGENTS.md](AGENTS.md).

## Layout

The directories appear step by step as the cluster is built:

```text
ansible/       k3s-ansible requirements and playbooks (inputs only from the environment)
tofu/          OpenTofu: VM module and environments (state never lives here)
apps/          one directory per application, ArgoCD manifests
networking/    Cilium pools and network policies
docs/          architecture and runbooks
ci/            helper scripts of the CI workflow
.github/       CI workflow (GitHub-hosted runners only)
```

## Checks

Every pull request runs the CI workflow: secret scan (default rules plus a rule for
secret-named keys with literal values and for ciphertext), YAML and workflow linting,
manifest validation (`kustomize`, `kubeconform`, `helm template`), image digest and
architecture checks, `ansible-lint` and `tofu validate`. One aggregate check, `ci-ok`, gates
the merge into `main`.

## License

Apache-2.0, see [LICENSE](LICENSE).
