# Rebuilding the lab from scratch

This is the runbook: how to build the lab on a new machine, how it works, and what to do
when something goes wrong.

> **Last verified 2026-10-02:** on a brand-new Ubuntu 26.04 VM made by `scripts/lab-in-vm.sh run`,
> `setup.sh` went from a bare system to a verified lab in **62 minutes, unattended**: public repo,
> generated secrets, ISO downloaded and checked, golden image built by Packer, all 17 smoke tests
> passed. Nothing was copied from another machine. Creating the VM adds a few minutes, plus
> downloading Ubuntu's cloud image (~600 MB) the first time; that run reused a cached, checked copy.

---

## Two ways in

| Your machine | Command | What you get |
|---|---|---|
| **Ubuntu 26.04 LTS** | `./setup.sh` | The lab runs on this machine; CLIENTS can use a real USB adapter and Wi-Fi AP |
| **Any other Linux with KVM** (Fedora, Bazzite, Arch...) | `scripts/lab-in-vm.sh run` | A fresh Ubuntu 26.04 VM, with `setup.sh` run inside it. CLIENTS exists, with no physical Wi-Fi |
| Windows, macOS | not supported | No KVM, so no nested lab |

`setup.sh` supports Ubuntu 26.04 only, and says so if run anywhere else. Supporting one
system well beats supporting several badly (the bridges use netplan, which is Ubuntu's).

---

## What you get

| Part | What it is | Address |
|---|---|---|
| Host | Ubuntu 26.04, runs everything | — |
| `default` network | libvirt NAT, OPNsense's WAN side | `192.168.122.0/24` |
| OPNsense | Firewall, router, Kea DHCP, VLANs, built from code | WAN `192.168.122.69` |
| SERVERS | Isolated, behind OPNsense | `192.168.100.0/24` |
| Ubuntu server | Pi-hole | `192.168.100.10` |
| CLIENTS | `br-clients` (+ USB adapter and Wi-Fi AP, if given) | `192.168.200.0/24` |
| Trunk | Tagged VLANs 10 / 20 / 30 on `br-trunk` | `10.20.10.0/24`, `10.20.20.0/24`, `10.20.30.0/24` |
| vlantest | Test VM on VLAN 10, with QEMU guest agent and `dig` | `10.20.10.x` (from Kea) |

Zones, addresses, pools and VLAN tags are defined once, in `network.json`.

---

## Before you start

**Hardware.** x86-64 with virtualization on in the BIOS (Intel VT-x / AMD-V).

| Path | RAM | Disk |
|---|---|---|
| `./setup.sh` on Ubuntu | about 5 GB **free** (lab VMs ~3 GB: OPNsense 1.5, server 1, vlantest 0.5; the golden image build briefly 2 GB) | about 40 GB |
| `lab-in-vm.sh run` | about 7 GB **free** (16 GB machine), and **nested virtualization** on | about 100 GB (thin; uses far less) |

**Internet access** to: GitHub, Ubuntu's package mirrors, `apt.releases.hashicorp.com`,
`pkg.opnsense.org` (the only source for older OPNsense releases), and Ubuntu's cloud images
(VM path only).

**For `lab-in-vm.sh` only**, on the machine running it: `virsh`, `qemu-img`, `xorriso`, `curl`,
`ssh`, your user in the `libvirt` group, and libvirt's storage daemon. Its preflight checks
all of it and prints the install command for Fedora, Bazzite and Ubuntu if anything is missing.
It installs nothing on your machine.

**Nothing else.** No files to copy: secrets are generated, the ISO is downloaded, the golden
image is built.

---

## Run it

### On Ubuntu 26.04

```bash
git clone https://github.com/Ankit99925/opnsense-iac-lab.git
cd opnsense-iac-lab
./setup.sh 2>&1 | tee ~/setup.log
# asks for your sudo password once; about an hour; ends with "Lab rebuilt and verified."
```

Options (environment variables):

| Variable | Use |
|---|---|
| `LAB_CLIENTS_NIC=enx...` | USB adapter for `br-clients` (list them: `ip -br link`). Without it, CLIENTS has no physical port |
| `LAB_OPNSENSE_ISO=/path/OPNsense-26.1-dvd-amd64.iso.bz2` | Use a local copy instead of downloading (still checked against `pins.env`) |
| `SECRETS_DIR` | Where secrets live (default `~/.config/opnsense-iac-lab`) |

### On another Linux

```bash
git clone https://github.com/Ankit99925/opnsense-iac-lab.git
cd opnsense-iac-lab
LAB_VM_YES=1 scripts/lab-in-vm.sh run 2>&1 | tee lab-in-vm-run.log
```

`run` creates a fresh VM (replacing a previous one, after asking; `LAB_VM_YES=1` answers in
advance), clones the repo **from GitHub** inside it (so it tests what is pushed), and runs
`setup.sh`. Other commands:

| Command | Does |
|---|---|
| `lab-in-vm.sh up` | A fresh VM only, then a shell in it |
| `lab-in-vm.sh ssh [command]` | A shell (or a command) in the VM |
| `lab-in-vm.sh vnc` / `vnc stop` | Watch a Packer build's screen in KRDC through an SSH tunnel / close the tunnel |
| `lab-in-vm.sh status` | The VM, its address, its network |
| `lab-in-vm.sh destroy` | Delete the VM and its disks |

It only ever deletes a VM it created itself: every VM it makes carries a label, and it refuses
to touch a VM that merely has the same name. Its network is `192.168.150.0/24`, deliberately
not `192.168.122.x`, which the lab inside uses.

### If it stops

Read the error, fix the cause, run the same command again (`./setup.sh`, or inside the VM
`cd opnsense-iac-lab && ./setup.sh`). Every step checks first and skips what is done, so it
resumes where it stopped. Don't use `lab-in-vm.sh run` to retry: that starts over.

---

## What setup.sh does

Every step is idempotent. Times are from the verified run.

| Step | Does | About |
|---|---|---|
| System | Ubuntu 26.04? KVM? sudo (asked once, then kept alive)? | seconds |
| Packages | QEMU, libvirt, xorriso, bzip2, dig, curl, git, Python, Perl, OpenSSL, ansible-core | 3–5 min |
| Ansible collections | `community.docker`, at the version pinned in `ansible/requirements.yml` | seconds |
| Terraform and Packer | HashiCorp's apt repository; its signing key checked against `pins.env` (and replaced if an old one is installed) | 1–2 min |
| Groups | Your user into `libvirt` and `kvm` | seconds |
| libvirt | Removes libvirt's stock `default` network, unless Terraform manages it; ensures a storage pool | seconds |
| Your account | SSH key if missing; the `terraform` shell function in `~/.bashrc` | seconds |
| Machine values | `gen-secrets.sh`; then `terraform/terraform.tfvars` and `ansible/host_vars/*.yml`, **only if missing** | seconds |
| OPNsense installer | Download (resumable), check the `.bz2`, decompress, check the `.iso`, cache | ~30 min from Japan |
| Golden image | Packer installs OPNsense from the ISO, adds the boot hook; placed in the pool read-only. Skipped if it exists | ~20 min |
| The lab | `scripts/rebuild.sh` (converge), ending with the smoke tests | ~15 min nested, less on hardware |

New group memberships normally need a new login. `setup.sh` runs Packer under `sg kvm` and
`rebuild.sh` under `sg libvirt`, so it works in the same run.

On a machine that is already set up (like the original host), `setup.sh` finds almost
everything done. It still ends by running `rebuild.sh`, which converges the live lab.

---

## What rebuild.sh does

`setup.sh` runs it at the end; run it directly afterwards to apply changes.

| Command | Does | Use when |
|---|---|---|
| `scripts/rebuild.sh` | **Converge**: build what is missing, fix drift, keep the rest | Applying a change; after a failed run |
| `scripts/rebuild.sh --fresh` | Destroy everything Terraform manages, then build from nothing | Proving the from-scratch path |
| `scripts/rebuild.sh --fresh --yes` | Same, without asking | Automation |

Stages: preflight → secrets and baseline (`gen-secrets.sh`, `render-baseline.py`) → config
backup (safety net) → host bridges (Ansible; asks for the sudo password only if sudo needs
one) → destroy (`--fresh` only) → Terraform (`terraform/`) → wait for OPNsense's API (boot,
baseline load, one reboot) → firewall policy (Terraform, `policy/`) → Ubuntu server (SSH,
host key, cloud-init) → Pi-hole (Ansible) → smoke tests.

---

## Smoke tests

`scripts/smoke.sh`, run by `rebuild.sh`, or alone any time: `TRIES=1 scripts/smoke.sh`.

| Layer | Check | Pass means |
|---|---|---|
| 1 host | `br-clients` and `br-trunk` are UP | Bridges exist |
| 1 host | All three VMs running | VMs started |
| 1 host | `tapcheck` exits 0 | Every VM NIC is on the right bridge |
| 2 OPNsense | API returns 200 with the automation key | The baseline loaded (only it has that key) |
| 2 OPNsense | `terraform plan` in `policy/` shows no changes | **The firewall matches the code** (drift check) |
| 3 routing | Route to `192.168.100.0/24` via `.69` | `default` network's route is in place |
| 3 routing | Ansible reaches the server over SSH | Host reaches SERVERS through OPNsense |
| 4 services | Pi-hole answers DNS | Pi-hole works |
| 4 services | Server can `curl` the internet | NAT through OPNsense works |
| 5 VLANs | Kea leased vlantest a `10.20.10.x` address | Trunk, tagging and Kea work |
| 6 rules | Guest agent in vlantest answers | Host can run commands inside vlantest |
| 6 rules | vlantest pings `8.8.8.8` | Positive control |
| 6 rules | vlantest **cannot** ping `10.20.10.1` | Client zones can't reach the firewall |
| 6 rules | `dig @192.168.100.10` works | Positive control: DNS through Pi-hole |
| 6 rules | `dig @8.8.8.8` gets **no reply** | DNS anywhere else is blocked |
| 6 rules | TCP 443 to `1.1.1.1` works | Positive control for the port tests |
| 6 rules | TCP 853 to `1.1.1.1` **fails** | DNS-over-TLS is blocked |

Layer 6 runs inside vlantest through the QEMU guest agent (a private channel, no network path),
so VLAN isolation is tested without weakening it. Every "blocked" check has a positive control.

---

## Generated files and secrets

Created once, never overwritten, never committed. **Back up `~/.config/opnsense-iac-lab/`**:
the root password there is the break-glass login for OPNsense's console.

| File | Holds |
|---|---|
| `~/.config/opnsense-iac-lab/root-password` (+ `.hash`) | OPNsense root password: lowercase letters and digits only, because Packer types it |
| `~/.config/opnsense-iac-lab/api.env` | The `automation` user's API key (Terraform, scripts) |
| `~/.config/opnsense-iac-lab/console-password` (+ `.hash`) | Console password for the lab's Ubuntu VMs |
| `~/.config/opnsense-iac-lab/pihole-password` | Pi-hole admin password |
| `~/.config/opnsense-iac-lab/webgui.crt` / `.key` | OPNsense web GUI certificate |
| `terraform/terraform.tfvars` | `libvirt-qemu` UID, `kvm` GID, console password hash |
| `ansible/host_vars/localhost.yml` | Bridge ports (USB adapter or none); sudo-rs workaround if needed |
| `ansible/host_vars/ubuntu-server.yml` | Pi-hole password |
| `~/.cache/opnsense-iac-lab/iso/` | The verified OPNsense ISO |
| `~/.cache/opnsense-iac-lab/baseline.xml` | Rendered every run, byte-identical unless an input changed |

---

## pins.env: everything that is pinned

One file holds every pinned version, checksum and signing key; scripts read it from there.

| Pin | Changes when | On a failed check |
|---|---|---|
| `HASHICORP_FPR` | HashiCorp rotates its key (rare; last on 2026-09-09) | Verify the new fingerprint at `hashicorp.com/trust/security` (a different host from the repository), update the line, say how you verified it in the commit message |
| `OPNSENSE_VERSION`, `OPNSENSE_URL`, `OPNSENSE_BZ2_SHA256`, `OPNSENSE_ISO_SHA256` | Only when **you** upgrade OPNsense | Never by itself: release files don't change. A mismatch means a bad download or a tampered file |

**Upgrading OPNsense** (for example to 26.7): new values in `pins.env` (checked against OPNsense's
published checksums), its factory config saved as `opnsense-image/factory-config-<version>.xml`
(certificate and password hashes removed), `render-baseline.py` pointed at it, then a full
`lab-in-vm.sh run`. One change, tested on its own.

Things that change constantly (Ubuntu's `current` cloud image) are not pinned: they are checked
against the publisher's checksum list on every download.

---

## How the firewall is built

| Part | Holds | Made by | Applied |
|---|---|---|---|
| **Golden image** | Installed OPNsense + boot hook, no config | Packer (`opnsense-image/golden.pkr.hcl`) from the pinned ISO | Terraform builds OPNsense's disk as a thin layer on it |
| **Baseline** | Interfaces, VLAN devices, users (root, automation), API key, certificate, SSH, Kea on, dnsmasq off, two bootstrap rules | `scripts/render-baseline.py`: OPNsense's factory config + `network.json` + secrets | At boot, by the hook, from the config ISO |
| **Policy** | Aliases, 28 rules, 5 Kea subnets | `policy/*.tf` + `network.json` | Terraform, through the API |

**To change the firewall:** edit `policy/*.tf` or `network.json`, run `scripts/rebuild.sh`, check
the smoke tests. **Not** in the GUI: the drift check fails until code and firewall agree.
A new client VLAN is one line in `network.json`.

| Zone | Rules, in order |
|---|---|
| WAN | host → Pi-hole TCP 22, TCP/UDP 53, TCP 80 (plus the two bootstrap rules in the baseline) |
| SERVERS | → anywhere (IPv4 and IPv6) |
| CLIENTS, VLAN10/20/30 | pass DNS to Pi-hole · block DNS elsewhere · block TCP 853 · block the firewall · block `RFC1918` · pass anywhere |

---

## The golden image (Packer)

Packer boots the ISO in a temporary VM and **types** the installer's keystrokes on a timer; it
cannot see the screen. The keystrokes were worked out by recording a manual install, and the
waits are the important part:

| Lesson | In the template |
|---|---|
| Setting the root password takes 5–10 s before the menu returns; a key sent earlier is lost | 15 s wait after the password |
| The reboot after the install took longer than estimated | 5 min wait after "Reboot now" |
| Typing through VNC into a nested VM can drop keys | 150 ms between keystrokes |
| Characters needing Shift are risky to type blind | Root password is lowercase letters and digits |
| QEMU's machine has an extra empty CD drive, so the hook CD's number varies | The shell step searches every `/dev/cd*` |
| If anything fails, the VM must not look finished | Only a fully successful shell step powers it off; otherwise the build times out |

**If a build stalls:** watch it (`lab-in-vm.sh vnc`, or VNC to `127.0.0.1:5901` on the build
machine), note the screen it is stuck on, lengthen the wait before that screen. For a key-by-key
log: `PACKER_LOG=1 PACKER_LOG_PATH=packer.log` (it can contain typed passwords: use a throwaway
password for debugging, and delete the log afterwards).

**The boot hook** (`opnsense-image/10-configdisk`): at every boot it looks for a CD holding an
OPNsense config as `user-data`. If its checksum differs from the last one applied, it copies it to
`/conf/config.xml`, records the checksum and reboots once. Same file next boot: nothing happens.

---

## Config backups (safety net)

Nothing is rebuilt from backups. `rebuild.sh` saves the running config when OPNsense answers,
for inspection and manual recovery (System → Configuration → Backups). The API serves the newest
entry in OPNsense's configuration **history**, not necessarily the live config; the backup step
rejects anything that looks like a factory config.

---

## Terraform and TMPDIR

The libvirt provider writes cloud-init ISOs to `$TMPDIR`; `/tmp` is tmpfs on Ubuntu (wiped at
reboot, aged out after 10 days). `rebuild.sh` sets `TMPDIR=~/.cache/terraform-tmp`; for typing
`terraform` by hand, `setup.sh` adds a shell function that does the same. VMs attach pool copies
of the ISOs, and `terraform/guards.tf` warns if an ISO ever lands in `/tmp`.

---

## Reaching the lab from another machine

The lab host is the only way in (a bastion): the lab VMs trust its key, so no other machine's key
is installed anywhere. On the other machine, in `~/.ssh/config`:

```
Host Server                      # shell on the Ubuntu server, through the lab host
    HostName <lab host's address>
    User <your user on the lab host>
    RequestTTY yes
    RemoteCommand ssh ubuntu@192.168.100.10

Host pihole-admin                # then browse http://localhost:8080/admin
    HostName <lab host's address>
    User <your user on the lab host>
    LocalForward 8080 192.168.100.10:80
    SessionType none
```

---

## Keeping it rebuildable

- Make changes on a branch; prove them with `scripts/lab-in-vm.sh run` (it clones what is
  **pushed**); merge only after the smoke tests pass.
- Firewall changes through `policy/` or `network.json`; networks and VMs through `terraform/`;
  never by hand.
- Don't change things inside VMs by hand: change the code and rebuild the VM.
- Never commit: `*.tfstate`, `terraform.tfvars`, `host_vars/*.yml`, `*.env` (except `pins.env`),
  config backups, anything from `~/.config/opnsense-iac-lab/`.

---

## Known gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `setup.sh` stops: HashiCorp key has an unexpected fingerprint | HashiCorp rotated its key | Verify the new one independently, update `HASHICORP_FPR` in `pins.env` |
| `[sudo: authenticate] Password:` although sudo is passwordless | `sudo -v` requires *every* matching sudoers rule to be NOPASSWD | `setup.sh` tries `sudo -n true` first; only then `sudo -v` |
| `netplan apply`: "networkmanager backend settings found but renderer is not NetworkManager" | Template's NetworkManager block on a systemd-networkd host | `bridge.yml` now includes it only where NetworkManager runs |
| Packer build goes off course after the password | Keys sent before the menu returned | Lengthen that wait (see the table above) |
| `lab-in-vm.sh`: "only N MiB RAM available" | Not enough free RAM | Close apps, or `LAB_VM_RAM_MB` |
| `vnc`: "Address already in use" | An old tunnel holds port 5901 | `lab-in-vm.sh vnc stop` |
| "No such file" for a file you just copied | The command ran on another machine | Check the prompt: `user@host:folder` |
| `rebuild.sh` times out waiting for OPNsense | Baseline didn't load, or wrong key | Console banner; log in with `~/.config/opnsense-iac-lab/root-password`; `/conf/configdisk.sha256` |
| Drift check fails | Firewall changed outside `policy/` | `terraform -chdir=policy plan` shows what differs |
| Phone has no DNS | Android Private DNS set to a provider | Set it to Automatic or Off (DNS-over-TLS is blocked) |
| `search_rule` API returns 0 rules | Needs `?interface=...` | Ask per interface |
| A VM lost its network after a bridge change | Restarting a bridge unplugs its VMs | `scripts/tapcheck`; restart the VM |
| `grep -q` in a pipe fails at random | With `pipefail`, the writer gets SIGPIPE when `grep -q` exits early | Don't use `grep -q` in pipes; let the reader read everything |

---

## Automation status

| Piece | Status |
|---|---|
| Fresh Ubuntu 26.04 → verified lab, one command (`setup.sh`) | **Done**, verified 2026-10-02 (62 min, unattended) |
| Any Linux with KVM → the same, in a VM (`lab-in-vm.sh run`) | **Done** |
| Golden image built by Packer from the pinned ISO | **Done** |
| Pinned and verified inputs (`pins.env`) | **Done** |
| Firewall as code: baseline + 28 rules, aliases, Kea subnets | **Done** |
| Smoke tests: 6 layers, drift check, DNS enforcement | **Done** |
| opnwatch: own read-only API key (`monitor` user) | Parked |
| Reboot OPNsense in converge mode when the baseline changes | Parked |
| Verify OPNsense's release signature, not only checksums | Parked |
| OPNsense 26.7 | Parked (one pin change + a test run) |
| Nightly `lab-in-vm.sh run` from CI (Jenkins) | Later |
| CSV parameter sheet generating `network.json` | Later |
