terraform {
  required_version = "1.13.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.121.0"
    }
  }
}
