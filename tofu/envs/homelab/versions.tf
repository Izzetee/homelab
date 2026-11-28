terraform {
  required_version = "1.13.10"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.123.0"
    }
  }
}
