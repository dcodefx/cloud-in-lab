module "floci" {
  source = "../../modules/proxmox-vm"

  vm_count  = 1
  vm_name   = "floci"
  vm_role   = "floci"
  cpu_cores = var.cpu_cores
  vm_memory = var.vm_memory
  disk_size = var.disk_size

  environment    = var.environment
  target_node    = var.target_node
  template_vm_id = var.template_vm_id
  base_ip        = var.base_ip
  ip_mask        = var.ip_mask
  ip_start_index = var.ip_offset
  gateway        = var.gateway
  ssh_user       = var.ssh_user
  ssh_pub_key    = file(var.ssh_pub_key_path)
  enable_firewall = var.enable_firewall
}

resource "local_file" "inventory" {
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    hostname    = module.floci.vm_names[0]
    ip          = module.floci.vm_ips[0]
    ssh_user    = var.ssh_user
    ssh_key     = trimsuffix(var.ssh_pub_key_path, ".pub")
    environment = var.environment
  })
  filename        = "${path.module}/../../../ansible/inventory/floci.ini.generated"
  file_permission = "0600"
}
