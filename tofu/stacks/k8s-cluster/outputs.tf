output "k8s_ips" {
  value       = flatten([for pool in module.k8s_pool : pool.vm_ips])
  description = "Tüm K8s VM IP adresleri"
}

output "k8s_vm_names" {
  value       = flatten([for pool in module.k8s_pool : pool.vm_names])
  description = "Tüm K8s VM isimleri"
}

output "k8s_master_ips" {
  value = flatten([
    for name, pool in module.k8s_pool :
    pool.vm_ips if var.node_pools[name].role == "k8s-master"
  ])
  description = "K8s master VM IP adresleri"
}

output "k8s_worker_ips" {
  value = flatten([
    for name, pool in module.k8s_pool :
    pool.vm_ips if var.node_pools[name].role == "k8s-worker"
  ])
  description = "K8s worker VM IP adresleri"
}

output "k8s_master_names" {
  value = flatten([
    for name, pool in module.k8s_pool :
    pool.vm_names if var.node_pools[name].role == "k8s-master"
  ])
  description = "K8s master VM isimleri"
}

output "k8s_worker_names" {
  value = flatten([
    for name, pool in module.k8s_pool :
    pool.vm_names if var.node_pools[name].role == "k8s-worker"
  ])
  description = "K8s worker VM isimleri"
}

resource "local_file" "inventory" {
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    master_vms = [
      for i, ip in module.k8s_pool["masters"].vm_ips : {
        name     = module.k8s_pool["masters"].vm_names[i]
        ip       = ip
        ssh_user = var.ssh_user
        ssh_key  = trimsuffix(var.ssh_pub_key_path, ".pub")
      }
    ]
    worker_vms = [
      for i, ip in module.k8s_pool["workers"].vm_ips : {
        name     = module.k8s_pool["workers"].vm_names[i]
        ip       = ip
        ssh_user = var.ssh_user
        ssh_key  = trimsuffix(var.ssh_pub_key_path, ".pub")
      }
    ]
    environment = var.environment
  })
  filename        = "${path.module}/../../../ansible/inventory/hosts.ini.generated"
  file_permission = "0600"
}
