output "db_ips" {
  value = flatten([for db in module.db_hosts : db.vm_ips])
}
