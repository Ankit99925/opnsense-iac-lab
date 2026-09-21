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

resource "libvirt_volume" "opnsense" {
  name          = "opnsense.qcow2"
  pool          = "default"
  capacity      = 20
  capacity_unit = "GiB"

  target = {
    format = { type = "qcow2" }
    permissions = {
      owner = "64055"
      group = "991"
      mode  = "0660"
    }
  }
}

resource "libvirt_domain" "opnsense" {
  name        = "opnsense"
  type        = "kvm"
  memory      = 2
  memory_unit = "GiB"
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
    type_machine = "pc-i440fx-resolute"
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
      { source = { network = { network = var.wan_network } }, model = { type = "virtio" } },
      { source = { network = { network = libvirt_network.servers.name } }, model = { type = "virtio" } },
      { source = { bridge = { bridge = var.clients_bridge } }, model = { type = "virtio" } },
      { source = { bridge = { bridge = var.trunk_bridge } }, model = { type = "virtio" } },
    ]

    consoles = [{ target = { type = "serial", port = 0 } }]

    graphics = [{ vnc = { auto_port = true, listen = "127.0.0.1" } }]
    videos   = [{ model = { type = "vga" } }]
  }
}
