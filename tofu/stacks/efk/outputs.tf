output "efk_ips" {
  value = flatten([for pool in module.efk_stack : pool.vm_ips])
}
