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

step() { printf '\n\033[1m== [%s] %s\033[0m\n' "$(date +%T)" "$*"; }
ok()   { echo "  ok: $*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Everything the lab needs from Ubuntu's own repositories
APT_PACKAGES=(
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients  # VMs
  xorriso bzip2 bind9-dnsutils curl git gnupg python3 perl openssl  # scripts, ISOs, smoke tests
  ansible-core                                                      # host bridges, Pi-hole
)
# Pinned versions, checksums and signing keys live in pins.env: one place to update them.
# shellcheck disable=SC1091
. "$REPO_DIR/pins.env"
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
  Check https://www.hashicorp.com/trust/security before changing HASHICORP_FPR in pins.env."
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

# Ansible collections (add-on module packs), pinned in ansible/requirements.yml.
# ansible-core alone doesn't include them; installing them explicitly makes this repeatable.
install_collections() {
  step "Ansible collections (ansible/requirements.yml)"
  ansible-galaxy collection install -r "$REPO_DIR/ansible/requirements.yml" >/dev/null
  ok "$(ansible-galaxy collection list community.docker 2>/dev/null | awk '/^community.docker/ {print $1, $2}')"
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

setup_machine_values() {
  step "Machine values"
  "$REPO_DIR/scripts/gen-secrets.sh"
  local secrets="${SECRETS_DIR:-$HOME/.config/opnsense-iac-lab}" f old_umask
  old_umask=$(umask); umask 077          # these files hold password hashes

  f="$REPO_DIR/terraform/terraform.tfvars"
  if [ ! -f "$f" ]; then
    cat > "$f" <<EOF
# Generated by setup.sh for this machine. setup.sh never overwrites it.
qemu_uid              = "$(id -u libvirt-qemu)"
kvm_gid               = "$(getent group kvm | cut -d: -f3)"
console_password_hash = "$(cat "$secrets/console-password.hash")"
EOF
    echo "  created terraform/terraform.tfvars"
  fi

  f="$REPO_DIR/ansible/host_vars/ubuntu-server.yml"
  if [ ! -f "$f" ]; then
    printf '# Generated by setup.sh. setup.sh never overwrites it.\npihole_web_password: "%s"\n' \
      "$(cat "$secrets/pihole-password")" > "$f"
    echo "  created ansible/host_vars/ubuntu-server.yml"
  fi

  f="$REPO_DIR/ansible/host_vars/localhost.yml"
  if [ ! -f "$f" ]; then
    local nic="${LAB_CLIENTS_NIC:-}" nics="[]" become=""
    if [ -n "$nic" ]; then
      ip link show "$nic" >/dev/null 2>&1 || die "LAB_CLIENTS_NIC=$nic: no such network interface (list them: ip -br link)"
      nics="[\"$nic\"]"
    fi
    if [[ "$(sudo --version 2>/dev/null)" == *sudo-rs* ]] && command -v sudo.ws >/dev/null; then
      become="ansible_become_exe: sudo.ws   # sudo-rs can stall Ansible's become prompt"
    fi
    cat > "$f" <<EOF
# Generated by setup.sh. setup.sh never overwrites it.
# br-clients' physical adapter: set LAB_CLIENTS_NIC=enx... before running setup.sh.
# nics: [] means CLIENTS exists with nothing plugged in (no Wi-Fi AP).
$become
bridges:
  - name: br-clients
    nics: $nics
  - name: br-trunk
    nics: []
EOF
    echo "  created ansible/host_vars/localhost.yml (CLIENTS adapter: ${nic:-none})"
  fi

  umask "$old_umask"
  ok "terraform.tfvars and host_vars present (existing files are never changed)"
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# The OPNsense installer ISO, checked against pins.env and cached.
# LAB_OPNSENSE_ISO may name a local .iso or .iso.bz2 (e.g. a copy from another machine) to
# skip the slow download. It must pass the same pinned checksums, so it is just as trustworthy.
OPNSENSE_ISO_DIR="$HOME/.cache/opnsense-iac-lab/iso"
get_opnsense_iso() {
  step "OPNsense $OPNSENSE_VERSION installer"
  local name="OPNsense-$OPNSENSE_VERSION-dvd-amd64.iso" src="${LAB_OPNSENSE_ISO:-}"
  OPNSENSE_ISO="$OPNSENSE_ISO_DIR/$name"
  local bz2="$OPNSENSE_ISO.bz2" part="$OPNSENSE_ISO.part"
  mkdir -p "$OPNSENSE_ISO_DIR"

  if [ -f "$OPNSENSE_ISO" ] && [ "$(sha256 "$OPNSENSE_ISO")" = "$OPNSENSE_ISO_SHA256" ]; then
    ok "$name (cached, checksum verified)"
    return 0
  fi

  if [ -n "$src" ]; then
    [ -f "$src" ] || die "LAB_OPNSENSE_ISO=$src: no such file"
    echo "  using a local copy: $src"
    case "$src" in
      *.bz2) cp "$src" "$bz2" ;;
      *)     cp "$src" "$part" ;;
    esac
  elif [ ! -f "$bz2" ] || [ "$(sha256 "$bz2")" != "$OPNSENSE_BZ2_SHA256" ]; then
    echo "  downloading $OPNSENSE_URL (about 470 MB; resumes if interrupted)"
    curl -fL -C - --progress-bar -o "$bz2" "$OPNSENSE_URL"
  fi

  if [ -f "$bz2" ]; then
    if [ "$(sha256 "$bz2")" != "$OPNSENSE_BZ2_SHA256" ]; then
      rm -f "$bz2"
      die "$name.bz2 does not match OPNSENSE_BZ2_SHA256 in pins.env (deleted it; run setup.sh again)"
    fi
    echo "  decompressing (about 2 GB)"
    bunzip2 -c "$bz2" > "$part"
    rm -f "$bz2"
  fi

  if [ "$(sha256 "$part")" != "$OPNSENSE_ISO_SHA256" ]; then
    rm -f "$part"
    die "$name does not match OPNSENSE_ISO_SHA256 in pins.env (deleted it)"
  fi
  mv "$part" "$OPNSENSE_ISO"
  ok "$name (both pinned checksums verified)"
}

# The golden image: installed OPNsense + boot hook, built from the verified ISO by Packer.
build_golden() {
  step "Golden image (Packer)"
  local name="opnsense-$OPNSENSE_VERSION-golden-v2.qcow2"
  local dest="/var/lib/libvirt/images/$name"
  local out="$HOME/.cache/opnsense-iac-lab/golden-build"
  local secrets="${SECRETS_DIR:-$HOME/.config/opnsense-iac-lab}"
  if sudo test -f "$dest"; then
    ok "$name already built"
    return 0
  fi
  rm -rf "$out"
  packer init "$REPO_DIR/opnsense-image" >/dev/null
  echo "  building from the ISO: about 20 minutes, typing into the installer"
  echo "  (watch it over VNC on 127.0.0.1:5901 here; from another machine: scripts/lab-in-vm.sh vnc)"
  # sg kvm: Packer needs /dev/kvm, i.e. the kvm group, which this run may only just have added
  PKR_VAR_root_password="$(cat "$secrets/root-password")" sg kvm -c \
    "packer build -var iso_path=$OPNSENSE_ISO -var iso_sha256=$OPNSENSE_ISO_SHA256 -var output_dir=$out $REPO_DIR/opnsense-image"
  sudo install -o libvirt-qemu -g kvm -m 0440 "$out/golden.qcow2" "$dest"
  $VIRSH pool-refresh default >/dev/null
  rm -rf "$out"
  ok "$name built and placed in the storage pool (read-only)"
}

# The lab itself. On a fresh machine, rebuild.sh's converge mode builds everything.
run_lab() {
  step "The lab (scripts/rebuild.sh)"
  # sg libvirt: talking to libvirt needs the libvirt group, which this run may only just have added
  sg libvirt -c "$REPO_DIR/scripts/rebuild.sh"
}

check_system
# keep sudo's timestamp fresh during long installs; stops when this script ends
( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &

install_packages
install_hashicorp
install_collections
setup_groups
setup_libvirt
setup_user
setup_machine_values
get_opnsense_iso
build_golden
run_lab
