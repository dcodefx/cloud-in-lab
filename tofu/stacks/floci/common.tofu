variable "environment" {
  type    = string
  default = "dev"
}

variable "target_node" {
  type    = string
  default = "pve"
}

variable "template_vm_id" {
  type = number
}

variable "cpu_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 4096
}

variable "disk_size" {
  type    = number
  default = 40
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

variable "ssh_user" {
  type    = string
  default = "qfx"
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
