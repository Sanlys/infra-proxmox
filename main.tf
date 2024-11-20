
terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc4"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.7.0-alpha.0"
    }
  }
}

variable "proxmoxurl" {
  default = "https://pve1.s1.lan:8006/api2/json"
}

variable "talos_iso" {
  default = "ceph-iso:iso/talos-nocloud-qemuguest-amd64.iso"
}

provider "proxmox" {
  pm_api_url      = var.proxmoxurl
  pm_tls_insecure = true
  pm_parallel     = 1
}

provider "talos" {}

variable "disk_size" {
  type    = string
  default = "20G"
}

variable "default_vm" {
  type = object({
    worker  = bool
    cores   = number
    memory  = number
    storage = string
  })
  default = {
    worker  = true
    cores   = 2
    memory  = 2048
    storage = "local-lvm"
  }
}

variable "vms" {
  type = list(object({
    node          = string
    control_plane = bool
    worker        = optional(bool)
    cores         = optional(number)
    memory        = optional(number)
    storage       = optional(string)
  }))
  default = [
    {
      node          = "pve1"
      control_plane = true
    },
    {
      node          = "pve2"
      control_plane = true
    },
    {
      node          = "pve3"
      control_plane = true
    },
    {
      node          = "pve4"
      control_plane = false
    }
  ]
}

resource "proxmox_vm_qemu" "node" {
  count       = length(var.vms)
  name        = "infranode-${count.index + 1}"
  target_node = element(var.vms, count.index).node
  cores       = coalesce(element(var.vms, count.index).cores, var.default_vm.cores)
  memory      = coalesce(element(var.vms, count.index).memory, var.default_vm.memory)
  tags = join(
    ",",
    concat(
      element(var.vms, count.index).control_plane ? ["control-plane"] : [],
      coalesce(element(var.vms, count.index).worker, var.default_vm.worker) ? ["worker"] : []
    )
  )

  scsihw                 = "virtio-scsi-pci"
  define_connection_info = true

  boot  = "order=sata0"
  agent = 1

  disks {
    scsi {
      scsi0 {
        disk {
          size    = var.disk_size
          storage = coalesce(element(var.vms, count.index).storage, var.default_vm.storage)
        }
      }
    }
    sata {
      sata0 {
        cdrom {
          iso = var.talos_iso
        }
      }
    }
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=dhcp"
}

locals {
  ips = [for vm in proxmox_vm_qemu.node : vm.ssh_host]
}

output "ips" {
  value       = local.ips
  description = "All node IPs"
}

locals {

}
