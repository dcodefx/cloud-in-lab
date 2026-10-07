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
  default = 301
  description = "Container ID. OpenBao stack varsayilani 301 (300+ araligi)."
}

variable "template_file_id" {
  type    = string
  description = "Container template file ID (e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst)"
}

variable "base_ip" {
  type    = string
}

variable "ip_mask" {
  type    = number
  default = 24
}

variable "ip_offset" {
  type    = number
  default = 186
}

variable "gateway" {
  type    = string
}

variable "cpu_cores" {
  type    = number
  default = 2
}

variable "memory_dedicated" {
  type    = number
  default = 2048
}

variable "memory_swap" {
  type    = number
  default = 0
}

variable "disk_size" {
  type    = number
  default = 20
}

variable "dns_server" {
  type    = string
  default = "1.1.1.1"
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_pub_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

# common.tfvars'tan gelen (K8s LXC vm icin) — openbao stack'inde kullanilmaz
variable "template_vm_id" {
  type    = number
  default = null
}

variable "protection" {
  type    = bool
  default = true
  description = "Container koruma (silinemez/degistirilemez)"
}

variable "root_password" {
  type      = string
  default   = "OpenBaoRoot2026!"
  sensitive = true
}

variable "proxmox_endpoint" {
  type    = string
}

variable "proxmox_token" {
  type      = string
  sensitive = true
}
