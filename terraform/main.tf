terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_network" "servers" {
  name = "servers"

  bridge = {
    name = "virbr2"
  }
}

variable "opnsense_iso" { type = string }
variable "wan_network" { default = "default" }
variable "clients_bridge" { default = "br-clients" }
variable "trunk_bridge" { default = "br-trunk" }
variable "vm_user" { default = "ubuntu" }
variable "ssh_key_path" { default = "~/.ssh/id_ed25519.pub" }

resource "libvirt_volume" "opnsense" {
  name          = "opnsense.qcow2"
  pool          = "default"
  capacity      = 20
  capacity_unit = "GiB"

  lifecycle {
    ignore_changes = [target]
  }

  target = {
    format = { type = "qcow2" }
    permissions = {
      owner = var.qemu_uid
      group = var.kvm_gid
      mode  = "0660"
    }
  }
}

resource "libvirt_domain" "opnsense" {
  name        = "opnsense"
  type        = "kvm"
  memory      = 1536
  memory_unit = "MiB"
  vcpu        = 2

  features = {
    acpi = true
    apic = {}
  }

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = var.opnsense_machine
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { file = { file = libvirt_volume.opnsense.path } }
        target = { dev = "vda", bus = "virtio" }
        boot   = { order = 1 }
      },
      {
        device = "cdrom"
        driver = { name = "qemu", type = "raw" }
        source = { file = { file = var.opnsense_iso } }
        target = { dev = "sda", bus = "sata" }
        boot   = { order = 2 }
      },
    ]

    interfaces = [
      { source = { network = { network = var.wan_network } }, model = { type = "virtio" }, mac = { address = "52:54:00:b4:49:cb" } },
      { source = { network = { network = libvirt_network.servers.name } }, model = { type = "virtio" } },
      { source = { bridge = { bridge = var.clients_bridge } }, model = { type = "virtio" } },
      { source = { bridge = { bridge = var.trunk_bridge } }, model = { type = "virtio" } },
    ]

    consoles = [{ target = { type = "serial", port = 0 } }]

    graphics = [{ vnc = { auto_port = true, listen = "127.0.0.1" } }]
    videos   = [{ model = { type = "vga" } }]
  }
}

resource "libvirt_cloudinit_disk" "server" {
  name = "lab-server-init.iso"

  meta_data = yamlencode({
    instance-id    = "ubuntu-server"
    local-hostname = "ubuntu-server"
  })

  user_data = <<-EOT
    #cloud-config
    users:
      - name: ${var.vm_user}
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        lock_passwd: false
        passwd: ${var.console_password_hash}
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand(var.ssh_key_path)))}
  EOT

  network_config = <<-EOT
    network:
      version: 2
      ethernets:
        lan:
          match:
            name: "en*"
          addresses: [192.168.100.10/24]
          routes:
            - to: default
              via: 192.168.100.1
          nameservers:
            addresses: [192.168.100.1]
  EOT
}

resource "libvirt_volume" "ubuntu_base" {
  name = "lab-ubuntu-base.qcow2"
  pool = "default"

  lifecycle {
    ignore_changes = [target]
  }

  create = {
    content = {
      url = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    }
  }

  target = {
    format      = { type = "qcow2" }
    permissions = { owner = var.qemu_uid, group = var.kvm_gid, mode = "0660" }
  }
}

resource "libvirt_volume" "server" {
  name          = "lab-server.qcow2"
  pool          = "default"
  capacity      = 20
  capacity_unit = "GiB"

  lifecycle {
    ignore_changes = [target]
  }

  target = {
    format      = { type = "qcow2" }
    permissions = { owner = var.qemu_uid, group = var.kvm_gid, mode = "0660" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }
}

resource "libvirt_domain" "server" {
  name        = "ubuntu-server"
  type        = "kvm"
  memory      = 1
  memory_unit = "GiB"
  vcpu        = 2

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = var.server_machine
  }

  features = {
    acpi = true
    apic = {}
  }

  cpu = { mode = "host-passthrough" }

  devices = {
    disks = [
      {
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { file = { file = libvirt_volume.server.path } }
        backing_store = {
          format = { type = "qcow2" }
          source = { file = { file = libvirt_volume.ubuntu_base.path } }
        }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        device = "cdrom"
        driver = { name = "qemu", type = "raw" }
        source = { file = { file = libvirt_cloudinit_disk.server.path } }
        target = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [
      { source = { network = { network = libvirt_network.servers.name } }, model = { type = "virtio" } },
    ]

    consoles = [{ target = { type = "serial", port = 0 } }]
  }
}

variable "qemu_uid" {
  type        = string
  description = "UID of libvirt-qemu: id -u libvirt-qemu"
}

variable "kvm_gid" {
  type        = string
  description = "GID of the kvm group: getent group kvm | cut -d: -f3"
}

variable "opnsense_machine" { default = "pc-i440fx-resolute" }
variable "server_machine" { default = "pc-q35-10.2" }
variable "console_password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 hash for console login: openssl passwd -6"
}

resource "libvirt_volume" "vlantest" {
  name          = "lab-vlantest.qcow2"
  pool          = "default"
  capacity      = 10
  capacity_unit = "GiB"

  target = {
    format      = { type = "qcow2" }
    permissions = { owner = var.qemu_uid, group = var.kvm_gid, mode = "0660" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu_base.path
    format = { type = "qcow2" }
  }

  lifecycle {
    ignore_changes = [target]
  }
}

resource "libvirt_cloudinit_disk" "vlantest" {
  name = "lab-vlantest-init.iso"

  meta_data = yamlencode({
    instance-id    = "vlantest"
    local-hostname = "vlantest"
  })

  user_data = <<-EOT
    #cloud-config
    users:
      - name: ${var.vm_user}
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        lock_passwd: false
        passwd: ${var.console_password_hash}
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand(var.ssh_key_path)))}
  EOT

  network_config = <<-EOT
    network:
      version: 2
      ethernets:
        trunk:
          match:
            name: "en*"
          dhcp4: false
      vlans:
        vlan10:
          id: 10
          link: trunk
          dhcp4: true
  EOT
}

resource "libvirt_domain" "vlantest" {
  name        = "vlantest"
  type        = "kvm"
  memory      = 512
  memory_unit = "MiB"
  vcpu        = 1

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = var.server_machine
  }

  features = {
    acpi = true
    apic = {}
  }

  cpu = { mode = "host-passthrough" }

  devices = {
    disks = [
      {
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { file = { file = libvirt_volume.vlantest.path } }
        backing_store = {
          format = { type = "qcow2" }
          source = { file = { file = libvirt_volume.ubuntu_base.path } }
        }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        device = "cdrom"
        driver = { name = "qemu", type = "raw" }
        source = { file = { file = libvirt_cloudinit_disk.vlantest.path } }
        target = { dev = "sda", bus = "sata" }
      },
    ]

    interfaces = [
      { source = { bridge = { bridge = var.trunk_bridge } }, model = { type = "virtio" } },
    ]

    consoles = [{ target = { type = "serial", port = 0 } }]
  }
}
