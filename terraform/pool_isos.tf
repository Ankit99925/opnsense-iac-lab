# Cloud-init ISOs copied into the storage pool.
# libvirt_cloudinit_disk writes its ISO to /tmp, which on this host is
# tmpfs (wiped at every reboot) and aged out after 10 days. VMs attach
# these pool copies instead, so they survive reboots like any disk.
# No format is set on purpose: "raw" makes the provider report a change
# on every apply.

resource "libvirt_volume" "server_cloudinit" {
  name   = "lab-server-cloudinit.iso"
  pool   = "default"
  create = { content = { url = libvirt_cloudinit_disk.server.path } }
}

resource "libvirt_volume" "vlantest_cloudinit" {
  name   = "lab-vlantest-cloudinit.iso"
  pool   = "default"
  create = { content = { url = libvirt_cloudinit_disk.vlantest.path } }
}

resource "libvirt_volume" "opnsense_config" {
  name   = "lab-opnsense-config.iso"
  pool   = "default"
  create = { content = { url = libvirt_cloudinit_disk.opnsense_config.path } }
}
