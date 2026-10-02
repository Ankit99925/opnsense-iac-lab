#!/usr/bin/env bash
# gen-secrets.sh: create the lab's secrets once; never overwrite existing ones.
# Safe to run any time: only missing files are created (idempotent).
#
# Output in $SECRETS_DIR (default ~/.config/opnsense-iac-lab), dir 700, files 600:
#   root-password        OPNsense root password (break-glass console login)
#   root-password.hash   its SHA-512 crypt hash, written into the baseline config
#   console-password     break-glass console password for the lab's Ubuntu VMs
#   console-password.hash  its hash, written into terraform.tfvars by setup.sh
#   pihole-password      Pi-hole admin password, written into host_vars by setup.sh
#   api.env              OPN_KEY / OPN_SECRET / OPN_HOST for the automation user
#   webgui.crt / .key    self-signed certificate for OPNsense's web GUI and API
set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-$HOME/.config/opnsense-iac-lab}"
OPN_HOST="${OPN_HOST:-192.168.122.69}"
umask 077                                  # every new file: owner-only
mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
cd "$SECRETS_DIR"

# new FILE: true (and says "created") only if FILE does not exist yet
new() { if [ -e "$1" ]; then echo "  kept:    $1"; return 1; fi; echo "  created: $1"; }

if new root-password; then
  openssl rand -base64 18 > root-password
fi
if new root-password.hash; then
  openssl passwd -6 -stdin < root-password > root-password.hash
fi
if new console-password; then
  openssl rand -base64 18 > console-password
fi
if new console-password.hash; then
  openssl passwd -6 -stdin < console-password > console-password.hash
fi
if new pihole-password; then
  openssl rand -base64 24 | tr -d '/+=' | cut -c1-24 > pihole-password
fi
if new api.env; then
  # 60 random bytes -> 80 base64 characters, the same length OPNsense uses
  printf 'OPN_KEY=%s\nOPN_SECRET=%s\nOPN_HOST=%s\n' \
    "$(openssl rand -base64 60 | tr -d '\n')" \
    "$(openssl rand -base64 60 | tr -d '\n')" \
    "$OPN_HOST" > api.env
fi
if new webgui.key; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=opnsense-iac-lab" -addext "subjectAltName=IP:$OPN_HOST" \
    -keyout webgui.key -out webgui.crt 2>/dev/null
fi
chmod 600 root-password root-password.hash console-password console-password.hash pihole-password api.env webgui.key webgui.crt
