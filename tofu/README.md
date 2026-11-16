# tofu

OpenTofu definitions of the virtual machines that run on the Proxmox hosts.

- `modules/vm/` is the VM module (contract in its README).
- `envs/homelab/` is the environment that instantiates the modules. `versions.tf` pins
  OpenTofu and the `bpg/proxmox` provider exactly; `.terraform.lock.hcl` pins the provider
  hashes for `linux_amd64`, `linux_arm64` and `darwin_arm64`.

Rules:

- No provider credentials, state, backend block or `*.tfvars` in this repository.
  Credentials come from environment variables, the state lives on the host that applies it.
- `tofu fmt -check -recursive` and `tofu validate` (with `-backend=false`) run in CI.
- Plans and applies are run by an operator from outside this repository.
- The operator's apply wrapper accepts under `tofu/` only regular `*.tf` files, the lock file and
  documentation, and the provider configuration only in `envs/homelab/provider.tf` (it replaces that
  file with the same empty block). The words that start a provider, backend or cloud block therefore
  appear in no other `.tf` file, comments included; a `source` is a local path or the pinned provider.

## Capacity

| Host | CPU threads | RAM | Thin pool `local-lvm` |
|---|---|---|---|
| `proxmox` | 4 | 30 GiB | about 55 GiB |
| `proxmox2` | 12 | 62 GiB | about 794 GiB |

Rules the operator's apply wrapper and report check before a resize:

- Memory: the guests that run on a host (also those outside the cluster range) plus a reserve of
  `max(4 GiB, 10 % of the host)` must fit into the host's RAM. Memory is the scarce resource; vCPUs may exceed
  the host's threads while the load stays low.
- Disk: the thin pool's data use stays below 80 %, and the virtual sizes of all volumes on a pool add up to at most
  90 % of the pool, so a full guest filesystem can never fill the pool.
  <!-- shortcut: the 90 % rule is read from the report, not enforced in code; upgrade when a pool is shared by several VMs -->

How a resize runs: change the row in `envs/homelab/nodes.tf` and the operator's node file, plan, apply. A disk only
grows (never shrinks) and is then grown inside the guest while it runs. Memory and cores of a running VM have no
hotplug: Proxmox keeps them pending until the VM is power-cycled, so each node is cordoned, drained, rebooted through
Proxmox and uncordoned, one node at a time, with the pending memory re-checked against the host first.
