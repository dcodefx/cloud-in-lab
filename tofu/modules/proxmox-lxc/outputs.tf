output "container_ids" {
  value       = proxmox_virtual_environment_container.lxc[*].id
  description = "Container ID'leri"
}

output "hostnames" {
  value       = [for i in range(var.lxc_count) : "${var.hostname}-${i + 1}"]
  description = "Container hostnamelari (var.hostname + index ile hesaplanir)"
}

output "ip_addresses" {
  value       = [for i in range(var.lxc_count) : cidrhost("${var.base_ip}/${var.ip_mask}", var.ip_start_index + i)]
  description = "Container IP adresleri (base_ip + ip_start_index ile hesaplanir)"
}
