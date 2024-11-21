
terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc4"
    }
    talos = {
      source = "siderolabs/talos"
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
  controlplaneips = [
    for vm in proxmox_vm_qemu.node :
    vm.ssh_host
    if can(regex("(?i)control-plane", vm.tags))
  ]
  workerips = tolist(setsubtract(local.ips, local.controlplaneips))
}

output "ips" {
  value       = local.ips
  description = "All node IPs"
}

output "controlplaneips" {
  value       = local.controlplaneips
  description = "Control plane IPs"
}

output "workerips" {
  value       = local.workerips
  description = "Worker IPs"
}

/* */

resource "talos_machine_secrets" "all_nodes" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "infra"
  machine_type     = "controlplane"
  cluster_endpoint = "https://${element(local.controlplaneips, 0)}:6443"
  machine_secrets  = talos_machine_secrets.all_nodes.machine_secrets
  config_patches = [
    yamlencode([
      {
        op   = "add"
        path = "/machine/install"
        value = {
          image = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.8.3"
        }
      },
      {
        op   = "add"
        path = "/machine/services/-"
        value = {
          name    = "qemu-guest-agent"
          command = "/usr/bin/qemu-ga"
          args    = ["--method=virtio-serial", "--path=/dev/virtio-ports/org.qemu.guest_agent.0"]
          enabled = true
        }
      }
    ])
  ]
}

data "talos_client_configuration" "controlplane" {
  cluster_name         = "infra"
  client_configuration = talos_machine_secrets.all_nodes.client_configuration
  nodes                = local.controlplaneips
}

resource "talos_machine_configuration_apply" "controlplane" {
  count                       = length(local.controlplaneips)
  client_configuration        = data.talos_client_configuration.controlplane.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  endpoint                    = element(local.controlplaneips, count.index)
  node                        = element(local.controlplaneips, count.index)
}

data "talos_machine_configuration" "worker" {
  cluster_name     = "infra"
  machine_type     = "worker"
  cluster_endpoint = "https://${element(local.controlplaneips, 0)}:6443"
  machine_secrets  = talos_machine_secrets.all_nodes.machine_secrets
}

data "talos_client_configuration" "worker" {
  cluster_name         = "infra"
  client_configuration = talos_machine_secrets.all_nodes.client_configuration
  nodes                = local.controlplaneips
}

resource "talos_machine_configuration_apply" "worker" {
  count                       = length(local.workerips)
  client_configuration        = data.talos_client_configuration.worker.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  endpoint                    = element(local.workerips, count.index)
  node                        = element(local.workerips, count.index)
}

resource "talos_machine_bootstrap" "controlplane" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  count                = length(local.controlplaneips)
  client_configuration = data.talos_client_configuration.controlplane.client_configuration
  endpoint             = element(local.controlplaneips, count.index)
  node                 = element(local.controlplaneips, count.index)
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.controlplane]
  client_configuration = data.talos_client_configuration.controlplane.client_configuration
  node                 = local.controlplaneips[0]
}
