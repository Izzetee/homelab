variable "name" {
  type        = string
  description = "VM name (the host name of the node)."
}

variable "vm_id" {
  type        = number
  description = "Proxmox VMID, 220 to 229."
}

variable "node_name" {
  type        = string
  description = "Proxmox node that runs the VM."
}

variable "cores" {
  type        = number
  description = "Number of vCPUs."
}

variable "memory_mib" {
  type        = number
  description = "Memory in MiB. The module cannot see host capacity: the operator's pre-apply step checks it."
}

variable "disk_gb" {
  type        = number
  description = "Size of the system disk in GiB."
}

variable "mac_address" {
  type        = string
  description = "Fixed MAC address of the network device (the DHCP reservation is keyed by it)."
}

variable "import_from" {
  type        = string
  description = "Volume ID of the verified disk image to import, <storage>:import/<file>.qcow2."
}

variable "ssh_public_key" {
  type        = string
  description = "Public key that the first-boot configuration installs for the admin user. A public key, no credential."
}

variable "started" {
  type        = bool
  default     = true
  description = "Whether the VM runs."
}
