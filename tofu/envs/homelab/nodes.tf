locals {
  # verified disk image on the import storage (the storage name is part of the volume ID the import needs)
  image_volume = "poecki-vault-2:import/ubuntu-26.04-server-cloudimg-amd64-20261016.qcow2"

  # One row per cluster node. The same rows (without `enabled`) are kept in the operator's node
  # file, and the apply wrapper refuses a plan that differs from it. All three nodes are enabled;
  # an agent's memory is the host headroom left after the other guests (at least 6 GiB).
  # Sizes follow the measured peaks (no VM below twice its peak). A disk only grows; memory and cores of a running
  # VM change after its next power cycle (see ../../README.md, Capacity).
  nodes = {
    "k3s-server-1" = {
      enabled     = true
      vm_id       = 220
      node_name   = "proxmox2"
      cores       = 6
      memory_mib  = 10240
      disk_gb     = 64
      mac_address = "BC:24:11:C4:4D:2F"
    }
    "k3s-agent-1" = {
      enabled     = true
      vm_id       = 221
      node_name   = "proxmox2"
      cores       = 6
      memory_mib  = 16384
      disk_gb     = 200
      mac_address = "BC:24:11:4F:A8:47"
    }
    "k3s-agent-2" = {
      enabled     = true
      vm_id       = 222
      node_name   = "proxmox"
      cores       = 4
      memory_mib  = 24576
      disk_gb     = 48
      mac_address = "BC:24:11:05:53:26"
    }
  }
}
