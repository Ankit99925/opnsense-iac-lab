# Rebuilding the lab from scratch

This file is for anyone rebuilding this lab, including future me.
Follow it top to bottom and you end up with the same lab that runs on `mera-server` today.

> **Status.** One command destroys the lab and rebuilds it from nothing, firewall included,
> then verifies it (`./scripts/rebuild.sh --fresh`, about 7.5 minutes). The firewall is built
> from code: a generated baseline config plus a Terraform policy stack. No config backup is
> needed to rebuild. On a **fresh** Ubuntu machine the tools and the golden image still have
> to be set up by hand; parts marked **(planned)** close that gap. Update this file in the
> same commit as the code.

---

## What you get at the end

| Part | What it is | Address |
|---|---|---|
| Host | Ubuntu Server 26.04, runs everything | — |
| `default` network | libvirt NAT, OPNsense's WAN side (Terraform) | `192.168.122.0/24` |
| OPNsense | Firewall, router, Kea DHCP, VLANs, built from code | WAN `192.168.122.69` (reserved) |
| SERVERS network | Isolated, behind OPNsense (`virbr2`) | `192.168.100.0/24` |
| Ubuntu server | Runs Pi-hole | `192.168.100.10` |
| CLIENTS | USB adapter + Wi-Fi AP on `br-clients` | `192.168.200.0/24` |
| Wi-Fi AP | Access point, managed over DHCP | `192.168.200.51` (not reserved yet) |
| Trunk | Tagged VLANs 10 / 20 / 30 on `br-trunk` | `10.20.10.0/24`, `10.20.20.0/24`, `10.20.30.0/24` |
| vlantest | Test VM on VLAN 10, with QEMU guest agent and `dig` | `10.20.10.x` (from Kea) |

The zones, addresses, DHCP pools and VLAN tags are defined once, in `network.json`.

---

## What you need before starting

### Hardware

- An x86-64 machine with virtualization turned on in the BIOS (Intel VT-x or AMD-V)
- At least 12 GB RAM and about 40 GB free disk
- A USB Ethernet adapter (becomes part of `br-clients`)
- A Wi-Fi AP in access-point mode, plugged into that adapter (for the CLIENTS network)

### Code (in git)

This repo, cloned anywhere (examples below use `~/opnsense-iac-lab`):

| Path | Holds |
|---|---|
| `network.json` | The network's shape: zones, addresses, pools, VLAN tags, host and Pi-hole addresses |
| `terraform/` | Networks, VMs, cloud-init, config ISO, guards |
| `policy/` | OPNsense aliases, firewall rules and Kea subnets, pushed through the API |
| `ansible/` | Host bridges (`bridge.yml`), Pi-hole (`pihole.yml`) |
| `scripts/` | `rebuild.sh`, `smoke.sh`, `tapcheck`, `gen-secrets.sh`, `render-baseline.py` |
| `opnsense-image/` | The boot hook, and OPNsense 26.1's factory config (secrets removed) |

### Files that are NOT in git

Secret, machine-specific, or too big for git. Keep a copy **off the machine**
(laptop, external drive or encrypted cloud storage); otherwise a dead disk means a harder rebuild.

| File | Put it at | What it holds | Where it comes from |
|---|---|---|---|
| OPNsense golden image v2 | `/var/lib/libvirt/images/opnsense-26.1-golden-v2.qcow2` | Installed OPNsense + boot hook, no config | Backup copy (check its `.sha256`), or build it (below) |
| Golden image checksum | `~/lab-backup/opnsense-26.1-golden-v2.sha256` | Fingerprint to verify a copied image | Made when the image was built |
| `terraform.tfvars` | `terraform/` in the repo (gitignored) | Console password hash, `libvirt-qemu` UID, `kvm` GID | Fill in by hand (planned: bootstrap fills the IDs) |
| `localhost.yml` | `ansible/host_vars/` in the repo (gitignored) | USB adapter name (`enx...`) | Write it for the adapter in use (below) |
| `ubuntu-server.yml` | `ansible/host_vars/` in the repo (gitignored) | Pi-hole admin password | Backup copy |
| SSH key pair | `~/.ssh/id_ed25519` and `.pub` | Access to the VMs; the public key is also installed for OPNsense's root | Backup copy, or make a new one |
| Lab secrets | `~/.config/opnsense-iac-lab/` (dir `700`, files `600`) | OPNsense root password and its hash, the automation user's API key (`api.env`), the web GUI certificate | **Generated** by `scripts/gen-secrets.sh` on the first run; back them up afterwards |

`~/.config/opnsense-iac-lab/root-password` is the break-glass login for OPNsense's console.
A new machine without these files simply gets new secrets on its first run.

**No longer needed:** an OPNsense config backup. The firewall is built from code.

**Generated every run, never edited:** `~/.cache/opnsense-iac-lab/baseline.xml`.

The USB adapter's name contains its hardware MAC, so a different adapter has a different name:

```bash
ip -br link | grep enx
# one line starting with enx..., that is the name to put in localhost.yml
```

After copying the golden image in, fix its owner and permissions and check it arrived intact:

```bash
sudo chown libvirt-qemu:kvm /var/lib/libvirt/images/opnsense-26.1-golden-v2.qcow2
sudo chmod 0440 /var/lib/libvirt/images/opnsense-26.1-golden-v2.qcow2
sudo sha256sum -c ~/lab-backup/opnsense-26.1-golden-v2.sha256
# ...golden-v2.qcow2: OK
virsh pool-refresh default
# Pool default refreshed
```

---

## Rebuild steps

### 1. Install Ubuntu Server 26.04 on the host

By hand. Create your user (it needs sudo), enable SSH.

### 2. Restore the files that are not in git

Copy each file from the table above into place.

### 3. Prepare the machine **(planned: `bootstrap.sh`, step 13)**

Runs once per machine. It will:

- install QEMU/KVM, libvirt, virtinst, xorriso, dnsutils, curl, git, Python 3, Perl, OpenSSL, Ansible, Terraform
- add your user to the `libvirt` and `kvm` groups
- install Ansible collections: `community.libvirt`, `community.general`, `community.docker`
- **delete libvirt's own `default` network**, because Terraform creates it (they collide otherwise)
- make sure the libvirt storage pool `default` exists
- clone this repo
- fill the machine-specific numbers in `terraform.tfvars` (`libvirt-qemu` UID, `kvm` GID)
- add the `terraform` shell function to `~/.bashrc` (see "Terraform and TMPDIR" below)
- build the golden image **(planned: Packer, step 15)**

Then **log out and back in**, so the new group membership applies.

### 4. Build the lab

```bash
cd ~/opnsense-iac-lab && ./scripts/rebuild.sh --fresh
```

It asks for two things: **your sudo password** (at `BECOME password:`), then the word
**`destroy`** (anything else cancels). Everything after that is unattended.
Takes about **7.5 minutes**.

To keep a record of the run:

```bash
cd ~/opnsense-iac-lab && time ./scripts/rebuild.sh --fresh 2>&1 | tee ~/lab-backup/rebuild-fresh-$(date +%F-%H%M).log; echo "exit: ${PIPESTATUS[0]}"
# ... "Lab rebuilt and verified.", the time taken, exit: 0
```

Two modes:

| Command | Does | Use when |
|---|---|---|
| `rebuild.sh` | **Converge**: builds what is missing, fixes drift, keeps the rest. Safe any time | Routine; applying a change; after a failed run (it resumes) |
| `rebuild.sh --fresh` | Destroys everything Terraform manages, then builds from nothing | Proving the from-scratch path |
| `rebuild.sh --fresh --yes` | Same, without the confirmation | Automation (later: Jenkins) |

What it does, in order:

1. **Preflight**: stops early if a tool or any file it needs is missing
2. **Secrets and baseline**: `gen-secrets.sh` (creates missing secrets, keeps the rest), then
   `render-baseline.py` (byte-identical output unless an input changed)
3. **Config backup** (safety net only): saves the running config if OPNsense answers with the automation key
4. **Host bridges**: `bridge.yml` (asks for the sudo password). Changes nothing if the bridges are already right
5. **Destroy** (`--fresh` only), and forget `policy/`'s state, which described the destroyed firewall.
   The golden image is not managed by Terraform, so it is never touched
6. **Terraform** (`terraform/`): networks and the three VMs; the OPNsense config ISO holds the baseline
7. **Waits** up to 10 minutes for OPNsense's API: boot, baseline load, one automatic reboot
8. **Firewall policy** (`policy/`): aliases, rules and Kea subnets, through the API
9. **Ubuntu server**: waits for SSH, replaces its old host key (trust on first use, acceptable on this isolated network), waits for cloud-init
10. **Pi-hole**: `pihole.yml`
11. **Smoke tests**, up to 5 minutes per check

If it fails partway: do not fix things by hand. Read the error, fix the cause, then run
`rebuild.sh` **without** `--fresh`; it picks up where it stopped.

### 5. Check it worked

`rebuild.sh` runs `scripts/smoke.sh` itself. Run it alone any time (from the repo root):

```bash
TRIES=1 ./scripts/smoke.sh
# every line PASS, then "All smoke tests passed."
```

| Layer | Check | Pass means |
|---|---|---|
| 1 host | `br-clients` and `br-trunk` are UP | Bridges exist |
| 1 host | All three VMs running | VMs started |
| 1 host | `tapcheck` exits 0 | Every VM NIC is on the right bridge |
| 2 OPNsense | API returns 200 with the automation key | The baseline loaded (only it has that key) |
| 2 OPNsense | `terraform plan` in `policy/` shows no changes | **The firewall matches the code exactly** (drift check) |
| 3 routing | Route to `192.168.100.0/24` via `.69` | `default` network's route is in place |
| 3 routing | Ansible reaches the server over SSH | Host reaches SERVERS through OPNsense |
| 4 services | Pi-hole answers DNS | Pi-hole works |
| 4 services | Server can `curl` the internet | NAT through OPNsense works |
| 5 VLANs | Kea leased vlantest a `10.20.10.x` address | Trunk, tagging and Kea DHCP work |
| 6 rules | Guest agent in vlantest answers | Host can run commands inside vlantest |
| 6 rules | vlantest can ping `8.8.8.8` | Positive control: the path works |
| 6 rules | vlantest **cannot** ping `10.20.10.1` | Client zones can't reach the firewall |
| 6 rules | `dig @192.168.100.10` works | Positive control: DNS through Pi-hole |
| 6 rules | `dig @8.8.8.8` gets **no reply** | DNS anywhere else is blocked |
| 6 rules | TCP 443 to `1.1.1.1` works | Positive control for the port tests |
| 6 rules | TCP 853 to `1.1.1.1` **fails** | DNS-over-TLS is blocked |

Layer 6 runs commands **inside** vlantest through the QEMU guest agent (a private virtual
channel, no network path), so the VLAN's isolation is tested without weakening it.
Every "blocked" check is paired with a positive control, so a failure can only mean the rule.

Also check by hand: a phone on the AP gets internet, and `http://192.168.100.10/admin` accepts the Pi-hole password.

---

## How the firewall is built

Two parts, both from this repo:

| Part | Holds | Made by | Applied |
|---|---|---|---|
| **Baseline** | Interfaces, VLAN devices, users (root, automation), API key, web GUI certificate, SSH, Kea on, dnsmasq off, two bootstrap rules | `scripts/render-baseline.py`: OPNsense's factory config + `network.json` + the lab secrets | At boot, by the golden image's hook, from the config ISO |
| **Policy** | Aliases, 28 firewall rules, 5 Kea subnets | `policy/*.tf` + `network.json` | By Terraform through the API, after OPNsense is up |

The baseline only holds what the API cannot do. Bootstrap rules: the host (`192.168.122.1`)
may reach the firewall on TCP 443 (web GUI and API) and 22 (SSH); everything else is policy.

**To change the firewall:** edit `policy/*.tf` (rules, aliases, Kea) or `network.json`
(zones, addresses, pools), commit, run `./scripts/rebuild.sh` (converge), check the smoke tests.
**Do not change rules in the GUI**: the next smoke test's drift check fails until the code
and the firewall agree again.

**To add a client VLAN:** one line in `network.json`. The baseline gets the interface and
VLAN device, and the policy gets its six rules and its Kea subnet automatically.

### The policy

| Zone | Rules (in order) |
|---|---|
| WAN | host → Pi-hole TCP 22, TCP/UDP 53, TCP 80 (plus the two bootstrap rules in the baseline) |
| SERVERS | → anywhere (IPv4 and IPv6) |
| CLIENTS, VLAN10, VLAN20, VLAN30 | pass DNS to Pi-hole · block DNS anywhere else · block TCP 853 · block the firewall itself · block all private ranges (`RFC1918`) · pass anywhere |

Every rule has a description saying why. Kea subnets hand out the zone's gateway as router
and Pi-hole as DNS. No NTP server is handed out: client zones may not reach the firewall,
so they use internet time.

To list the rules on OPNsense through the API, ask per interface (a search without
`interface` returns nothing):

```bash
set -a; source ~/.config/opnsense-iac-lab/api.env; set +a
curl -sk -u "$OPN_KEY:$OPN_SECRET" "https://$OPN_HOST/api/firewall/filter/search_rule?interface=opt3"
```

### Secrets

`scripts/gen-secrets.sh` creates each secret once and never overwrites it (idempotent):
root's password and hash, the automation user's API key and secret, and a self-signed web GUI
certificate. OPNsense stores API secrets as SHA-512 crypt with an empty salt (`$6$$...`);
`render-baseline.py` reproduces that with Perl's `crypt`. Root has no API key; the
`automation` user has one and no password.

SSH into OPNsense is key-only (your `id_ed25519.pub` for root), with lockout on.

---

## Building the OPNsense image (rarely)

Only needed when upgrading OPNsense to a new major version, or changing the boot hook.
**Not** part of a normal rebuild. Manual for now. **(planned: Packer, step 15)**

1. **Base image.** Install OPNsense from the ISO onto a 20 GiB qcow2 (virtio disk, machine type
   `pc-i440fx-*`). Keep it as `opnsense-26.1-base.qcow2`; never boot it directly.
2. **Build VM.** Copy the base to a working disk. Boot it with `virt-install --import` on a
   temporary isolated network (`virsh net-create` with just a name) with **two** virtio NICs,
   plus an ISO holding the hook (`xorriso -as mkisofs -R -J`). Isolated, because a fresh
   OPNsense runs a DHCP server on its LAN side.
3. **Add the hook.** In the shell (option 8): mount the ISO (`mount -t cd9660 -o ro /dev/cd0 /tmp/hook`),
   copy `10-configdisk` to `/usr/local/etc/rc.syshook.d/early/`, `chmod 755`.
   Run it once by hand (no config disk attached: exits 0, no reboot).
   Check `/conf/configdisk.sha256` does **not** exist. Power off.
4. **Save golden.** Rename the disk to `opnsense-26.1-golden-v2.qcow2`, owner `libvirt-qemu:kvm`,
   mode `0440`, `virsh pool-refresh default`, record `sha256sum` into `~/lab-backup/`.
5. **Test.** Thin copy on golden (`qemu-img create -b ... -F qcow2`) plus a config ISO,
   **four** NICs (first on `default` so the host can reach its WAN, the rest on the isolated
   network). It must reboot once by itself, come up with the lab's interfaces, and accept the
   automation key on its API.
6. **New OPNsense version:** also save its factory config (certificate and password hashes
   removed) as `opnsense-image/factory-config-<version>.xml` and point `render-baseline.py` at it.

Note: the golden image itself has OPNsense's **default** root login (`root` / `opnsense`).
It only matters if the baseline fails to load. **(planned: unique password, with Packer)**

### How the boot hook works

At every boot, `10-configdisk` looks for a CD holding a file `user-data` that is an OPNsense config.
If that file's checksum differs from the last one it applied, it saves the old config as
`/conf/config.xml.before-configdisk`, copies the new one to `/conf/config.xml`, records the
checksum in `/conf/configdisk.sha256` and reboots once. Same file on the next boot: nothing
happens. Because the baseline is deterministic, OPNsense only reloads when an input changed.

---

## Config backups (safety net)

Nothing is rebuilt from backups any more. `rebuild.sh` still saves the running config when
OPNsense answers, for inspection, comparison and manual recovery (System → Configuration →
Backups in the GUI).

`/api/core/backup/download/this` serves the **newest entry in OPNsense's configuration
history**, not necessarily the live config. The boot hook bypasses that history, but the
policy stage changes the firewall through the API, which saves properly, so after a full
rebuild the newest entry is the real config. The backup step still rejects anything that
looks like a factory config (`trigger_initial_wizard` marker, or no `vlan01`), and skips
saving a download identical to the last one.

---

## Terraform and TMPDIR

The libvirt provider writes cloud-init ISOs to `$TMPDIR`. On this host `/tmp` is tmpfs:
wiped at every reboot and aged out after 10 days. If the ISOs land there, every plan after a
reboot wants to rebuild them.

- `rebuild.sh` sets `TMPDIR=~/.cache/terraform-tmp` itself.
- For typing `terraform` by hand, `~/.bashrc` has:
  `terraform() { TMPDIR="$HOME/.cache/terraform-tmp" command terraform "$@"; }`
- `terraform/guards.tf` prints a warning if any cloud-init ISO path starts with `/tmp/`.
- The VMs attach **pool copies** of the ISOs (`terraform/pool_isos.tf`), so they boot even if the originals vanish.
- `~/.cache/terraform-tmp` is `chmod 700`: the ISOs hold the baseline and password hashes.

---

## Reaching the lab from another machine

mera-server is the only way in (a bastion): the lab VMs trust mera-server's key, so no other
machine's key has to be installed anywhere. On the other machine, in `~/.ssh/config`:

```
Host Server                      # shell on the Ubuntu server, through mera-server
    HostName <mera-server's address>
    User <your user on mera-server>
    RequestTTY yes
    RemoteCommand ssh ubuntu@192.168.100.10

Host pihole-admin                # then browse http://localhost:8080/admin
    HostName <mera-server's address>
    User <your user on mera-server>
    LocalForward 8080 192.168.100.10:80
    SessionType none
```

`ssh-copy-id` to the server does not work: it only accepts keys, and `ssh-copy-id` needs a
password login. The server's user is `ubuntu`.

---

## Keeping it rebuildable

- Firewall changes go through `policy/` or `network.json`, never the GUI. The drift check enforces it.
- Networks and VMs change through `terraform/`, never `virsh` by hand. Terraform cannot see hand-made changes.
- **Do not change things inside VMs by hand.** Treat them as cattle: change the code (cloud-init, Ansible) and rebuild the VM with `terraform apply -replace=...`.
- After any change, `terraform plan` in `terraform/` and `policy/` should say **No changes**.
- Make changes on a branch; run `rebuild.sh` (or `--fresh`) from it; merge to `main` only after the smoke tests pass.
- Keep the off-machine copy of the "not in git" files up to date, including `~/.config/opnsense-iac-lab/`.
- Never commit: `*.tfstate` (it holds the baseline, with password hashes and the certificate key), `terraform.tfvars`, config backup XML, `*.env`, `host_vars/*.yml`, anything from `~/.config/opnsense-iac-lab/`.

---

## Known gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `rebuild.sh` times out waiting for OPNsense | The baseline did not load (console shows plain LAN/WAN), or the API key does not match | Check the console banner; log in with `~/.config/opnsense-iac-lab/root-password`; check `/conf/configdisk.sha256` exists |
| Smoke test: "firewall policy matches the code" fails | Someone changed the firewall outside `policy/` (GUI), or the provider reports drift | `terraform -chdir=policy plan` shows what differs; fix the code or rerun `rebuild.sh` |
| Phone has no DNS after the switch to code-built firewall | Android Private DNS set to a provider hostname; DNS-over-TLS is blocked | Set Private DNS to Automatic or Off |
| `search_rule` API returns 0 rules | The search needs `?interface=...` | Ask per interface (`lan`, `opt2` ... `opt5`, `wan`) |
| Plan wants to recreate cloud-init ISOs after a host reboot | Terraform ran without `TMPDIR` | Use the `terraform` function / `rebuild.sh`; `-replace` the ISOs |
| A VM lost its network after a bridge or network change | Restarting a bridge unplugs the VMs on it | Run `tapcheck`; restart the affected VM |
| No DHCP leases on a zone | Kea not running or not listening there | Check Kea's interfaces in the baseline; `configctl kea restart` in the OPNsense shell |
| `guest-ping`: "Guest agent is not connected" | cloud-init still installing `qemu-guest-agent` (needs DNS via Pi-hole) | Wait a few minutes |
| `qemu-img info` on a running VM's disk: "Failed to get shared write lock" | The VM holds the disk open | Add `-U` to read it anyway |
| `ssh-copy-id` to the server: "Permission denied (publickey)" | The server is key-only | Go through mera-server (see "Reaching the lab") |

---

## Automation status

| Piece | Status |
|---|---|
| Host bridges (Ansible) | Done |
| `default` network, incl. reservation and route (Terraform) | Done |
| SERVERS network and all VMs, autostart and `running` (Terraform) | Done |
| Cloud-init ISOs in the storage pool (survive reboots) | Done |
| Golden image v2 with boot hook | Done (manual build) |
| `network.json`: one description of the network | Done |
| Secrets generated once (`gen-secrets.sh`) | Done |
| OPNsense baseline generated from code (`render-baseline.py`) | Done |
| Firewall policy as code: 3 aliases, 28 rules, 5 Kea subnets (`policy/`) | Done |
| Pi-hole (Ansible) | Done |
| `smoke.sh`, 6 layers incl. drift check and DNS enforcement | Done |
| `rebuild.sh`, converge and `--fresh` | Done (about 7.5 min) |
| One lab repo, self-contained | Done |
| opnwatch: own read-only API key | To do |
| `infra` addresses (route, reservation, server IP) read from `network.json` | Later |
| Image built by Packer, unique golden root password | Planned (step 15) |
| `bootstrap.sh` + proof on a fresh Ubuntu VM; CLIENTS adapter optional | Planned (step 13) |
| Named admin user with sudo on OPNsense; central auth | Later |
| CSV parameter sheet generating `network.json` | Later |
| Triggered by Jenkins on git push | Later |
