# Warn if any cloud-init ISO lands in /tmp (tmpfs on this host: wiped at
# reboot, which makes every later plan want to rebuild the ISOs).
check "cloudinit_isos_not_in_tmp" {
  assert {
    condition = alltrue([
      for p in [
        libvirt_cloudinit_disk.server.path,
        libvirt_cloudinit_disk.vlantest.path,
        libvirt_cloudinit_disk.opnsense_config.path,
      ] : !startswith(p, "/tmp/")
    ])
    error_message = "A cloud-init ISO is in /tmp and will vanish at reboot. Run Terraform with TMPDIR=~/.cache/terraform-tmp (the terraform shell function in ~/.bashrc does this), then recreate the ISO with -replace."
  }
}
