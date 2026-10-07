module "openbao" {
  source = "../../modules/proxmox-lxc"

  target_node        = var.target_node
  hostname           = "openbao"
  description        = "OpenBao Secret Management - Managed by OpenTofu - ${var.environment}"
  ct_id              = var.ct_id
  template_file_id    = var.template_file_id
  os_type            = "ubuntu"
  root_password      = var.root_password
  environment         = var.environment
  tags               = [var.environment, "openbao", "secret-management"]
  ssh_pub_key        = file(var.ssh_pub_key_path)

  lxc_count        = 1
  cpu_cores        = var.cpu_cores
  memory_dedicated = var.memory_dedicated
  memory_swap      = var.memory_swap
  disk_size        = var.disk_size

  base_ip         = var.base_ip
  ip_mask         = var.ip_mask
  ip_start_index  = var.ip_offset
  gateway         = var.gateway
  dns_server      = var.dns_server

  enable_firewall = true
  startup_order   = 1
  protection      = var.protection
}


resource "local_file" "inventory" {
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    hostname    = module.openbao.hostnames[0]
    ip          = module.openbao.ip_addresses[0]
    ssh_user    = var.ssh_user
    ssh_key     = trimsuffix(var.ssh_pub_key_path, ".pub")
    environment = var.environment
  })
  filename        = "${path.module}/../../../ansible/inventory/openbao.ini.generated"
  file_permission = "0600"
}
