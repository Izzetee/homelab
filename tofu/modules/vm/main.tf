locals {
  pool_id      = "k3s"
  datastore_id = "local-lvm"
  admin_user   = "k3smig"
}

resource "proxmox_virtual_environment_vm" "this" {
  node_name   = var.node_name
  vm_id       = var.vm_id
  name        = var.name
  pool_id     = local.pool_id
  description = "K3s node, managed by OpenTofu"

  on_boot       = true
  started       = var.started
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  # destroy stops the guest (no guest agent) and leaves backup jobs alone; updates never reboot
  # the guest on their own
  stop_on_destroy     = true
  purge_on_destroy    = false
  reboot_after_update = false

  operating_system {
    type = "l26"
  }

  # the disk image has no guest agent
  agent {
    enabled = false
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory_mib
  }

  # the system disk is imported from the verified image and never part of a backup (cattle: Git
  # and etcd snapshots restore the cluster)
  disk {
    datastore_id = local.datastore_id
    interface    = "scsi0"
    import_from  = var.import_from
    size         = var.disk_gb
    file_format  = "raw"
    backup       = false
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = var.mac_address
    model       = "virtio"
    firewall    = false
  }

  # native first-boot configuration: no snippets, no credential
  initialization {
    datastore_id = local.datastore_id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = local.admin_user
      keys     = [var.ssh_public_key]
    }
  }

  serial_device {}

  lifecycle {
    # the pool is set when the VM is created; the API does not report it back, so the state reads it as
    # empty and every plan would show a change of the pool
    ignore_changes = [pool_id]

    precondition {
      condition     = var.vm_id != 100
      error_message = "VMID 100 is the Home Assistant VM and is never managed here."
    }
    precondition {
      condition     = var.vm_id >= 220 && var.vm_id <= 229
      error_message = "VMID must be in 220-229, the range of the K3s cluster."
    }
    precondition {
      condition     = lower(var.name) != "homeassistantos"
      error_message = "The name homeassistantos is refused."
    }
    precondition {
      condition     = local.pool_id == "k3s"
      error_message = "VMs of this module live only in pool k3s."
    }
    precondition {
      condition     = can(regex("^[a-z0-9-]+:import/[A-Za-z0-9._-]+[.]qcow2$", var.import_from))
      error_message = "import_from must name an import volume (<storage>:import/<file>.qcow2)."
    }
    precondition {
      condition     = can(regex("^BC:24:11(:[0-9A-F]{2}){3}$", var.mac_address))
      error_message = "mac_address must be an upper-case address in the Proxmox OUI BC:24:11."
    }
  }
}
