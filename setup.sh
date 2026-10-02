#!/usr/bin/env bash
# setup.sh: turn a fresh Ubuntu 26.04 machine into this lab, in one run.
#
#   ./setup.sh
#
# Supports Ubuntu 26.04 LTS only. On any other Linux with KVM, run the lab inside
# an Ubuntu VM instead:  scripts/lab-in-vm.sh up
#
# Safe to run again: every step checks first and skips what is already done.
# Run it as your normal user; it asks for your sudo password once.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { echo "  ok: $*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Everything the lab needs from Ubuntu's own repositories
APT_PACKAGES=(
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients  # VMs
  xorriso bind9-dnsutils curl git gnupg python3 perl openssl        # scripts, ISOs, smoke tests
  ansible-core                                                      # host bridges, Pi-hole
)
# HashiCorp's Linux package signing key (Terraform, Packer). Rotated 2026-09-09; the new
# fingerprint was checked against https://www.hashicorp.com/trust/security (a different host
# from the repository) on 2026-10-02. Old key was 798AEC654E5C15428C8E42EEAA16FCBCA621E701.
HASHICORP_FPR="D55C0D1AC78A8D8126CB631CFC9CA96ACA026560"
VIRSH="sudo virsh -c qemu:///system"

check_system() {
  step "System"
  [ "$(id -u)" -ne 0 ] || die "run this as your normal user (it uses sudo where needed), not as root"
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 26.04 ]; then
    die "this needs Ubuntu 26.04 LTS (found: ${PRETTY_NAME:-unknown}).
  On another Linux with KVM, run the lab in an Ubuntu VM: scripts/lab-in-vm.sh up"
  fi
  [ -e /dev/kvm ] || die "no /dev/kvm: hardware virtualization is off or unavailable"
  # Passwordless users: "sudo -v" can still ask (it requires EVERY matching sudoers rule to
  # be NOPASSWD), so try a harmless command first; only then ask for the password.
  sudo -n true 2>/dev/null || sudo -v || die "this needs sudo"
  ok "$PRETTY_NAME, KVM available, sudo works"
}

install_packages() {
  step "Packages from Ubuntu"
  local p missing=()
  for p in "${APT_PACKAGES[@]}"; do
    [ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "  installing: ${missing[*]}"
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
  fi
  ok "${#APT_PACKAGES[@]} packages present"
}

install_hashicorp() {
  step "Terraform and Packer (HashiCorp's repository)"
  local key=/usr/share/keyrings/hashicorp-archive-keyring.gpg
  local list=/etc/apt/sources.list.d/hashicorp.list
  local have="" changed=0
  [ -f "$key" ] && have=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
  if [ "$have" != "$HASHICORP_FPR" ]; then           # missing, or an old (rotated) key
    local tmp fpr
    tmp=$(mktemp)
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor > "$tmp"
    fpr=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
    if [ "$fpr" != "$HASHICORP_FPR" ]; then
      rm -f "$tmp"
      die "HashiCorp's signing key has an unexpected fingerprint ($fpr); not trusting it.
  Check https://www.hashicorp.com/trust/security before changing HASHICORP_FPR."
    fi
    sudo install -m 0644 "$tmp" "$key" && rm -f "$tmp"
    echo "  installed HashiCorp's signing key (fingerprint verified)"
    changed=1
  fi
  if [ ! -f "$list" ]; then
    local suite
    # HashiCorp adds new Ubuntu releases some time after they ship; fall back to the previous LTS
    suite=$(. /etc/os-release; echo "$VERSION_CODENAME")
    curl -fsI "https://apt.releases.hashicorp.com/dists/$suite/Release" >/dev/null 2>&1 || suite=noble
    echo "deb [signed-by=$key] https://apt.releases.hashicorp.com $suite main" | sudo tee "$list" >/dev/null
    echo "  added HashiCorp's repository (suite: $suite)"
    changed=1
  fi
  [ "$changed" = 0 ] || sudo apt-get update -q
  if ! command -v terraform >/dev/null || ! command -v packer >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q terraform packer
  fi
  ok "$(terraform version | head -1), $(packer version | head -1)"
}

setup_groups() {
  step "Groups"
  local g
  for g in libvirt kvm; do
    if [[ " $(id -nG "$USER") " != *" $g "* ]]; then
      sudo usermod -aG "$g" "$USER"
      echo "  added $USER to $g (applies to new logins)"
    fi
  done
  ok "$USER is in libvirt and kvm"
}

# true if Terraform's state in this repo already manages libvirt's 'default' network
terraform_owns_default_network() {
  local state="$REPO_DIR/terraform/terraform.tfstate"
  [ -f "$state" ] || return 1
  python3 - "$state" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
sys.exit(0 if any(r.get("type") == "libvirt_network" and r.get("name") == "default"
                  for r in s.get("resources", [])) else 1)
EOF
}

setup_libvirt() {
  step "libvirt"
  $VIRSH list >/dev/null || die "libvirt is installed but not answering"
  # libvirt ships its own 'default' NAT network; Terraform (terraform/default_network.tf)
  # creates the lab's. Remove the stock one, but never one Terraform already manages.
  if $VIRSH net-info default >/dev/null 2>&1; then
    if terraform_owns_default_network; then
      ok "'default' network is managed by Terraform here: left alone"
    else
      $VIRSH net-destroy default >/dev/null 2>&1 || true
      $VIRSH net-undefine default >/dev/null
      ok "removed libvirt's stock 'default' network (Terraform creates the lab's)"
    fi
  else
    ok "no stock 'default' network"
  fi
  if ! $VIRSH pool-info default >/dev/null 2>&1; then
    $VIRSH pool-define-as default dir --target /var/lib/libvirt/images >/dev/null
    $VIRSH pool-build default >/dev/null
    $VIRSH pool-start default >/dev/null
    $VIRSH pool-autostart default >/dev/null
  fi
  ok "storage pool 'default'"
}

setup_user() {
  step "Your account"
  if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
    echo "  created ~/.ssh/id_ed25519"
  fi
  if ! grep -F 'terraform()' "$HOME/.bashrc" >/dev/null 2>&1; then
    cat >> "$HOME/.bashrc" <<'EOF'

# Terraform: the libvirt provider writes cloud-init ISOs to $TMPDIR; /tmp is tmpfs.
terraform() { TMPDIR="$HOME/.cache/terraform-tmp" command terraform "$@"; }
EOF
    echo "  added the terraform shell function to ~/.bashrc"
  fi
  ok "SSH key, terraform shell function"
}

check_system
# keep sudo's timestamp fresh during long installs; stops when this script ends
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &

install_packages
install_hashicorp
setup_groups
setup_libvirt
setup_user

step "Part 1 done"
echo "  Not written yet: the golden image (Packer), machine values, then the lab build."
