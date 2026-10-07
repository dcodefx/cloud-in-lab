variable "efk_pools" {
  type = map(object({
    role              = string
    vm_name           = string
    vm_count          = number
    cpu_cores         = number
    vm_memory         = number
    disk_size         = number
    disk_storage      = string
    data_disk_enabled = bool
    data_disk_size    = number
    data_disk_storage = string
    ip_start_index    = number
  }))
  default = {}
}

module "efk_stack" {
  for_each = var.efk_pools
  source   = "../../modules/proxmox-vm"

  vm_name    = each.value.vm_name
  vm_role    = each.value.role
  vm_count   = each.value.vm_count
  cpu_cores  = each.value.cpu_cores
  vm_memory  = each.value.vm_memory
  disk_size  = each.value.disk_size
  disk_storage = each.value.disk_storage

  data_disk_enabled = each.value.data_disk_enabled
  data_disk_size    = each.value.data_disk_size
  data_disk_storage = each.value.data_disk_storage

  ip_start_index = each.value.ip_start_index

  environment    = var.environment
  target_node    = var.target_node
  template_vm_id = var.template_vm_id
  base_ip        = var.base_ip
  ip_mask        = var.ip_mask
  gateway        = var.gateway
  ssh_user       = var.ssh_user
  ssh_pub_key    = file(var.ssh_pub_key_path)
  enable_firewall = var.enable_firewall
}
