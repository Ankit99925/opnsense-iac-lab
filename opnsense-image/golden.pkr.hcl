# golden.pkr.hcl: build the OPNsense golden image from the official installer ISO.
#
# Installs OPNsense on UFS, sets root's password, copies the boot hook
# (10-configdisk) into the installed system, and powers off. The result has no
# lab config: that arrives at boot on the config ISO (see render-baseline.py).
#
# Packer cannot see the screen: boot_command is keystrokes and waits, worked out
# by watching a manual install over VNC. If a build stalls, watch it on VNC
# (127.0.0.1:5901 inside the build machine) and lengthen the wait before the
# screen it got stuck on.
#
# Normally run by setup.sh. By hand:
#   PKR_VAR_root_password=... packer build -var iso_path=... -var iso_sha256=... \
#     -var output_dir=... opnsense-image/

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

variable "iso_path" {
  type        = string
  description = "Verified OPNsense DVD ISO (setup.sh checks it against pins.env)"
}

variable "iso_sha256" {
  type        = string
  description = "Its SHA256, from pins.env"
}

variable "output_dir" {
  type        = string
  description = "Where Packer writes golden.qcow2 (must not exist yet)"
}

variable "root_password" {
  type        = string
  sensitive   = true
  description = "OPNsense root password for the image; pass as PKR_VAR_root_password"
}

source "qemu" "golden" {
  iso_url          = var.iso_path
  iso_checksum     = "sha256:${var.iso_sha256}"
  output_directory = var.output_dir
  vm_name          = "golden.qcow2"
  format           = "qcow2"
  disk_size        = "20G"
  disk_interface   = "virtio"
  disk_compression = true
  machine_type     = "pc"
  accelerator      = "kvm"
  memory           = 2048
  cpus             = 2
  headless         = true
  vnc_bind_address = "127.0.0.1"
  vnc_port_min     = 5901
  vnc_port_max     = 5901

  # The hook travels on a small extra CD. QEMU's "pc" machine already has an
  # empty CD drive besides the DVD, so the hook's drive number is not fixed:
  # the shell step below searches every /dev/cd* for it.
  cd_files = ["${path.root}/10-configdisk"]
  cd_label = "HOOK"

  # Two NICs (user-mode networking, isolated) so the installer's default
  # LAN/WAN assignment finds both interfaces and never stops to ask.
  qemuargs = [
    ["-netdev", "user,id=wan"], ["-device", "virtio-net,netdev=wan"],
    ["-netdev", "user,id=lan"], ["-device", "virtio-net,netdev=lan"],
  ]

  # No login over the network: the VM powers itself off at the end, and Packer
  # waits for that. If anything fails, it never powers off and the build times out.
  communicator     = "none"
  shutdown_timeout = "20m"

  boot_wait = "5s"
  boot_command = [
    # DVD boots to login; its timed prompts (config importer etc.) pass by themselves
    "<wait4m>",
    # login as the installer
    "installer<enter><wait3>",
    "opnsense<enter><wait10>",
    # Keymap Selection: keep the default
    "<enter><wait5>",
    # main menu: ZFS is highlighted; one Down to Install (UFS)
    "<down><enter><wait5>",
    # UFS Configuration: RAM warning, "Proceed anyway" is highlighted
    "<enter><wait5>",
    # UFS Configuration: disk vtbd0, OK
    "<enter><wait5>",
    # Last chance: No is highlighted; Left to Yes. Install takes ~4 min
    "<left><enter><wait6m>",
    # Final Configuration: Root Password (asked twice)
    "<enter><wait3>",
    "${var.root_password}<enter><wait3>",
    "${var.root_password}<enter><wait5>",
    # Final Configuration: one Down to Complete Install
    "<down><enter><wait5>",
    # Installation Complete: Reboot now. Installed system boots in ~1-2 min
    "<enter><wait3m>",
    # log in as root, open the shell (menu option 8)
    "root<enter><wait3>",
    "${var.root_password}<enter><wait5>",
    "8<enter><wait3>",
    # root's shell is csh, so the steps run under sh. Find the hook CD, install
    # the hook, make sure no config fingerprint exists, power off. Any failure
    # stops the chain, so the VM stays up and the build times out instead.
    "sh -c 'mkdir -p /tmp/h /usr/local/etc/rc.syshook.d/early && for d in /dev/cd*; do mount -t cd9660 -o ro $d /tmp/h 2>/dev/null && [ -f /tmp/h/10-configdisk ] && break; umount /tmp/h 2>/dev/null; done && cp /tmp/h/10-configdisk /usr/local/etc/rc.syshook.d/early/ && chmod 755 /usr/local/etc/rc.syshook.d/early/10-configdisk && umount /tmp/h && rm -f /conf/configdisk.sha256 && shutdown -p now'<enter>",
  ]
}

build {
  sources = ["source.qemu.golden"]
}
