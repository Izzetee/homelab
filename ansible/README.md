# ansible

Playbooks and roles that prepare the nodes, install K3s with the
[k3s-ansible](https://github.com/k3s-io/k3s-ansible) collection (pinned in `requirements.yml`) and hand the
cluster to ArgoCD.

Install the requirements once per workstation:

```sh
ansible-galaxy collection install -r ansible/requirements.yml
```

| Playbook | What it does | Secret input (environment only) |
|---|---|---|
| `node-prep.yml` | packages, sshd drop-in, inotify sysctls, the Pod Security admission file on the server | none |
| `k3s-cluster.yml` | pinned add-on manifests, token drop-in, K3s via k3s-ansible, token-file and kubeconfig checks | `K3S_TOKEN` |
| `cilium.yml` | Gateway API CRDs (checksum) and the pinned Cilium chart with `apps/platform/cilium/values.yaml` | none |
| `secret-bootstrap.yml` | the seal key Secret of the secret store (one server-side apply, guarded against a different live value), value on a file descriptor of `kubectl` | `OPENBAO_SEAL_KEY` |
| `argocd-bootstrap.yml` | ArgoCD from its pinned chart, the AppProject `platform` and the root app | none |

The agents are in their own inventory group, so the first `k3s-cluster` run is limited to the server
(`--limit server`).

`files/k3s-addons/` and `k3s-images.lock` hold the K3s bundled add-ons (CoreDNS, local-path provisioner, metrics-server)
and the pause image, every image pinned by digest; they are generated for the pinned K3s version and refreshed
together with every K3s version change. K3s applies the add-on files from its auto-deploy directory, which the
`k3s-cluster` play fills before K3s starts for the first time.

Rules:

- Secret inputs (for example the cluster join token) come only from the environment
  (`lookup('env', ...)`) or from files outside this repository, never from inventory
  variables. Plays that handle a secret use `no_log` and are never run with `--diff` or `-v`.
- The inventory holds hostnames, groups and non-secret switches only.
- Every change passes `ansible-lint` in CI.
