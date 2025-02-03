
terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc4"
    }
    talos = {
      source = "siderolabs/talos"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
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

variable "default_vm" {
  type = object({
    worker  = bool
    cores   = number
    memory  = number
    storage = string
    disk    = string
  })
  default = {
    worker  = true
    cores   = 4
    memory  = 2048
    storage = "local-lvm"
    disk    = "40G"
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
    disk          = optional(string)
  }))
  default = [
    {
      node          = "pve1"
      control_plane = false
    },
    {
      node          = "pve2"
      control_plane = true
    },
    {
      node          = "pve3"
      control_plane = false
    },
    {
      node          = "pve4"
      control_plane = true
    },
    {
      node          = "pve5"
      control_plane = true
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

  boot   = "order=scsi0;sata0"
  agent  = 1
  onboot = true

  disks {
    scsi {
      scsi0 {
        disk {
          size    = coalesce(element(var.vms, count.index).disk, var.default_vm.disk)
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
  ips = toset([for vm in proxmox_vm_qemu.node : vm.ssh_host])
  controlplaneips = toset([
    for vm in proxmox_vm_qemu.node :
    vm.ssh_host
    if can(regex("(?i)control-plane", vm.tags))
  ])
  workerips = toset(setsubtract(local.ips, local.controlplaneips))
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

resource "talos_machine_secrets" "all_nodes" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = "infra"
  machine_type     = "controlplane"
  cluster_endpoint = "https://api.infrak8s.s1.lan:6443"
  machine_secrets  = talos_machine_secrets.all_nodes.machine_secrets
}

data "talos_machine_configuration" "worker" {
  cluster_name     = "infra"
  machine_type     = "worker"
  cluster_endpoint = "https://api.infrak8s.s1.lan:6443"
  machine_secrets  = talos_machine_secrets.all_nodes.machine_secrets
}

data "talos_client_configuration" "all_nodes" {
  cluster_name         = "infra"
  client_configuration = talos_machine_secrets.all_nodes.client_configuration
  endpoints            = local.controlplaneips
}

data "talos_image_factory_extensions_versions" "this" {
  talos_version = "v1.9.0"
  filters = {
    names = [
      "iscsi-tools",
      "util-linux-tools",
      "qemu-guest-agent",
    ]
  }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = data.talos_image_factory_extensions_versions.this.extensions_info.*.name
        }
      }
    }
  )
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each                    = local.controlplaneips
  client_configuration        = talos_machine_secrets.all_nodes.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.key
  apply_mode                  = "reboot"
  config_patches = [
    yamlencode([
      {
        op   = "add"
        path = "/machine/install"
        value = {
          image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${data.talos_image_factory_extensions_versions.this.talos_version}",
          disk  = "/dev/sda"
        }
      }
    ]),
    yamlencode([
      {
        op    = "add"
        path  = "/cluster/allowSchedulingOnControlPlanes"
        value = true
      }
    ]),
    yamlencode([
      {
        op   = "add"
        path = "/machine/kubelet/extraMounts"
        value = [{
          destination = "/var/lib/longhorn"
          type        = "bind"
          source      = "/var/lib/longhorn"
          options     = ["bind", "rshared", "rw"]
        }]
      }
    ])
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  client_configuration        = talos_machine_secrets.all_nodes.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  for_each                    = local.workerips
  node                        = each.key
  config_patches = [
    yamlencode([
      {
        op   = "add"
        path = "/machine/install"
        value = {
          image = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}:${data.talos_image_factory_extensions_versions.this.talos_version}",
          disk  = "/dev/sda"
        }
      }
    ]),
    yamlencode([
      {
        op    = "add"
        path  = "/cluster/allowSchedulingOnControlPlanes"
        value = true
      }
    ]),
    yamlencode([
      {
        op   = "add"
        path = "/machine/kubelet/extraMounts"
        value = [{
          destination = "/var/lib/longhorn"
          type        = "bind"
          source      = "/var/lib/longhorn"
          options     = ["bind", "rshared", "rw"]
        }]
      }
    ])
  ]
}

/*
data "talos_machine_configuration" "worker" {
  cluster_name     = "infra"
  machine_type     = "worker"
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
      }
    ])
  ]
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
}*/

resource "talos_machine_bootstrap" "controlplane" {
  depends_on = [talos_machine_configuration_apply.controlplane]

  client_configuration = data.talos_client_configuration.all_nodes.client_configuration
  node                 = [for k, v in local.controlplaneips : k][0]
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.controlplane]
  client_configuration = data.talos_client_configuration.all_nodes.client_configuration
  node                 = [for k, v in local.controlplaneips : k][0]
}

resource "local_sensitive_file" "talosconfig" {
  content  = data.talos_client_configuration.all_nodes.talos_config
  filename = "tmp/talosconfig.yaml"
}

resource "local_sensitive_file" "kubeconfig" {
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename = "tmp/kubeconfig.yaml"
}

provider "kubernetes" {
  config_path    = "tmp/kubeconfig.yaml"
  config_context = "admin@infra"
}

provider "helm" {
  kubernetes {
    config_path = "tmp/kubeconfig.yaml"
  }
}

resource "kubernetes_namespace" "metallb" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "metallb-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  depends_on       = [kubernetes_namespace.metallb]
  name             = "metallb"
  chart            = "https://github.com/metallb/metallb/releases/download/metallb-chart-0.14.9/metallb-0.14.9.tgz"
  namespace        = kubernetes_namespace.metallb.metadata[0].name
  create_namespace = false

  set {
    name  = "speaker.ignoreExcludeLB"
    value = true
  }
}

resource "kubernetes_manifest" "metallb" {
  depends_on = [helm_release.metallb]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = "ip-range"
      namespace = kubernetes_namespace.metallb.metadata[0].name
    }
    spec = {
      addresses = ["10.0.5.230-10.0.5.240"]
    }
  }
}

resource "kubernetes_manifest" "metallb-advertisement" {
  depends_on = [kubernetes_manifest.metallb]
  manifest = {
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = "l2advertisement"
      namespace = kubernetes_namespace.metallb.metadata[0].name
    }
  }
}

resource "kubernetes_namespace" "coredns" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "coredns"
  }
}

resource "helm_release" "coredns" {
  depends_on       = [helm_release.metallb, kubernetes_namespace.coredns]
  name             = "coredns"
  chart            = "https://github.com/coredns/helm/releases/download/coredns-1.37.0/coredns-1.37.0.tgz"
  namespace        = kubernetes_namespace.coredns.metadata[0].name
  create_namespace = false

  values = [
    "${file("./coredns/values.yaml")}"
  ]

  set {
    name  = "isClusterService"
    value = false
  }
  set {
    name  = "serviceType"
    value = "LoadBalancer"
  }
  set {
    name  = "service.loadBalancerIP"
    value = "10.0.5.230"
  }
  set {
    name  = "extraVolumeMounts"
    value = ""
  }
}

resource "kubernetes_namespace" "longhorn" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "longhorn-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "longhorn" {
  depends_on       = [kubernetes_namespace.longhorn]
  name             = "longhorn"
  chart            = "https://github.com/longhorn/charts/releases/download/longhorn-1.7.2/longhorn-1.7.2.tgz"
  namespace        = kubernetes_namespace.longhorn.metadata[0].name
  create_namespace = false

  set {
    name  = "defaultSettings.nodeDrainPolicy"
    value = "block-for-eviction"
  }
}

resource "kubernetes_namespace" "vault" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "vault"
  }
}

resource "helm_release" "vault" {
  depends_on       = [kubernetes_namespace.vault, helm_release.longhorn]
  name             = "vault"
  chart            = "https://helm.releases.hashicorp.com/vault-0.29.1.tgz"
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
}

resource "helm_release" "vaultsecretsoperator" {
  depends_on       = [helm_release.vault]
  name             = "vaultsecretsoperator"
  chart            = "https://helm.releases.hashicorp.com/vault-secrets-operator-0.9.1.tgz"
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  set {
    name  = "defaultVaultConnection.enabled"
    value = true
  }
  set {
    name  = "defaultVaultConnection.address"
    value = "http://vault.vault.svc.cluster.local:8200"
  }
  set {
    name  = "defaultVaultConnection.skipTLSVerify"
    value = true
  }
}

resource "kubernetes_namespace" "traefik" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "traefik"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "kubernetes_service_account" "traefik_operator" {
  depends_on = [kubernetes_namespace.vault]
  metadata {
    name      = "traefik-operator"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "kubernetes_service_account" "traefik" {
  depends_on = [kubernetes_namespace.traefik]
  metadata {
    name      = "traefik"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
}

resource "kubernetes_manifest" "static_auth" {
  depends_on = [kubernetes_namespace.traefik]
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "static-auth"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role           = "traefik-role"
        serviceAccount = "traefik"
        audiences      = ["vault"]
      }
    }
  }
}

resource "kubernetes_manifest" "static_secret" {
  depends_on = [kubernetes_namespace.traefik, kubernetes_manifest.static_auth]
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "static-secret"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      type  = "kv-v1"
      mount = "secret"
      path  = "/infra/traefik/cloudflare"
      destination = {
        name   = "cloudflaresecrets"
        create = true
      }
      refreshAfter = "15s"
      vaultAuthRef = kubernetes_manifest.static_auth.manifest.metadata.name
    }
  }
}

resource "helm_release" "traefik" {
  depends_on = [
    kubernetes_namespace.traefik,
    helm_release.longhorn,
    helm_release.coredns,
  ]
  name             = "traefik"
  chart            = "https://traefik.github.io/charts/traefik/traefik-33.2.1.tgz"
  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false

  values = ["${file("./traefik/values.yaml")}"]
}

resource "kubernetes_namespace" "nginxtest" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "nginxtest"
  }
}

resource "kubernetes_deployment" "nginxtest" {
  depends_on = [kubernetes_namespace.nginxtest, helm_release.traefik]
  metadata {
    name      = "nginx"
    namespace = "nginxtest"
  }
  spec {
    selector {
      match_labels = {
        app = "nginx"
      }
    }
    replicas = 3
    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }
      spec {
        container {
          image = "nginx:latest"
          name  = "nginx"

          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginxtest" {
  depends_on = [local_sensitive_file.kubeconfig]
  metadata {
    name      = "nginx"
    namespace = "nginxtest"
  }
  spec {
    selector = {
      app = "nginx"
    }
    type = "ClusterIP"
    port {
      name = "http"
      port = 80
    }
  }
}

resource "kubernetes_ingress_v1" "nginxtest" {
  depends_on = [local_sensitive_file.kubeconfig]
  metadata {
    name      = "nginx"
    namespace = "nginxtest"
  }
  spec {
    rule {
      host = "test.lysakermoen.com"
      http {
        path {
          backend {
            service {
              name = "nginx"
              port {
                name = "http"
              }
            }
          }
        }
      }
    }
  }
}


resource "kubernetes_namespace" "dnsentry" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "dnsentry"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "kubernetes_manifest" "dnsrecord" {
  depends_on = [kubernetes_namespace.dnsentry]
  manifest = {
    apiVersion = "apiextensions.k8s.io/v1"
    kind       = "CustomResourceDefinition"
    metadata = {
      name = "dnsrecords.cluster.local"
    }
    spec = {
      group = "cluster.local"
      versions = [{
        name    = "v1"
        served  = true
        storage = true
        schema = {
          openAPIV3Schema = {
            type = "object"
            properties = {
              spec = {
                type = "object"
                properties = {
                  host = {
                    type = "string"
                  }
                  ip = {
                    type = "string"
                  }
                }
              }
            }
          }
        }
      }]
      names = {
        kind       = "DNSRecord"
        plural     = "dnsrecords"
        singular   = "dnsrecord"
        shortNames = ["dr"]
      }
      scope = "Namespaced"
    }
  }
}

resource "kubernetes_role_v1" "dnsupdater" {
  depends_on = [kubernetes_manifest.dnsrecord]
  metadata {
    name      = "dnsupdater"
    namespace = kubernetes_namespace.dnsentry.metadata[0].name
  }
  rule {
    api_groups = ["cluster.local"]
    resources  = ["dnsrecords"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "dnsupdater" {
  depends_on = [kubernetes_manifest.dnsrecord]
  metadata {
    name      = "dnsupdater"
    namespace = kubernetes_namespace.dnsentry.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.dnsentry.metadata[0].name
  }
  role_ref {
    kind      = "Role"
    name      = "dnsupdater"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "hosts" {
  depends_on = [
    kubernetes_namespace.dnsentry,
    helm_release.longhorn,
  ]

  metadata {
    name      = "hosts"
    namespace = kubernetes_namespace.dnsentry.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "dnsupdater" {
  metadata {
    name      = "dns-updater"
    namespace = kubernetes_namespace.dnsentry.metadata[0].name
  }
  spec {
    schedule                      = "*/2 * * * *"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    suspend                       = true
    job_template {
      metadata {
        name      = "dns-updater-job"
        namespace = kubernetes_namespace.dnsentry.metadata[0].name
      }
      spec {
        template {
          metadata {
            name = "dns-updater-pod"
          }
          spec {
            container {
              name  = "update-hosts"
              image = "bitnami/kubectl:latest"
              command = [
                "sh",
                "-c",
                "kubectl get dnsrecords.cluster.local -o json -n dnsentry | jq '.items[] | \"\\(.spec.ip) \\(.spec.host)\"' > /mnt/output/hosts"
              ]
              volume_mount {
                name       = "output-volume"
                mount_path = "/mnt/output"
              }
            }
            restart_policy = "OnFailure"
            volume {
              name = "output-volume"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim_v1.hosts.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
}

variable "dns_records" {
  type = map(object({
    host = string
    ip   = string
  }))
  default = {
    "pve-1" = {
      host = "pve1.s1.lysakermoen.com"
      ip   = "10.0.5.101"
    }
    "pve-2" = {
      host = "pve2.s1.lysakermoen.com"
      ip   = "10.0.5.102"
    }
    "pve-3" = {
      host = "pve3.s1.lysakermoen.com"
      ip   = "10.0.5.103"
    }
    "pve-4" = {
      host = "pve4.s1.lysakermoen.com"
      ip   = "10.0.5.149"
    }
    "pve-5" = {
      host = "pve5.s1.lysakermoen.com"
      ip   = "10.0.5.119"
    }
  }
}

resource "kubernetes_manifest" "dns_records" {
  depends_on = [kubernetes_manifest.dnsrecord]
  for_each   = var.dns_records

  manifest = {
    apiVersion = "cluster.local/v1"
    kind       = "DNSRecord"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace.dnsentry.metadata[0].name
    }
    spec = {
      host = each.value.host
      ip   = each.value.ip
    }
  }
}
resource "kubernetes_namespace" "grafana_prom_stack" {
  depends_on = [local_sensitive_file.kubeconfig]

  metadata {
    name = "grafana-prom-stack"
  }
}


resource "helm_release" "grafana_prom_stack" {
  depends_on       = [kubernetes_namespace.grafana_prom_stack]
  name             = "grafana-prom-stack"
  chart            = "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-68.2.1/kube-prometheus-stack-68.2.1.tgz"
  namespace        = kubernetes_namespace.grafana_prom_stack.metadata[0].name
  create_namespace = false
}
