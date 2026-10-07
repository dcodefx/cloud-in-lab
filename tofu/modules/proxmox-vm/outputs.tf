output "vm_ips" {
  description = "Oluşturulan VM'lerin IP adresleri (Cloud-Init initialization)"
  value       = [for vm in proxmox_virtual_environment_vm.node : split("/", vm.initialization[0].ip_config[0].ipv4[0].address)[0]]
}

output "vm_names" {
  description = "Oluşturulan VM'lerin isimleri"
  value       = [for vm in proxmox_virtual_environment_vm.node : vm.name]
}
