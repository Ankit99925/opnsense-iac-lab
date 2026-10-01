variable "opnsense_config_xml" {
  description = "Baseline config.xml from scripts/render-baseline.py, loaded at boot by the golden image's hook"
  default     = "~/.cache/opnsense-iac-lab/baseline.xml"
}

# Config ISO for OPNsense. The boot hook in the golden image
# (opnsense-image/10-configdisk) reads user-data from it and loads it
# as /conf/config.xml, rebooting once when the file is new.
# Note: the full config, secrets included, is stored in Terraform state.
resource "libvirt_cloudinit_disk" "opnsense_config" {
  name      = "lab-opnsense-config.iso"
  meta_data = yamlencode({ instance-id = "opnsense-config" })
  user_data = file(pathexpand(var.opnsense_config_xml))
}

variable "opnsense_golden_image" {
  description = "Installed OPNsense + boot hook, no config. Built by hand (later Packer). Read-only."
  default     = "/var/lib/libvirt/images/opnsense-26.1-golden-v2.qcow2"
}
