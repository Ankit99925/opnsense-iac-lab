# Rebuilding the lab from scratch

This file is for anyone rebuilding this lab, including future me.
Follow it top to bottom and you end up with the same lab that runs on `mera-server` today.

> **Status.** One command rebuilds the whole lab from nothing and verifies it
> (`./scripts/rebuild.sh --fresh`, about 7 minutes). The repo is self-contained: scripts find
> everything relative to themselves. On a **fresh** Ubuntu machine the tools still have to be
> installed by hand; parts marked **(planned)** close that gap. Update this file in the same
> commit as the code.

---

## What you get at the end

| Part | What it is | Address |
|---|---|---|
| Host | Ubuntu Server 26.04, runs everything | — |
| `default` network | libvirt NAT, OPNsense's WAN side (Terraform) | `192.168.122.0/24` |
| OPNsense | Firewall, router, Kea DHCP, VLANs | WAN `192.168.122.69` (reserved) |
| SERVERS network | Isolated, behind OPNsense (`virbr2`) | `192.168.100.0/24` |
| Ubuntu server | Runs Pi-hole | `192.168.100.10` |
| CLIENTS | USB adapter + Buffalo AP on `br-clients` | `192.168.200.0/24` |
| Buffalo AP | Access point, managed over DHCP | `192.168.200.51` (not reserved yet) |
| Trunk | Tagged VLANs 10 / 20 / 30 on `br-trunk` | `10.20.10.0/24`, `10.20.20.0/24`, `10.20.30.0/24` |
| vlantest | Test VM on VLAN 10, with QEMU guest agent | `10.20.10.x` (from Kea) |

The full address plan and firewall rules are in `README.md`. They are not repeated here.

---

## What you need before starting

### Hardware

- An x86-64 machine with virtualization turned on in the BIOS (Intel VT-x or AMD-V)
- At least 12 GB RAM and about 40 GB free disk
- A USB Ethernet adapter (becomes part of `br-clients`)
- A Wi-Fi AP in access-point mode, plugged into that adapter (for the CLIENTS network)

### Code (in git)

This repo, cloned anywhere (examples below use `~/opnsense-iac-lab`):

| Folder | Holds |
|---|---|
| `terraform/` | Networks, VMs, cloud-init, config ISO, guards |
| `ansible/` | Host bridges (`bridge.yml`), Pi-hole (`pihole.yml`) |
| `scripts/` | `rebuild.sh`, `smoke.sh`, `tapcheck` |
| `opnsense-image/` | `10-configdisk`, the boot hook baked into the golden image |

### Files that are NOT in git

Secret, machine-specific, or too big for git. Keep a copy **off the machine**
(laptop, external drive or encrypted cloud storage); otherwise a dead disk means no rebuild.

| File | Put it at | What it holds | Where it comes from |
|---|---|---|---|
| OPNsense golden image v2 | `/var/lib/libvirt/images/opnsense-26.1-golden-v2.qcow2` | Installed OPNsense + boot hook, no config | Backup copy (check its `.sha256`), or build it (below) |
| Golden image checksum | `~/lab-backup/opnsense-26.1-golden-v2.sha256` | Fingerprint to verify a copied image | Made when the image was built |
| OPNsense config backup | `~/lab-backup/config-OPNsense-<date>.xml` | All firewall config, incl. API key. **Unencrypted** | Backup copy |
| `latest` pointer | `~/lab-backup/config-OPNsense-latest.xml` | Symlink to the backup to rebuild from | `ln -sfn <file> config-OPNsense-latest.xml` |
| `terraform.tfvars` | `terraform/` in the repo (gitignored) | Console password hash, `libvirt-qemu` UID, `kvm` GID | Fill in by hand (planned: bootstrap fills the IDs) |
| `localhost.yml` | `ansible/host_vars/` in the repo (gitignored) | USB adapter name (`enx...`) | Write it for the adapter in use (below) |
| `ubuntu-server.yml` | `ansible/host_vars/` in the repo (gitignored) | Pi-hole admin password | Backup copy |
| `creds.env` | `~/.config/opnsense-iac-lab/creds.env` (dir `700`, file `600`) | OPNsense API key and secret (`OPN_KEY`, `OPN_SECRET`, `OPN_HOST`) | Backup copy |
| SSH key | `~/.ssh/id_ed25519` and `.pub` | Access to the VMs | Backup copy, or make a new one |

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

- install QEMU/KVM, libvirt, virtinst, xorriso, dnsutils, curl, git, Python 3, Ansible, Terraform
- add your user to the `libvirt` and `kvm` groups
- install Ansible collections: `community.libvirt`, `community.general`, `community.docker`
- **delete libvirt's own `default` network**, because Terraform creates it (they collide otherwise)
- make sure the libvirt storage pool `default` exists
- clone this repo
- fill the machine-specific numbers in `terraform.tfvars` (`libvirt-qemu` UID, `kvm` GID)
- add the `terraform` shell function to `~/.bashrc` (see "Terraform and TMPDIR" below)

Then **log out and back in**, so the new group membership applies.

### 4. Build the lab

```bash
cd ~/opnsense-iac-lab && ./scripts/rebuild.sh --fresh
```

It asks for two things: **your sudo password** (at `BECOME password:`), then the word
**`destroy`** (anything else cancels). Everything after that is unattended.
Takes about **7 minutes**.

To keep a record of the run:

```bash
cd ~/opnsense-iac-lab && time ./scripts/rebuild.sh --fresh 2>&1 | tee ~/lab-backup/rebuild-fresh-$(date +%F-%H%M).log; echo "exit: ${PIPESTATUS[0]}"
# ... "Lab rebuilt and verified.", the time taken, exit: 0
```

Two modes:

| Command | Does | Use when |
|---|---|---|
| `rebuild.sh` | **Converge**: builds what is missing, fixes drift, keeps the rest. Safe any time | Routine; after a failed run (it resumes) |
| `rebuild.sh --fresh` | Destroys everything Terraform manages, then builds from nothing | Proving the from-scratch path |
| `rebuild.sh --fresh --yes` | Same, without the confirmation | Automation (later: Jenkins) |

What it does, in order:

1. **Preflight**: stops early if a tool or any file from the table above is missing
2. **Config backup**: if OPNsense's API answers, downloads a backup and accepts it only if it looks like the lab's config (see "Config backups" below); otherwise keeps `latest`
3. **Host bridges**: `bridge.yml` (asks for the sudo password). Changes nothing if the bridges are already right, so running VMs stay plugged in
4. **Destroy** (`--fresh` only). The golden image is not managed by Terraform, so it is never touched
5. **Terraform**: networks and the three VMs; `running = true` means the VMs start themselves
6. **Waits** up to 10 minutes for OPNsense's API: boot, config load, one automatic reboot
7. **Ubuntu server**: waits for SSH, replaces its old host key (trust on first use, acceptable on this isolated network), waits for cloud-init
8. **Pi-hole**: `pihole.yml`
9. **Smoke tests**, up to 5 minutes per check

If it fails partway: do not fix things by hand. Read the error, fix the cause, then run
`rebuild.sh` **without** `--fresh`; it picks up where it stopped.

### 5. Check it worked

`rebuild.sh` runs `scripts/smoke.sh` itself. Run it alone any time (read-only, from the repo root):

```bash
TRIES=1 ./scripts/smoke.sh
# every line PASS, then "All smoke tests passed."
```

| Layer | Check | Pass means |
|---|---|---|
| 1 host | `br-clients` and `br-trunk` are UP | Bridges exist |
| 1 host | All three VMs running | VMs started |
| 1 host | `tapcheck` exits 0 | Every VM NIC is on the right bridge |
| 2 OPNsense | API returns 200 | Config (and its API key) was loaded |
| 3 routing | Route to `192.168.100.0/24` via `.69` | `default` network's route is in place |
| 3 routing | Ansible reaches the server over SSH | Host reaches SERVERS through OPNsense |
| 4 services | Pi-hole answers DNS | Pi-hole works |
| 4 services | Server can `curl` the internet | NAT through OPNsense works |
| 5 VLANs | Kea leased vlantest a `10.20.10.x` address | Trunk, tagging and Kea DHCP work |
| 6 rules | Guest agent in vlantest answers | Host can run commands inside vlantest |
| 6 rules | vlantest can ping `8.8.8.8` | Positive control: the path works |
| 6 rules | vlantest **cannot** ping `10.20.10.1` | Firewall rules restored, not allow-all |

Layer 6 runs commands **inside** vlantest through the QEMU guest agent (a private virtual
channel, no network path), so the VLAN's isolation is tested without weakening it.

Also check by hand: a phone on the AP gets internet, and `http://192.168.100.10/admin` accepts the Pi-hole password.

---

## Building the OPNsense image (rarely)

Only needed when upgrading OPNsense to a new major version, or changing the boot hook.
**Not** part of a normal rebuild. Manual for now. **(planned: Packer)**

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
   **four** NICs on the isolated network. It must reboot once by itself, come up with the
   lab's interfaces, and **not** reboot again after a manual `reboot`.

Note: the current golden image has OPNsense's **default** root login (`root` / `opnsense`).
It is only used if the config fails to load. **(planned: set a unique password in golden v3)**

### How the boot hook works

At every boot, `10-configdisk` looks for a CD holding a file `user-data` that is an OPNsense config.
If that file's checksum differs from the last one it applied, it saves the old config as
`/conf/config.xml.before-configdisk`, copies the new one to `/conf/config.xml`, records the
checksum in `/conf/configdisk.sha256` and reboots once. Same file on the next boot: nothing
happens, so GUI changes survive until a new config ISO is supplied.

The hook writes `/conf/config.xml` directly, **bypassing OPNsense's configuration history**.
**(planned: golden v3 also files the loaded config into the history)**

---

## Config backups

`rebuild.sh` downloads backups with `/api/core/backup/download/this`. That endpoint serves the
**newest entry in OPNsense's configuration history**, not necessarily the live config.
Right after a rebuild the newest entry is the golden image's **factory** config (the hook
bypassed the history). So:

- A download is accepted only if it has no `trigger_initial_wizard` marker and contains `vlan01`.
  Otherwise it is saved as `*.rejected`, `latest` is kept, and a **WARNING** is printed.
- After a rebuild, expect that warning on the next converge run. It stops once any change is
  saved in the OPNsense GUI (that writes a new history entry).
- A download identical to `latest` is not saved again.

Check a backup by hand:

```bash
f=~/lab-backup/config-OPNsense-latest.xml; wc -c < "$f"; grep -c trigger_initial_wizard "$f"; grep -c vlan01 "$f"
# about 60 KB, then 0, then 1 or more. About 34 KB with a wizard marker = factory config: do not use
```

---

## Terraform and TMPDIR

The libvirt provider writes cloud-init ISOs to `$TMPDIR`. On this host `/tmp` is tmpfs:
wiped at every reboot and aged out after 10 days. If the ISOs land there, every plan after a
reboot wants to rebuild them.

- `rebuild.sh` sets `TMPDIR=~/.cache/terraform-tmp` itself.
- For typing `terraform` by hand, `~/.bashrc` has:
  `terraform() { TMPDIR="$HOME/.cache/terraform-tmp" command terraform "$@"; }`
- `guards.tf` prints a warning if any cloud-init ISO path starts with `/tmp/`.
- The VMs attach **pool copies** of the ISOs (`pool_isos.tf`), so they boot even if the originals vanish.
- `~/.cache/terraform-tmp` is `chmod 700`: the ISOs hold the OPNsense config and password hashes.

---

## Keeping it rebuildable

- **The rebuild is only as good as the config backup.** After changing OPNsense in the GUI, take a backup (or let `rebuild.sh` do it) and check it.
- Networks and VMs change through Terraform, never `virsh` by hand. Terraform cannot see hand-made changes.
- **Do not change things inside VMs by hand.** Treat them as cattle: change the code (cloud-init, Ansible) and rebuild the VM with `terraform apply -replace=...`. A hand edit inside vlantest once put it on VLAN 20 while the code said 10; only the smoke test noticed.
- After any change, `terraform plan` should say **No changes**.
- Keep the off-machine copy of the "not in git" files up to date.
- Never commit: `*.tfstate` (it holds the OPNsense config and password hashes), `terraform.tfvars`, config backup XML, `creds.env`, `host_vars/localhost.yml`, `host_vars/ubuntu-server.yml`.

---

## Known gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `rebuild.sh` times out waiting for OPNsense; console shows `OPNsense.internal` with plain LAN/WAN | The config ISO held a **factory** config (a bad backup became `latest`) | Point `latest` at a good backup (check above), then `rebuild.sh --fresh` |
| Backup step prints WARNING about a factory-default config | Normal right after a rebuild (history not caught up) | Nothing; stops after the next GUI save |
| Plan wants to recreate cloud-init ISOs after a host reboot | Terraform ran without `TMPDIR` | Use the `terraform` function / `rebuild.sh`; `-replace` the ISOs |
| A VM lost its network after a bridge or network change | Restarting a bridge unplugs the VMs on it | Run `tapcheck`; restart the affected VM |
| Kea running but no leases | It started while dnsmasq still held port 67, never retried | `configctl kea restart` in the OPNsense shell |
| `guest-ping`: "Guest agent is not connected" | cloud-init still installing `qemu-guest-agent` | Wait a few minutes |
| `qemu-img info` on a running VM's disk: "Failed to get shared write lock" | The VM holds the disk open | Add `-U` to read it anyway |
| Can't log in to OPNsense's console with your password | The config didn't load; only the golden image's default login exists | See the first row |

---

## Automation status

| Piece | Status |
|---|---|
| Host bridges (Ansible) | Done |
| `default` network, incl. reservation and route (Terraform) | Done |
| SERVERS network and all VMs, autostart and `running` (Terraform) | Done |
| Cloud-init ISOs in the storage pool (survive reboots) | Done |
| Golden image v2 with boot hook | Done (manual build) |
| OPNsense built from golden v2 + config ISO | Done |
| Pi-hole (Ansible) | Done |
| `smoke.sh`, 6 layers incl. firewall block test via guest agent | Done |
| `rebuild.sh`, converge and `--fresh` | Done (about 7 min) |
| Backup step rejects factory configs | Done |
| One lab repo; scripts use paths relative to the repo; `tapcheck` inside; lab-owned credentials file | Done |
| `bootstrap.sh` + proof on a fresh Ubuntu VM; CLIENTS adapter optional | Planned (step 13) |
| Off-machine copy of the non-git files | Planned (step 13) |
| Check the Day 2 backup job's backups since the rebuild (same API endpoint) | To do |
| Golden v3: unique root password, hook files config into history | Later |
| Image built by Packer | Later |
| CSV parameter sheet generating the vars files | Later |
| Triggered by Jenkins on git push | Later |
