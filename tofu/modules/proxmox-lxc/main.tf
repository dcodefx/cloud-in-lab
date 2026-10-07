terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
  }
}

resource "proxmox_virtual_environment_container" "lxc" {
  count        = var.lxc_count
  node_name    = var.target_node
  vm_id        = var.ct_id > 0 ? var.ct_id : null
  unprivileged = var.unprivileged
  description  = var.description
  protection   = var.protection

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type != "" ? var.os_type : null
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_dedicated
    swap      = var.memory_swap
  }

  disk {
    datastore_id = var.disk_storage
    size         = var.disk_size
  }

  network_interface {
    name         = "eth0"
    bridge       = "vmbr0"
    firewall     = var.enable_firewall
    host_managed = true
  }

  initialization {
    hostname = "${var.hostname}-${count.index + 1}"

    ip_config {
      ipv4 {
        address = "${cidrhost("${var.base_ip}/${var.ip_mask}", var.ip_start_index + count.index)}/${var.ip_mask}"
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.dns_server]
      domain  = var.dns_domain
    }

    dynamic "user_account" {
      for_each = var.ssh_pub_key != "" || var.root_password != "" ? [1] : []
      content {
        keys     = var.ssh_pub_key != "" ? [var.ssh_pub_key] : null
        password = var.root_password != "" ? var.root_password : null
      }
    }
  }

  features {
    nesting = var.features_nesting
    keyctl  = var.features_keyctl
  }

  tags = var.tags

  console {
    enabled = var.console_enabled
  }

  startup {
    order = var.startup_order
  }

  wait_for_ip {
    ipv4 = true
  }

  lifecycle {
    ignore_changes = [
      disk,
    ]
  }
}
