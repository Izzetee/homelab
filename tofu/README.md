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
