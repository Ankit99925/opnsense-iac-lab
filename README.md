# opnsense-iac-lab

**TL;DR:** A segmented OPNsense firewall lab on KVM, defined entirely in code. One command turns
a fresh Ubuntu 26.04 machine into the whole lab (firewall, VLANs, DHCP, Pi-hole, three VMs) and
proves it works with 17 smoke tests. Nothing to download or configure by hand.

## Quick start

**You need** (about an hour, unattended):

| Your machine | Free RAM | Free disk | Also |
|---|---|---|---|
| Ubuntu 26.04 (`./setup.sh`) | **about 5 GB** (the lab's VMs use ~3 GB; building the golden image briefly 2 GB) | about 40 GB | hardware virtualization on in the BIOS |
| Any Linux with KVM (`lab-in-vm.sh run`) | **about 7 GB** for the Ubuntu VM that holds the lab (checked before it starts) | about 30 GB | nested virtualization on |

```bash
git clone https://github.com/Ankit99925/opnsense-iac-lab.git
cd opnsense-iac-lab

./setup.sh                              # Ubuntu 26.04: asks for your sudo password once
# or
LAB_VM_YES=1 scripts/lab-in-vm.sh run   # any other Linux with KVM: the same, in a fresh Ubuntu VM
```

It ends with `All smoke tests passed.` and `Lab rebuilt and verified.` To connect a USB Ethernet
adapter and Wi-Fi AP to the CLIENTS zone, run `LAB_CLIENTS_NIC=enx... ./setup.sh` (list adapters
with `ip -br link`). If anything stops, fix the cause and run the same command again: it resumes.

## Using the lab

On the lab host (in the VM path: `scripts/lab-in-vm.sh ssh`, then `cd opnsense-iac-lab`):

```bash
TRIES=1 scripts/smoke.sh       # check everything still works (read-only, about a minute)
scripts/rebuild.sh             # apply a change: converge to what the code says
scripts/rebuild.sh --fresh     # destroy everything and rebuild from nothing
```

| To change | Edit | Then run |
|---|---|---|
| Firewall rules, aliases, DHCP subnets | `policy/*.tf` | `scripts/rebuild.sh` |
| Zones, addresses, VLANs | `network.json` | `scripts/rebuild.sh --fresh` (the firewall's baseline must be reloaded) |
| VMs, networks | `terraform/*.tf` | `scripts/rebuild.sh` |
| OPNsense version, pinned keys | `pins.env` | `./setup.sh` (verify new values first: see REBUILD.md) |

| To reach | From the lab host | Login |
|---|---|---|
| OPNsense web GUI | `https://192.168.122.69` | `root`, password in `~/.config/opnsense-iac-lab/root-password` |
| Pi-hole admin | `http://192.168.100.10/admin` | password in `~/.config/opnsense-iac-lab/pihole-password` |
| The Ubuntu server | `ssh ubuntu@192.168.100.10` | your SSH key |

> **Last verified 2026-10-02:** on a brand-new Ubuntu 26.04 VM, `setup.sh` went from a bare system
> to a verified lab in **62 minutes, unattended**, with nothing copied in. All 17 smoke tests passed.
> Creating the VM adds a few minutes, plus Ubuntu's cloud image (~600 MB) the first time.
>
> **Verified on real hardware 2026-10-04:** on mera-server (Ubuntu 26.04, a USB adapter and Wi-Fi AP on CLIENTS), `setup.sh` built the lab from a wiped state and all 17 smoke tests passed. It stopped once, at problem 19 (fixed in code), and resumed: the lab itself took 9 minutes. A phone on the Wi-Fi then got an address from the new pool and browsed through Pi-hole.

**How it was built, and the 19 problems found along the way:** [docs/CASE-STUDY.md](docs/CASE-STUDY.md)
Full runbook, options and troubleshooting: [REBUILD.md](REBUILD.md)

## Topology

```mermaid
flowchart TB
  inet((Internet)) --- nat
  subgraph host["lab host: Ubuntu 26.04, KVM/libvirt"]
    nat["default network<br/>libvirt NAT 192.168.122.0/24"]
    opn["OPNsense<br/>firewall, router, Kea DHCP"]
    srv["ubuntu-server<br/>Pi-hole 192.168.100.10"]
    vt["vlantest<br/>VLAN 10, QEMU guest agent"]
    nat -- "WAN .69" --- opn
    opn -- "SERVERS 192.168.100.0/24" --- srv
    opn -- "br-trunk: VLANs 10/20/30<br/>10.20.x.0/24" --- vt
  end
  opn -- "CLIENTS 192.168.200.0/24<br/>br-clients + USB NIC" --- ap["Wi-Fi AP<br/>(phones, laptops)"]
```

## How it is built

| Piece | Tool | Job |
|---|---|---|
| Host setup | `setup.sh` | Packages, Terraform and Packer (signing key checked), groups, generated secrets and machine values, then everything below |
| Pinned inputs | `pins.env` | OPNsense version and checksums, HashiCorp's key fingerprint: one place, each noting how it was verified |
| Network description | `network.json` | Zones, addresses, DHCP pools, VLAN tags: written once, read by the baseline generator and the policy |
| Golden image | Packer (`opnsense-image/`) | Installs OPNsense from the checked ISO by typing through its installer, adds the boot hook |
| Host networking | Ansible | Linux bridges for CLIENTS and the VLAN trunk (netplan; NetworkManager or systemd-networkd) |
| Networks and VMs | Terraform (`terraform/`, libvirt provider) | NAT and isolated networks, three VMs, cloud-init, autostart |
| Firewall, Day 0 | Generated baseline | `render-baseline.py` builds OPNsense's config (interfaces, VLANs, users, API key, certificate); the boot hook loads it |
| Firewall, Day 1 | Terraform (`policy/`, OPNsense provider) | Aliases, 28 firewall rules and Kea subnets, pushed through the API |
| Services | Ansible | Pi-hole in Docker on the Ubuntu server |
| Orchestration | Bash | `scripts/rebuild.sh`: converge (default) or `--fresh` |
| Verification | Bash + QEMU guest agent | `scripts/smoke.sh`: six layers, plus a drift check |
| Test harness | `scripts/lab-in-vm.sh` | Fresh Ubuntu VM on any KVM machine, clone from GitHub, run `setup.sh` |

## What the smoke tests prove

1. **Host:** bridges up, all VMs running, every VM NIC on the right bridge
2. **OPNsense:** its API answers with the automation key (so the baseline loaded), and
   `terraform plan` in `policy/` shows no changes (**the firewall matches the code exactly**)
3. **Routing:** the host reaches SERVERS through the firewall
4. **Services:** Pi-hole answers DNS; the server reaches the internet through NAT
5. **VLANs:** Kea leased vlantest an address on VLAN 10 (trunk, tagging, DHCP)
6. **Firewall rules,** from *inside* VLAN 10 through the QEMU guest agent, so the test needs
   no network path into the isolated VLAN. Every block is paired with a positive control:
   internet works but the gateway is unreachable; DNS via Pi-hole works but `8.8.8.8` gets no
   reply; TCP 443 out works but DNS-over-TLS (853) is blocked

## Design decisions

- **Proven on fresh machines, not just the original.** `lab-in-vm.sh run` builds from a blank
  Ubuntu VM, cloning the public repo. Doing that exposed four assumptions the original host had
  been hiding: `sudo -v` prompting a passwordless user, HashiCorp's rotated signing key, the
  installer's real timings, and NetworkManager-only bridge settings on a systemd-networkd host.
  Each is now handled in code.
- **Every input is pinned and verified.** The OPNsense ISO is checked against OPNsense's
  published checksum and against an independent earlier copy; HashiCorp's signing key against
  its fingerprint. When HashiCorp rotated its key, the build stopped instead of trusting it;
  the new fingerprint was confirmed on a different HashiCorp host before the pin was changed.
- **The golden image is built, not stored.** Packer types through OPNsense's installer. The
  waits come from watching a real install (the root password takes 5-10 s to apply; the reboot
  longer than estimated), and the root password avoids characters that need Shift.
- **Firewall as code, in two layers.** A small **baseline** holds only what OPNsense's API
  cannot do; it is generated from OPNsense's own factory config plus `network.json`, and loaded
  at boot by a hook in the golden image. The **policy** (aliases, rules, Kea subnets) is
  Terraform code pushed through the API. The same pattern vendors use: a bootstrap config,
  then policy from a source of truth.
- **One description of the network.** `network.json` feeds both the baseline generator and
  the policy stack. Client zones share one six-rule pattern, so a new VLAN is one line.
- **Deterministic generation.** Secrets are created once and reused; IDs are derived from
  names. The same inputs give a byte-identical baseline, so the firewall only reloads when
  something actually changed.
- **Least privilege for automation.** Root has no API key; a separate `automation` user does.
  SSH to the firewall is key-only, with lockout on.
- **Moving from restore to code exposed real problems.** The old restored config carried dead
  settings, WireGuard that could never work behind CGNAT, a CLIENTS zone that could reach the
  hypervisor, and VLANs told to use an NTP server they were blocked from.
- **Backups are checked, not trusted.** OPNsense's backup API serves the newest entry in its
  configuration *history*; after a rebuild that was once the factory config. Backups are now
  only a safety net, and the backup step rejects factory configs.
- **Nothing important lives in `/tmp`.** It is tmpfs on Ubuntu; VMs attach copies of their
  cloud-init ISOs in the storage pool, and a Terraform `check` block warns otherwise.
- **VMs are cattle.** Drift inside a VM is fixed by rebuilding it from code.
- **Secrets stay out of git.** Generated into `~/.config/opnsense-iac-lab/`, never committed;
  history is scanned with gitleaks.

## Prerequisites

- **Ubuntu 26.04 LTS** for `setup.sh`, or **any Linux with KVM and libvirt** for
  `scripts/lab-in-vm.sh` (which runs `setup.sh` inside an Ubuntu VM). Windows and macOS: no.
- **Hardware virtualization;** 12 GB RAM natively, or about 7 GB free plus nested
  virtualization for the VM path.
- **Optional:** a USB Ethernet adapter and a Wi-Fi AP for CLIENTS (`LAB_CLIENTS_NIC=enx...`).
- **Internet access** to GitHub, Ubuntu, HashiCorp and `pkg.opnsense.org`.
- **Nothing to copy:** secrets are generated, the ISO is downloaded, the golden image is built.

Options, timings and troubleshooting: **[REBUILD.md](REBUILD.md)**.

## Limitations and next steps

- One host, local Terraform state (teams use a remote backend).
- Interface assignment stays in the baseline: OPNsense's API does not cover it.
- Converge mode cannot yet apply a baseline change (OPNsense must reboot to load it); `--fresh` can.
- OPNsense 26.1; moving to 26.7 is a pin change plus a test run.
- The ISO is checked by checksum; verifying OPNsense's release signature is next.
- Later: a nightly CI run of `lab-in-vm.sh run`, a CSV parameter sheet, a read-only monitoring key.

## Repo layout

```
setup.sh          one command: fresh Ubuntu 26.04 -> verified lab
pins.env          pinned versions, checksums and signing keys
network.json      zones, addresses, pools, VLAN tags
terraform/        networks, VMs, cloud-init, config ISO, guards
policy/           OPNsense aliases, rules, Kea subnets (through the API)
ansible/          host bridges, Pi-hole
opnsense-image/   Packer template, boot hook, OPNsense factory config
scripts/          rebuild.sh, smoke.sh, tapcheck, gen-secrets.sh, render-baseline.py, lab-in-vm.sh
REBUILD.md        runbook: how it works, gotchas, automation status
```

---

## Lab details


A segmented home network running as virtual machines on one Ubuntu host
(`mera-server`). OPNsense is the firewall and router; everything else sits
behind it in a zone.

This file is the runbook. It covers the topology, which tool owns which piece,
how to rebuild it, the steps that are still manual, and the things that cost
hours to work out the first time.

---

## Topology in detail

    Internet
       |  (mobile connection, carrier-grade NAT — inbound is impossible)
    Upstream router
       |  Wi-Fi
    mera-server (Ubuntu host)
       |  libvirt NAT, virbr0, 192.168.122.0/24
    OPNsense VM
       |-- vtnet0  WAN       virbr0        192.168.122.69 (reserved)
       |-- vtnet1  SERVERS   virbr2        192.168.100.1/24
       |-- vtnet2  CLIENTS   br-clients    192.168.200.1/24
       +-- vtnet3  trunk     br-trunk      tagged, no address of its own
                                vlan01  VLAN10  10.20.10.1/24
                                vlan02  VLAN20  10.20.20.1/24
                                vlan03  VLAN30  10.20.30.1/24

    SERVERS    ubuntu-server  192.168.100.10  Pi-hole, DNS for everything
    CLIENTS    USB ethernet -> Buffalo AP -> phones and laptops, .200.50-200
    trunk      vlantest VM, tags its own frames for testing

### Why it is built this way

The upstream connection is mobile and behind carrier-grade NAT. Its address
changes on every restart and there is no usable configuration page. So the lab
owns all of its own addressing behind OPNsense, and nothing in this repo
references the upstream network. It renumbered three times in one morning
without affecting anything.

---

## Who owns what

Four bridges exist on the host, created by three different things.

| Bridge       | Zone     | Created by |
|--------------|----------|------------|
| `virbr0`     | WAN      | libvirt, from `libvirt_network.default` (Terraform, `terraform/default_network.tf`) |
| `virbr2`     | SERVERS  | libvirt, from `libvirt_network.servers` (Terraform) |
| `br-clients` | CLIENTS  | Ansible, via netplan (`ansible/bridge.yml`) |
| `br-trunk`   | trunk    | Ansible, via netplan (`ansible/bridge.yml`) |

| Piece | Managed by |
|-------|------------|
| Host packages, groups, secrets, machine values | `setup.sh` |
| Pinned versions, checksums, signing keys | `pins.env` |
| Zones, addresses, pools, VLAN tags | `network.json` |
| `default` network, incl. OPNsense's DHCP reservation and the host route to SERVERS | Terraform (`terraform/`) |
| SERVERS network, all VMs, volumes, cloud-init and config ISOs | Terraform (`terraform/`) |
| `br-clients`, `br-trunk` | Ansible |
| Pi-hole | Ansible |
| OPNsense installed system and boot hook | Golden image, built by Packer (`opnsense-image/golden.pkr.hcl`) |
| OPNsense interfaces, VLAN devices, users, API key, certificate, SSH, Kea on/off | Baseline, generated by `scripts/render-baseline.py` |
| Firewall aliases, rules, Kea subnets | Terraform (`policy/`), through the API |

Terraform refers to `br-clients` and `br-trunk` by name only; it does not create them.
`scripts/smoke.sh` checks both bridges are up, `scripts/tapcheck` checks every VM network card
is attached to the bridge it should be, and the drift check confirms the firewall matches `policy/`.

---

## Rebuild order

On a new machine, `./setup.sh` prepares the host and ends by running this. Afterwards, run it
directly to apply changes:

    ./scripts/rebuild.sh            # converge: build what is missing, fix drift
    ./scripts/rebuild.sh --fresh    # destroy everything, then build from nothing

It runs, in order:

1. **Preflight:** tools, golden image, host files
2. **Secrets and baseline:** create missing secrets; render the baseline config
3. **Config backup** from OPNsense's API (safety net only)
4. **Ansible** creates the bridges. VMs attach to them, and a VM cannot start if its bridge does not exist.
5. **Terraform** (`terraform/`) creates the networks, the VMs and their disks; the VMs start themselves
6. **OPNsense** boots the golden image; the boot hook loads the baseline and reboots once
7. **Terraform** (`policy/`) pushes aliases, rules and Kea subnets through the API
8. **Ubuntu server:** wait for SSH, refresh its host key, wait for cloud-init
9. **Ansible** deploys Pi-hole
10. **Smoke tests,** all six layers

Details and failure recovery: [REBUILD.md](REBUILD.md).

## What is still done by hand

- **Typing your sudo password once** when `setup.sh` starts (on a real machine).
- **Physical things:** plugging in the USB adapter, and setting the Wi-Fi AP to access-point mode.
- **Reading a failure,** fixing the cause, running the same command again (everything resumes).
- **Changing a pin** in `pins.env`, deliberately, after verifying the new value.

Nothing is built, copied or restored by hand any more.

---

## Things that cost hours

**NIC order is load-bearing.** OPNsense names interfaces `vtnet0` to `vtnet3`
in the order they appear in `devices.interfaces`. The restored config assigns
WAN, SERVERS and CLIENTS to 0, 1 and 2. Reorder that list and the restore puts
WAN rules on the servers zone.

**Machine types come from the backup, not from memory.** OPNsense wants
`pc-i440fx-resolute`; the Ubuntu server wants `pc-q35-10.2`. An old q35 version
(`pc-q35-6.2`) boots but the guest never sees its virtio disk — it drops to an
initramfs prompt saying the root filesystem does not exist, and `ls /dev/vd*`
shows nothing. The fix is the machine type, not permissions.

**OPNsense needs ACPI and APIC.** Without them its FreeBSD kernel panics at
boot with "running without device atpic requires a local APIC". Virt-Manager
adds these silently; this provider does not.

**Declare the disk format.** A disk without `driver = { type = "qcow2" }`
fails with "Permission denied", because QEMU refuses to guess a format and
reports the closest errno it has. The message is misleading — check the format
before the permissions.

**Declare the backing chain too.** A layered disk needs `backing_store` on the
domain's disk as well as on the volume. Without it QEMU will not follow the
chain into the base image.

**Use `source.file`, not `source.volume`.** The volume form, which refers to a
pool and a volume name, did not work here. A direct file path does, and it
matches what a working VM's XML looks like.

**Pools and volumes are immutable.** Every change requires replacement, and
replacing a pool takes its volumes with it. `terraform plan` may still describe
the change as in-place; the provider refuses at apply time.

**Volume ownership drifts.** libvirt chowns a disk to `libvirt-qemu` when its
VM starts and back to root when it stops, so a stopped VM's disk always differs
from the config. `lifecycle { ignore_changes = [target] }` stops this appearing
in every plan.

**cloud-init locks passwords by default.** `passwd:` alone puts the hash in
`/etc/shadow` with a `!` in front, which means locked. `lock_passwd: false` is
required as well.

**Changing the bridges unplugs the VMs.** `netplan apply` restarts
NetworkManager, which rebuilds `br-clients` and `br-trunk` with only the ports
it knows about. libvirt's tap devices are not among them, so OPNsense silently
loses its CLIENTS and trunk connections. Stop OPNsense before changing bridges,
or run `ops tapcheck` afterwards and restart it.

---

## Local values

`terraform.tfvars` is gitignored. Copy the example and fill it in:

    qemu_uid              id -u libvirt-qemu
    kvm_gid               getent group kvm | cut -d: -f3
    opnsense_iso          path to the installer ISO
    console_password_hash openssl passwd -6
    vm_user               defaults to ubuntu
    opnsense_machine      defaults to pc-i440fx-resolute
    server_machine        defaults to pc-q35-10.2

The ISO must be somewhere QEMU can read — `/var/lib/libvirt/isos/` rather than
your home directory, which is not traversable by `libvirt-qemu`.
