# vm module

Contract of the VM module:

- Creates one virtual machine (`proxmox_virtual_environment_vm`) from a verified cloud image in
  the fixed resource pool `k3s`. The pool is not a variable.
- The system disk is imported (`import_from`) onto `local-lvm` and has `backup = false`; there is
  no `clone`, `hostpci` or `usb` block. Cloud-init is native (user `k3smig`, the public key from a
  variable, DHCP); the guest agent is off because the image has none.
- Refuses at plan time (resource preconditions) VMID 100, any VMID outside 220-229, the name
  `homeassistantos` in any case, a malformed MAC or import volume. It never manages a guest
  outside the pool.
- Capacity is not checked here: the module cannot see what the hosts already allocate. The
  operator's pre-apply step checks RAM and storage against the plan before anything is applied.
- Takes no credentials as variables; provider authentication comes from the environment. The one
  secret-like input is the SSH public key, which is public.
- Destroy stops the guest and does not purge it from backup jobs (`purge_on_destroy = false`).
