variable "target_node" {
  type        = string
  default     = "pve"
  description = "Proxmox node name"
}

variable "ct_id" {
  type        = number
  default     = 0
  description = "Container ID (0 = automatic)"
}

variable "lxc_count" {
  type        = number
  default     = 1
  description = "Oluşturulacak container sayısı"
}

variable "hostname" {
  type        = string
  description = "Container hostname"
}

variable "description" {
  type        = string
  default     = "Managed by OpenTofu"
  description = "Container description"
}

variable "template_file_id" {
  type        = string
  description = "Container template file ID (e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst)"
}

variable "ssh_pub_key" {
  type        = string
  default     = ""
  description = "SSH public key content (file() ile okuyun). Bos ise user_account eklenmez."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment name (dev, prod)"
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Container tags"
}

variable "unprivileged" {
  type        = bool
  default     = true
  description = "Run container unprivileged"
}

variable "cpu_cores" {
  type        = number
  default     = 1
  description = "CPU cores"
}

variable "memory_dedicated" {
  type        = number
  default     = 512
  description = "RAM in MB"
}

variable "memory_swap" {
  type        = number
  default     = 0
  description = "Swap in MB"
}

variable "disk_size" {
  type        = number
  default     = 10
  description = "Disk size in GB"
}

variable "disk_storage" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage name"
}

variable "base_ip" {
  type        = string
  description = "Network base IP (e.g. 164.102.98.0)"
}

variable "ip_mask" {
  type        = number
  default     = 24
  description = "IP mask"
}

variable "ip_start_index" {
  type        = number
  default     = 10
  description = "IP başlangıç indeksi (cidrhost ile hesaplama)"
}

variable "gateway" {
  type        = string
  description = "Network gateway"
}

variable "dns_server" {
  type        = string
  default     = "1.1.1.1"
  description = "DNS server"
}

variable "dns_domain" {
  type        = string
  default     = "homelab.local"
  description = "DNS domain"
}

variable "enable_firewall" {
  type        = bool
  default     = true
  description = "Enable Proxmox firewall"
}

variable "features_nesting" {
  type        = bool
  default     = true
  description = "Enable nesting (systemd icin gerekli)"
}

variable "features_keyctl" {
  type        = bool
  default     = false
  description = "Enable keyctl"
}

variable "console_enabled" {
  type        = bool
  default     = true
  description = "Enable console"
}

variable "startup_order" {
  type        = number
  default     = 1
  description = "Startup order (lower = earlier)"
}

variable "os_type" {
  type        = string
  default     = ""
  description = "LXC OS tipi (ubuntu, debian, alpine, centos...). Bos ise unmanaged."
}

variable "root_password" {
  type        = string
  default     = ""
  description = "Container root sifresi. Bos ise user_account'a password eklenmez."
  sensitive   = true
}

variable "protection" {
  type        = bool
  default     = false
  description = "true ise container ve diski silinemez/degistirilemez. Stateful servisler (openbao, database) icin kullanin."
}
