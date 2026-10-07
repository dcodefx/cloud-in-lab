output "floci_ip" {
  value       = module.floci.vm_ips[0]
  description = "Floci sunucu IP adresi"
}

output "floci_name" {
  value       = module.floci.vm_names[0]
  description = "Floci sunucu ismi"
}

output "floci_info" {
  value       = "Floci AWS Emulator:\n  IP: ${module.floci.vm_ips[0]}\n  Kurulum sonrasi Ansible:\n  ansible-playbook -i inventory/floci.ini.generated playbooks/floci.yml"
  description = "Kurulum sonrasi bilgiler"
}
