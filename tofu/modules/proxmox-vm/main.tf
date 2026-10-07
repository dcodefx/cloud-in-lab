terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.78"
    }
  }
}

# Universal VM Modülü
# BPG provider - doc.bpg.sh'a göre

resource "proxmox_virtual_environment_vm" "node" {
  count = var.vm_count

  node_name = var.target_node
  name      = "${var.vm_name}-${count.index + 1}"

  description = "Managed by OpenTofu - ${var.environment}/${var.vm_role}"

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = var.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory
    floating  = var.vm_memory
  }

  # OS Disk
  disk {
    datastore_id = var.disk_storage
    size         = var.disk_size
    interface    = "scsi0"
    discard      = "on"
  }

  # Data Disk (opsiyonel)
  dynamic "disk" {
    for_each = var.data_disk_enabled ? [1] : []
    content {
      datastore_id = var.data_disk_storage
      size         = var.data_disk_size
      interface    = "scsi1"
      discard      = "on"
    }
  }

  network_device {
    bridge   = "vmbr0"
    firewall = var.enable_firewall
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${cidrhost("${var.base_ip}/${var.ip_mask}", var.ip_start_index + count.index)}/${var.ip_mask}"
        gateway = var.gateway
      }
    }

    user_account {
      username = var.ssh_user
      keys     = [var.ssh_pub_key]
    }
  }

  agent {
    enabled = true
  }

  tags = [var.environment, var.vm_role, "terraform"]

  serial_device {}

  lifecycle {
    ignore_changes = [
      network_device,
      disk,
    ]
  }
}
