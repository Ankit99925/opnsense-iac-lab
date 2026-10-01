#!/usr/bin/env bash
# rebuild.sh: build the lab from code, or bring it back in line with the code.
#
#   rebuild.sh                  converge: build what is missing, fix drift, keep the rest
#   rebuild.sh --fresh          destroy everything first, then build from nothing
#   rebuild.sh --fresh --yes    same, without the confirmation prompt
#
# Needs the files listed in REBUILD.md under "Files that are NOT in git".
set -euo pipefail

# Everything in the repo is found relative to this script,
# so the repo works wherever it is cloned.
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TF_DIR="$REPO_DIR/terraform"
ANSIBLE_DIR="$REPO_DIR/ansible"
POLICY_DIR="$REPO_DIR/policy"
# Outside the repo, never in git: backups and API credentials.
BACKUP_DIR="${BACKUP_DIR:-$HOME/lab-backup}"
CREDS="${CREDS:-$HOME/.config/opnsense-iac-lab/api.env}"   # automation user, made by gen-secrets.sh
GOLDEN="opnsense-26.1-golden-v2.qcow2"
SERVER_IP=192.168.100.10
# The libvirt provider writes cloud-init ISOs to $TMPDIR; /tmp is tmpfs here.
export TMPDIR="$HOME/.cache/terraform-tmp"

FRESH=0; YES=0
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1 ;;
    --yes)   YES=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 2 ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# wait_for "description" max_seconds command...: retry every 5 s until it succeeds
wait_for() {
  local desc="$1" secs="$2"; shift 2
  local end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || die "timed out after ${secs}s waiting for: $desc"
    sleep 5
  done
  echo "  ok: $desc"
}

api_up() {
  [ "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' -u "$OPN_KEY:$OPN_SECRET" \
       "https://$OPN_HOST/api/core/firmware/status")" = 200 ]
}

# ------------------------------------------------------------------ preflight
step "Preflight"
for c in virsh terraform ansible ansible-playbook curl dig python3 perl openssl ssh-keyscan; do
  command -v "$c" >/dev/null || die "missing command: $c (see bootstrap in REBUILD.md)"
done
virsh uri >/dev/null 2>&1 || die "cannot talk to libvirt (are you in the libvirt group?)"
virsh pool-refresh default >/dev/null 2>&1 || die "libvirt storage pool 'default' not found"
virsh vol-info --pool default "$GOLDEN" >/dev/null 2>&1 \
  || die "golden image $GOLDEN not in pool 'default' (REBUILD.md: Building the OPNsense image)"
[ -r "$TF_DIR/terraform.tfvars" ]                || die "missing $TF_DIR/terraform.tfvars"
[ -r "$ANSIBLE_DIR/host_vars/localhost.yml" ]     || die "missing host_vars/localhost.yml (USB adapter name)"
[ -r "$ANSIBLE_DIR/host_vars/ubuntu-server.yml" ] || die "missing host_vars/ubuntu-server.yml (Pi-hole password)"
[ -r "$HOME/.ssh/id_ed25519" ]                    || die "missing SSH key ~/.ssh/id_ed25519"
[ -r "$REPO_DIR/network.json" ]                  || die "missing network.json in the repo"
[ -r "$HOME/.ssh/id_ed25519.pub" ]               || die "missing SSH public key ~/.ssh/id_ed25519.pub"
mkdir -p "$TMPDIR" && chmod 700 "$TMPDIR"
echo "  ok: tools, libvirt, golden image, host files"

# ------------------------------------------------------- secrets and baseline
step "Secrets and baseline config"
# Secrets are created once and kept; the baseline is re-rendered every run but
# is byte-identical unless an input changed, so OPNsense only reloads on a real change.
"$REPO_DIR/scripts/gen-secrets.sh"
"$REPO_DIR/scripts/render-baseline.py"
source "$CREDS"

# -------------------------------------------------------------- config backup
step "OPNsense config backup"
# /api/core/backup/download/this returns the newest entry in OPNsense's
# configuration history, not necessarily the live config. Right after a rebuild
# (config loaded by the boot hook, which bypasses the history) that entry is the
# golden image's factory config. So a download is only accepted if it looks like
# the lab's config; otherwise the existing 'latest' is kept.
latest="$BACKUP_DIR/config-OPNsense-latest.xml"
if api_up; then
  out="$BACKUP_DIR/config-OPNsense-$(date +%F-%H%M%S).xml"
  curl -sk --max-time 20 -u "$OPN_KEY:$OPN_SECRET" \
    "https://$OPN_HOST/api/core/backup/download/this" -o "$out.part" || true
  [ -f "$out.part" ] && chmod 600 "$out.part"
  if ! { head -n 2 "$out.part" | grep -q '<opnsense>' && ! grep -q 'BEGIN config.xml' "$out.part"; }; then
    rm -f "$out.part"
    die "OPNsense answered but the backup download was not a valid unencrypted config"
  elif grep -q '<trigger_initial_wizard' "$out.part" || ! grep -q 'vlan01' "$out.part"; then
    mv "$out.part" "$out.rejected"
    echo "  WARNING: the download looks like a factory-default config, not the lab's."
    echo "           Kept $(readlink "$latest"); rejected copy: $(basename "$out.rejected")"
  elif cmp -s "$out.part" "$latest"; then
    rm -f "$out.part"
    echo "  ok: config unchanged since $(readlink "$latest")"
  else
    mv "$out.part" "$out"
    ln -sfn "$(basename "$out")" "$latest"
    echo "  ok: saved $(basename "$out"), now 'latest'"
  fi
else
  echo "  OPNsense API not answering with this key: no backup taken (backups are only a safety net)"
fi

# --------------------------------------------------------------- host bridges
step "Host bridges (Ansible; asks for your sudo password)"
# Idempotent: if the bridges already match, nothing changes and running VMs stay plugged in.
( cd "$ANSIBLE_DIR" && ansible-playbook -i inventory.ini bridge.yml -K )

# -------------------------------------------------------------------- destroy
if (( FRESH )); then
  step "Destroy everything (--fresh)"
  if (( ! YES )); then
    read -r -p "This destroys every lab VM and network. Type 'destroy' to continue: " ans
    [ "$ans" = destroy ] || die "aborted"
  fi
  # The golden image is not managed by Terraform, so destroy never touches it.
  ( cd "$TF_DIR" && terraform destroy -input=false -auto-approve )
  # policy/'s state describes rules inside the firewall that was just destroyed.
  # Forget it, so the new firewall gets its policy created from scratch.
  rm -f "$POLICY_DIR/terraform.tfstate" "$POLICY_DIR/terraform.tfstate.backup"
fi

# ------------------------------------------------------------------ terraform
step "Terraform (networks and VMs; VMs start themselves)"
cd "$TF_DIR"
terraform init -input=false >/dev/null
terraform plan -input=false -out=rebuild.tfplan
terraform apply -input=false rebuild.tfplan
rm -f rebuild.tfplan

# ------------------------------------------------------------------- OPNsense
step "Waiting for OPNsense (boot, config load, one reboot)"
wait_for "OPNsense API answers with the lab config" 600 api_up

# ------------------------------------------------------------------- policy
step "Firewall policy (Terraform, policy/)"
export OPNSENSE_API_KEY="$OPN_KEY" OPNSENSE_API_SECRET="$OPN_SECRET"
cd "$POLICY_DIR"
terraform init -input=false >/dev/null
terraform plan -input=false -out=rebuild.tfplan
terraform apply -input=false rebuild.tfplan
rm -f rebuild.tfplan

# -------------------------------------------------------------- ubuntu server
step "Ubuntu server"
wait_for "SSH port open on $SERVER_IP" 600 timeout 3 bash -c "</dev/tcp/$SERVER_IP/22"
# Trust on first use: accept whatever key the (possibly new) server presents.
# Acceptable on this isolated lab network; the old key would otherwise block Ansible.
ssh-keygen -R "$SERVER_IP" >/dev/null 2>&1 || true
ssh-keyscan -H "$SERVER_IP" 2>/dev/null >> "$HOME/.ssh/known_hosts"
cd "$ANSIBLE_DIR"
ansible ubuntu-server -i inventory.ini -m wait_for_connection -a timeout=300 >/dev/null
ansible ubuntu-server -i inventory.ini -m command -a "cloud-init status --wait" >/dev/null
echo "  ok: server reachable, cloud-init finished"

# -------------------------------------------------------------------- pi-hole
step "Pi-hole (Ansible)"
ansible-playbook -i inventory.ini pihole.yml

# ---------------------------------------------------------------------- smoke
step "Smoke tests"
TRIES=60 "$REPO_DIR/scripts/smoke.sh"

printf '\n\033[32mLab rebuilt and verified.\033[0m\n'
