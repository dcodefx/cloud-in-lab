output "laws_ip" {
  value       = module.laws.ip_addresses[0]
  description = "Laws container IP adresi"
}

output "laws_id" {
  value       = module.laws.container_ids[0]
  description = "Laws container ID"
}

output "laws_endpoint" {
  value       = "http://${module.laws.ip_addresses[0]}:4566"
  description = "Laws AWS emulator endpoint"
}

output "laws_info" {
  value       = "Laws AWS emulator:\n  Endpoint: http://${module.laws.ip_addresses[0]}:4566\n  Kurulum sonrasi Ansible:\n  ansible-playbook -i inventory/laws.ini.generated playbooks/laws.yml"
  description = "Kurulum sonrasi bilgiler"
}
