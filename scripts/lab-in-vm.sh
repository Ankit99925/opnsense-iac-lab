#!/usr/bin/env bash
# lab-in-vm.sh: run the lab inside a fresh Ubuntu 26.04 VM, on any Linux with KVM + libvirt.
#
# For machines that are not Ubuntu 26.04 (setup.sh supports only that), and to test
# setup.sh on a truly clean machine. Everything goes through libvirt as your user:
# no sudo, nothing installed on this machine.
#
#   lab-in-vm.sh up        create a FRESH VM (asks before replacing an existing one), wait for SSH
#   lab-in-vm.sh ssh       open a shell in the VM (or: lab-in-vm.sh ssh <command>)
#   lab-in-vm.sh status    show the VM, its address and its network
#   lab-in-vm.sh destroy   delete the VM and its disks (keeps the cached image and network)
#
# Only ever deletes a VM it created itself (it labels them); other VMs are never touched.
# Settings (environment): LAB_VM_RAM_MB (8192), LAB_VM_CPUS (4), LAB_VM_DISK_GB (100),
# LAB_VM_POOL (default), LAB_VM_SSH_PUB (~/.ssh/id_ed25519.pub), LAB_VM_YES=1 (don't ask)
set -euo pipefail

export LIBVIRT_DEFAULT_URI=qemu:///system
NAME="lab-in-vm"
RAM_MB="${LAB_VM_RAM_MB:-8192}"
CPUS="${LAB_VM_CPUS:-4}"
DISK_GB="${LAB_VM_DISK_GB:-100}"
POOL="${LAB_VM_POOL:-default}"
NET="lab-in-vm"
NET_PREFIX="192.168.150"         # must differ from 192.168.122.x, which the lab inside uses
RELEASE="resolute"               # Ubuntu 26.04 LTS
IMG="$RELEASE-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/$RELEASE/current"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lab-in-vm"
KNOWN_HOSTS="$CACHE/known_hosts"  # throwaway VMs never touch ~/.ssh/known_hosts
SSH_PUB="${LAB_VM_SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
mkdir -p "$CACHE" && touch "$KNOWN_HOSTS"

say() { printf '\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# need COMMAND FEDORA_PKG UBUNTU_PKG: stop with install instructions if COMMAND is missing
need() {
  command -v "$1" >/dev/null && return 0
  die "missing: $1
  Fedora:              sudo dnf install $2
  Bazzite / Silverblue: rpm-ostree install $2 (then reboot), or use a distrobox
  Ubuntu / Debian:     sudo apt install $3"
}

preflight() {
  say "Preflight"
  need virsh     libvirt-client  libvirt-clients
  need qemu-img  qemu-img        qemu-utils
  need xorriso   xorriso         xorriso
  need curl      curl            curl
  need sha256sum coreutils       coreutils
  need ssh       openssh-clients openssh-client
  [ -e /dev/kvm ] || die "no /dev/kvm: KVM is not available (virtualization off in the BIOS?)"
  local nested
  nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null | head -1 || true)
  [[ "$nested" == Y || "$nested" == 1 ]] || die "nested virtualization is off (the lab inside the VM needs it)"
  virsh list >/dev/null 2>&1 || die "cannot reach libvirt (qemu:///system): is your user in the libvirt group?"
  virsh pool-info "$POOL" >/dev/null 2>&1 || die "no libvirt storage pool '$POOL', or libvirt's storage daemon is off:
  sudo systemctl enable --now virtstoraged.socket virtstoraged-ro.socket virtstoraged-admin.socket"
  [ -r "$SSH_PUB" ] || die "no SSH public key at $SSH_PUB (create one: ssh-keygen -t ed25519)"
  local avail_mb
  avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  (( avail_mb >= RAM_MB )) || die "only ${avail_mb} MiB RAM available; the VM needs ${RAM_MB} (set LAB_VM_RAM_MB to change)"
  echo "  ok: tools, KVM, nested virtualization, libvirt, pool '$POOL', SSH key, ${avail_mb} MiB free"
}

ensure_network() {
  if ! virsh net-info "$NET" >/dev/null 2>&1; then
    say "Network $NET ($NET_PREFIX.0/24, NAT)"
    virsh net-define /dev/stdin >/dev/null <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <ip address='$NET_PREFIX.1' netmask='255.255.255.0'>
    <dhcp><range start='$NET_PREFIX.100' end='$NET_PREFIX.200'/></dhcp>
  </ip>
</network>
EOF
    virsh net-autostart "$NET" >/dev/null
  fi
  [ "$(virsh net-info "$NET" | awk '/^Active:/ {print $2}')" = yes ] || virsh net-start "$NET" >/dev/null
}

fetch_base() {
  say "Ubuntu 26.04 cloud image"
  curl -fsSL "$IMG_URL/SHA256SUMS" -o "$CACHE/SHA256SUMS"
  local want
  want=$(awk -v f="$IMG" '$2 == f || $2 == "*" f {print $1}' "$CACHE/SHA256SUMS")
  [ -n "$want" ] || die "$IMG is not listed in $IMG_URL/SHA256SUMS"
  if [ ! -f "$CACHE/$IMG" ] || [ "$(sha256sum < "$CACHE/$IMG" | cut -d' ' -f1)" != "$want" ]; then
    echo "  downloading $IMG ..."
    curl -fL --progress-bar "$IMG_URL/$IMG" -o "$CACHE/$IMG.part"
    [ "$(sha256sum < "$CACHE/$IMG.part" | cut -d' ' -f1)" = "$want" ] || die "checksum mismatch: $IMG is corrupt or tampered"
    mv "$CACHE/$IMG.part" "$CACHE/$IMG"
  fi
  BASE_VOL="$NAME-base-${want:0:12}.img"   # a new Ubuntu build gets a new volume name
  if ! virsh vol-info --pool "$POOL" "$BASE_VOL" >/dev/null 2>&1; then
    echo "  uploading it into pool '$POOL' as $BASE_VOL"
    virsh vol-create-as "$POOL" "$BASE_VOL" "$(stat -c %s "$CACHE/$IMG")" --allocation 0 --format raw >/dev/null
    virsh vol-upload --pool "$POOL" "$BASE_VOL" "$CACHE/$IMG"
    virsh pool-refresh "$POOL" >/dev/null
  fi
  echo "  ok: $BASE_VOL (sha256 ${want:0:12}..., verified)"
}

LABEL="created by lab-in-vm.sh"   # written into every VM this script makes

# The script only deletes a VM that carries its label, never one that merely has the name.
ours() { virsh desc "$NAME" 2>/dev/null | grep -F "$LABEL" >/dev/null; }

# confirm WORD WHAT: if our VM exists, the user must type WORD to go ahead (LAB_VM_YES=1 skips)
confirm() {
  virsh dominfo "$NAME" >/dev/null 2>&1 || return 0
  ours || die "a VM named '$NAME' exists but was not created by this script; refusing to touch it"
  [ "${LAB_VM_YES:-}" = 1 ] && return 0
  local answer
  read -r -p "A '$NAME' VM already exists. $2 (everything in it is lost)? Type '$1': " answer
  [ "$answer" = "$1" ] || die "aborted; nothing was changed"
}

destroy_vm() {
  if virsh dominfo "$NAME" >/dev/null 2>&1; then
    ours || die "a VM named '$NAME' exists but was not created by this script; refusing to touch it"
    say "Removing VM $NAME"
    virsh destroy "$NAME" >/dev/null 2>&1 || true
    virsh undefine "$NAME" >/dev/null
  fi
  local v
  for v in "$NAME-disk.qcow2" "$NAME-seed.iso"; do
    if virsh vol-info --pool "$POOL" "$v" >/dev/null 2>&1; then
      virsh vol-delete --pool "$POOL" "$v" >/dev/null
    fi
  done
  return 0
}

create_vm() {
  say "Fresh VM $NAME (${RAM_MB} MiB, $CPUS vCPU, ${DISK_GB} GB disk)"
  local work
  work=$(mktemp -d)
  cat > "$work/user-data" <<EOF
#cloud-config
hostname: lab-host
ssh_authorized_keys:
  - $(cat "$SSH_PUB")
package_update: false
EOF
  # a new instance-id every time, so cloud-init treats each VM as brand new
  printf 'instance-id: %s-%s\nlocal-hostname: lab-host\n' "$NAME" "$(date +%s)" > "$work/meta-data"
  xorriso -as mkisofs -quiet -R -J -V cidata -o "$work/seed.iso" "$work/user-data" "$work/meta-data"
  virsh vol-create-as "$POOL" "$NAME-seed.iso" "$(stat -c %s "$work/seed.iso")" --format raw >/dev/null
  virsh vol-upload --pool "$POOL" "$NAME-seed.iso" "$work/seed.iso"
  rm -rf "$work"
  # thin disk on top of the cloud image; cloud-init grows the filesystem to fill it
  virsh vol-create-as "$POOL" "$NAME-disk.qcow2" "${DISK_GB}G" --format qcow2 \
    --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
  virsh define /dev/stdin >/dev/null <<EOF
<domain type='kvm'>
  <name>$NAME</name>
  <description>$LABEL (opnsense-iac-lab); safe for that script to delete</description>
  <memory unit='MiB'>$RAM_MB</memory>
  <vcpu>$CPUS</vcpu>
  <cpu mode='host-passthrough'/>
  <os><type arch='x86_64' machine='q35'>hvm</type></os>
  <features><acpi/><apic/></features>
  <devices>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source pool='$POOL' volume='$NAME-disk.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='volume' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source pool='$POOL' volume='$NAME-seed.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$NET'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'/>
    <console type='pty'/>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
  </devices>
</domain>
EOF
  virsh start "$NAME" >/dev/null
}

vm_ip() {
  virsh domifaddr "$NAME" --source lease 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

ssh_vm() {
  local ip
  ip=$(vm_ip)
  [ -n "$ip" ] || die "VM $NAME has no address (is it running? $0 status)"
  ssh -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes "ubuntu@$ip" "$@"
}

wait_ssh() {
  say "Waiting for the VM to boot"
  local ip="" end=$((SECONDS + 300))
  until ip=$(vm_ip) && [ -n "$ip" ] && timeout 3 bash -c "</dev/tcp/$ip/22" 2>/dev/null; do
    (( SECONDS < end )) || die "the VM did not come up within 5 minutes (look with: virsh console $NAME)"
    sleep 5
  done
  ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  ssh-keyscan -H "$ip" 2>/dev/null >> "$KNOWN_HOSTS"
  ssh_vm cloud-init status --wait >/dev/null
  echo "  ok: ubuntu@$ip, cloud-init finished"
}

status() {
  virsh dominfo "$NAME" 2>/dev/null | grep -E '^(Name|State|Max memory|CPU\(s\))' || echo "no VM $NAME"
  echo "Address:        $(vm_ip || true)"
  virsh net-info "$NET" 2>/dev/null | grep -E '^(Name|Active)' || echo "no network $NET"
}

case "${1:-}" in
  up)      preflight; confirm replace "Replace it with a fresh one"; ensure_network; fetch_base; destroy_vm; create_vm; wait_ssh
           echo; echo "Fresh VM ready. Shell later with: $0 ssh"
           if [ -t 0 ] && [ -t 1 ]; then   # a person at a terminal: go straight in
             echo "Opening a shell in the VM (exit to leave; the VM keeps running)"; ssh_vm
           fi ;;
  ssh)     shift; ssh_vm "$@" ;;
  status)  status ;;
  destroy) confirm delete "Delete it"; destroy_vm; echo "VM and its disks removed (cached image and network kept)" ;;
  *)       sed -n '2,16p' "$0"; exit 2 ;;
esac
