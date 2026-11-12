variable "ssh_public_key" {
  type        = string
  description = "Public key the first-boot configuration installs for the admin user (TF_VAR_ssh_public_key)."
}

module "vm" {
  source   = "../../modules/vm"
  for_each = { for name, n in local.nodes : name => n if n.enabled }

  name           = each.key
  vm_id          = each.value.vm_id
  node_name      = each.value.node_name
  cores          = each.value.cores
  memory_mib     = each.value.memory_mib
  disk_gb        = each.value.disk_gb
  mac_address    = each.value.mac_address
  import_from    = local.image_volume
  ssh_public_key = var.ssh_public_key
}
