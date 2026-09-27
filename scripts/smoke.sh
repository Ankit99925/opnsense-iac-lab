#!/usr/bin/env bash
# smoke.sh: quick checks that the lab works, bottom layer first.
# Read-only. Stops at the first failure and exits non-zero.
# TRIES=1 ./smoke.sh   -> no retries (fast, for a lab that is already up)
set -uo pipefail

ANSIBLE_DIR="${ANSIBLE_DIR:-$HOME/ansible/lab}"
CREDS="${CREDS:-$HOME/python/opnwatch/creds.env}"
TAPCHECK="${TAPCHECK:-$HOME/ops/libexec/tapcheck}"
SERVER_IP=192.168.100.10
VLANTEST_NET=10.20.10.   # vlantest's VLAN in the code (cloud-init: VLAN 10)
TRIES="${TRIES:-24}"     # 24 tries x 5 s = up to 2 minutes per check
WAIT=5
LAYER=""

layer() { LAYER="$1"; echo "== $1"; }
pass()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; echo "Smoke test failed at layer: $LAYER"; exit 1; }

# check "description" test_function: retry until it succeeds, or fail
check() {
  local desc="$1"; shift
  for ((i = 1; i <= TRIES; i++)); do
    if "$@" >/dev/null 2>&1; then pass "$desc"; return 0; fi
    ((i < TRIES)) && sleep "$WAIT"
  done
  fail "$desc"
}

source "$CREDS" || { echo "cannot read $CREDS"; exit 1; }

# --- the tests -------------------------------------------------------------
t_bridges()  { ip -br link show br-clients | grep -qw UP && ip -br link show br-trunk | grep -qw UP; }
t_vms()      { local r; r=$(virsh list --name); for v in opnsense ubuntu-server vlantest; do grep -qx "$v" <<<"$r" || return 1; done; }
t_api()      { [ "$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' -u "$OPN_KEY:$OPN_SECRET" "https://$OPN_HOST/api/core/firmware/status")" = 200 ]; }
t_route()    { ip route | grep -q '^192.168.100.0/24 via 192.168.122.69'; }
t_ssh()      { (cd "$ANSIBLE_DIR" && ansible ubuntu-server -i inventory.ini -m ping); }
t_dns()      { dig @"$SERVER_IP" example.com +short +time=2 +tries=1 | grep -qE '^[0-9.]+$'; }
t_internet() { (cd "$ANSIBLE_DIR" && ansible ubuntu-server -i inventory.ini -m command -a "curl -sfI --max-time 5 https://example.com"); }
t_vlan()     { curl -sk --max-time 5 -u "$OPN_KEY:$OPN_SECRET" "https://$OPN_HOST/api/kea/leases4/search" \
                 | python3 -c 'import json,sys; rows=json.load(sys.stdin).get("rows",[]); sys.exit(0 if any(r.get("hostname")=="vlantest" and r.get("address","").startswith(sys.argv[1]) for r in rows) else 1)' "$VLANTEST_NET"; }

# guest_run CMD ARGS...: run a command inside vlantest through the guest agent,
# wait for it, and return its exit code (99 if the agent itself failed).
guest_run() {
  local req pid out code
  req=$(python3 -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":sys.argv[1],"arg":sys.argv[2:],"capture-output":True}}))' "$@")
  pid=$(virsh qemu-agent-command vlantest "$req" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])') || return 99
  for _ in $(seq 1 20); do
    out=$(virsh qemu-agent-command vlantest "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}") || return 99
    code=$(python3 -c 'import json,sys; r=json.loads(sys.argv[1])["return"]; print(r.get("exitcode",99) if r.get("exited") else "")' "$out")
    [ -n "$code" ] && return "$code"
    sleep 1
  done
  return 99
}
t_agent()      { virsh qemu-agent-command vlantest '{"execute":"guest-ping"}'; }
t_vlan_out()   { guest_run /usr/bin/ping -c 2 -W 2 8.8.8.8; }                    # must work
t_gw_blocked() { guest_run /usr/bin/ping -c 2 -W 2 10.20.10.1; [ $? -eq 1 ]; }   # ping exit 1 = no replies

# --- run them, bottom layer first ------------------------------------------
layer "1 host"
check "bridges br-clients and br-trunk are UP"           t_bridges
check "VMs running: opnsense, ubuntu-server, vlantest"   t_vms
check "every VM NIC on the right bridge (tapcheck)"      "$TAPCHECK"

layer "2 OPNsense"
check "API returns 200 (config and API key loaded)"      t_api

layer "3 routing"
check "host route to SERVERS via OPNsense WAN"           t_route
check "host reaches ubuntu-server over SSH"              t_ssh

layer "4 services"
check "Pi-hole answers DNS"                              t_dns
check "server reaches the internet through OPNsense"     t_internet

layer "5 VLANs"
check "Kea leased vlantest an address on VLAN 10"        t_vlan

layer "6 firewall rules (from inside vlantest, via the guest agent)"
check "guest agent in vlantest answers"                  t_agent
check "vlantest reaches the internet (positive control)" t_vlan_out
check "vlantest cannot ping its gateway (block rule)"    t_gw_blocked

echo "All smoke tests passed."
