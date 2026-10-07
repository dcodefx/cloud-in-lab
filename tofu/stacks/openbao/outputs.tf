output "openbao_ip" {
  value       = module.openbao.ip_addresses[0]
  description = "OpenBao container IP adresi"
}

output "openbao_id" {
  value       = module.openbao.container_ids[0]
  description = "OpenBao container ID"
}

output "openbao_api_addr" {
  value       = "https://${module.openbao.ip_addresses[0]}:8200"
  description = "OpenBao API adresi (Ansible için)"
}

output "openbao_admin_info" {
  value       = "OpenBao kurulduktan sonra:\n  cd ansible\n  # Önerilen (wrapper):\n  ansible-playbook playbook.yml -i inventory/openbao.ini.generated\n  # Alternatif (doğrudan):\n  ansible-playbook -i inventory/openbao.ini.generated playbooks/openbao.yml"
  description = "Kurulum sonrası yapılması gerekenler"
}
