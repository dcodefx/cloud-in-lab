variable "environment" {
  type    = string
  default = "dev"
}

variable "target_node" {
  type    = string
  default = "pve"
}

variable "ct_id" {
  type    = number
  default = 302
}

variable "template_file_id" {
  type = string
}

variable "cpu_cores" {
  type    = number
  default = 1
}

variable "memory_dedicated" {
  type    = number
  default = 2048
}

variable "memory_swap" {
  type    = number
  default = 1024
}

variable "disk_size" {
  type    = string
  default = "20"
}

variable "base_ip" {
  type = string
}

variable "ip_offset" {
  type = number
}

variable "ip_mask" {
  type    = string
  default = "24"
}

variable "gateway" {
  type = string
}

variable "dns_server" {
  type    = string
  default = "1.1.1.1"
}

# common.tfvars'tan gelen (K8s LXC vm icin) — laws stack'inde kullanilmaz
variable "template_vm_id" {
  type    = number
  default = null
}

variable "root_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_pub_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "enable_firewall" {
  type    = bool
  default = false
}

variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}
