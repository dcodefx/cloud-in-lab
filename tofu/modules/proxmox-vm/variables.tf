variable "vm_count" {
  type        = number
  description = "Oluşturulacak VM sayısı"
  default     = 1
}

variable "vm_name" {
  type        = string
  description = "VM temel adı (örn: k8s-master)"
}

variable "vm_role" {
  type        = string
  description = "VM rolü (örn: k8s-master, db-primary)"
}

variable "environment" {
  type        = string
  description = "Ortam adı (dev, test, stage, prod)"
  default     = "dev"
}

variable "template_vm_id" {
  type        = number
  description = "Clone alınacak template VM ID"
}

variable "target_node" {
  type        = string
  description = "VM'in kurulacağı Proxmox node adı"
  default     = "pve"
}

# Donanım
variable "cpu_cores" {
  type    = number
  default = 2
}

variable "vm_memory" {
  type    = number
  default = 4096
}

# OS Disk
variable "disk_size" {
  type        = number
  description = "OS disk boyutu (GB)"
  default     = 20
}

variable "disk_storage" {
  type    = string
  default = "local-lvm"
}

# Data Disk (Opsiyonel)
variable "data_disk_enabled" {
  type    = bool
  default = false
}

variable "data_disk_size" {
  type        = number
  description = "Data disk boyutu (GB)"
  default     = 50
}

variable "data_disk_storage" {
  type    = string
  default = "local-lvm"
}

# Network
variable "base_ip" {
  type        = string
  description = "IP ağ adresi (örn: 192.168.1.0)"
}

variable "ip_mask" {
  type    = string
  default = "24"
}

variable "ip_start_index" {
  type        = number
  description = "IP başlangıç indeksi (cidrhost ile hesaplama)"
  default     = 10
}

variable "gateway" {
  type        = string
  description = "Ağ gateway adresi"
}

variable "enable_firewall" {
  type    = bool
  default = false
}

# SSH
variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_pub_key" {
  type        = string
  description = "SSH public key"
  sensitive   = true
}
