# lab

Two playbooks. One configures the host's network bridges; the other deploys
Pi-hole onto the lab's Ubuntu server.

The infrastructure these sit on is in `~/terraform/lab`, and its README is the
runbook for the lab as a whole.

## Inventory

| Group     | Host            | Reached by                          |
|-----------|-----------------|-------------------------------------|
| `host`    | `localhost`     | local connection, no ssh            |
| `servers` | `ubuntu-server` | ssh to 192.168.100.10 as `ubuntu`   |

Reaching `servers` depends on a route the host has to the SERVERS network via
OPNsense. If Ansible cannot connect, check that first:

    ip route | grep 192.168.100

---

## bridge.yml

Creates `br-clients` and `br-trunk` on the host by writing one netplan file
from a template.

    ansible-playbook -i inventory.ini bridge.yml -K --check --diff
    ansible-playbook -i inventory.ini bridge.yml -K

`br-clients` has the USB ethernet adapter as a port, and carries the CLIENTS
zone to a Buffalo access point. `br-trunk` has no physical port at all — it
exists so OPNsense and a test VM can exchange VLAN-tagged frames.

### Stop the VMs first

`netplan apply` restarts NetworkManager, which rebuilds both bridges with only
the ports it knows about. libvirt's tap devices are not among them, so any VM
attached to these bridges is silently unplugged — it keeps running, but its
cable is out.

Either stop OPNsense before running this, or check afterwards:

    ops tapcheck

and restart OPNsense if it reports anything. `virsh start` makes libvirt
reattach everything.

### Both bridges have no IP address

`link-local: []`, `accept-ra: false`, and NetworkManager passthrough setting
both `ipv4.method` and `ipv6.method` to `disabled`.

A bridge does not need an address to forward frames — a switch in a cupboard
has none. An address would make the host a participant on that network,
reachable from CLIENTS without passing through OPNsense, which is exactly what
the segmentation exists to prevent.

Two levels were needed: `link-local: []` alone leaves NetworkManager's method
as `ignore`, and the kernel then assigns an IPv6 link-local address anyway.
`disabled` is what stops it.

Check with:

    ip -br addr show type bridge
    cat /proc/sys/net/ipv6/conf/br-clients/disable_ipv6   # 1 means off

### Adding a bridge

Add an entry to `bridges` in `host_vars/localhost.yml`. `nics: []` for a purely
virtual one. The template loops over the list.

---

## pihole.yml

Installs Docker, writes a compose file, and starts Pi-hole on the server.

    ssh-keygen -R 192.168.100.10     # only after the server has been rebuilt
    ansible-playbook -i inventory.ini pihole.yml

### The port 53 problem

Ubuntu runs `systemd-resolved`, which listens on port 53 — but only on
`127.0.0.53`. Pi-hole is published on `192.168.100.10:53` specifically, so the
two never collide and nothing on the host needs disabling.

A port is only in use on a particular address, not on the whole machine.

### Settings

`FTLCONF_dns_listeningMode=all` matters. By default Pi-hole answers only its
own subnet. Clients here are on CLIENTS and the VLANs, arriving via OPNsense,
so without this it ignores them silently.

The admin password is in `host_vars/ubuntu-server.yml`, which is gitignored.
Pi-hole hashes it itself, so it goes in as plain text — unlike the console
password in Terraform, which must be a hash because `/etc/shadow` stores hashes.

The compose file on the server is mode `0600` because it holds that password.

### Checking it

    dig @192.168.100.10 example.com +short

From the host this crosses OPNsense, so it also needs the firewall rule
allowing `MGMT_HOST` to reach port 53 on the server. A timeout means a rule is
missing; addresses coming back means the whole path works.
