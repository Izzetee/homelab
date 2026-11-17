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
| `node-prep.yml` | packages, sshd drop-in, inotify sysctls, the default container AppArmor profile (with the stacked-label peer rules), the Pod Security admission file on the server | none |
| `k3s-cluster.yml` | pinned add-on manifests, token drop-in, K3s via k3s-ansible, token-file and kubeconfig checks | `K3S_TOKEN` |
| `cilium.yml` | Gateway API CRDs (checksum) and the pinned Cilium chart with `apps/platform/cilium/values.yaml` | none |
| `secret-bootstrap.yml` | the seal key Secret of the secret store (one server-side apply, guarded against a different live value), value on a file descriptor of `kubectl` | `OPENBAO_SEAL_KEY` |
| `argocd-bootstrap.yml` | ArgoCD from its pinned chart, the AppProject `platform` and the root app | none |

The agents are in their own inventory group, so the first `k3s-cluster` run is limited to the server
(`--limit server`). The Raspberry Pi agents (arm64) are the group `pi` inside `agent`: they register with the label
`homelab.io/node-class=pi` and the taint `homelab.io/pi=true:NoSchedule` (`pi4-4` also carries `homelab.io/link=wifi`),
and run with their own `--limit <host>`; the arm64 K3s binary has its own pinned checksum.

K3s upgrade: `node-prep` stops while `node_prep_cri_apparmor_k3s_version` differs from `k3s_version`. Compare `contrib/apparmor/template.go` of the new
containerd (`k3s-io/containerd`, tag of the new K3s) with `roles/node-prep/templates/cri-containerd.apparmor.d.j2`, re-render the file and move the pin; once
the containerd of K3s carries the stacked-peer rules itself (containerd pull request 14487), remove the template, the task, the handler and the variables. That does not touch the nodes: the installed profile file and the loaded profile stay
(the file is loaded at every boot) until someone removes the file on each node as a deliberate, separately approved step and reboots it, after which containerd
generates its own.

Reboot a new node once after it joined and check from a host outside the cluster that every load balancer address answers; some settings take effect only at the first reboot.

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
