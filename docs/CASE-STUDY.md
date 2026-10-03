# Case study: from a hand-built lab to one command

## TL;DR

I turned a firewall lab I had built by hand (an OPNsense VM, Ubuntu VMs, bridges and VLANs on
KVM) into code that rebuilds it from nothing and proves it works. Today, one command on a fresh
Ubuntu 26.04 machine produces the whole lab, firewall policy included, in about an hour,
unattended, and ends with 17 smoke tests. Getting there meant finding and fixing 16 real
problems; most were assumptions that only broke on a machine that wasn't mine.

**Run it**

```bash
git clone https://github.com/Ankit99925/opnsense-iac-lab.git && cd opnsense-iac-lab
./setup.sh                          # on Ubuntu 26.04: asks for your sudo password once
LAB_VM_YES=1 scripts/lab-in-vm.sh run   # on any other Linux with KVM: same, inside a fresh Ubuntu VM
```

**Use it**

```bash
TRIES=1 scripts/smoke.sh            # prove it still works (read-only, about a minute)
scripts/rebuild.sh                  # apply a change: converge to what the code says
scripts/rebuild.sh --fresh          # destroy everything and rebuild from nothing
scripts/lab-in-vm.sh ssh            # VM path: a shell on the lab host
```

Firewall rules live in `policy/*.tf`, the network's shape in `network.json`: edit, then
`scripts/rebuild.sh`. Pi-hole's admin page is `http://192.168.100.10/admin` from the lab host;
the root password for OPNsense's console is in `~/.config/opnsense-iac-lab/root-password`.

| | |
|---|---|
| Rebuild of the lab on its host | about 7.5 minutes |
| `setup.sh` on a fresh Ubuntu VM → verified lab | 62 minutes, unattended, nothing copied in (creating the VM adds a few minutes, plus ~600 MB for Ubuntu's cloud image the first time) |
| Smoke tests | 17 checks in 6 layers, incl. a drift check and firewall block tests |
| Firewall policy as code | 3 aliases, 28 rules, 5 DHCP subnets |
| Tools | Terraform, Ansible, Packer, Bash, Python, libvirt/KVM, OPNsense |

---

## Where it started

The lab worked, but only on one machine, and only because I remembered how I'd built it:

- OPNsense installed by hand from the ISO, its config restored from a backup through the GUI
- libvirt's `default` network edited by hand (a DHCP reservation and a route)
- VMs and networks partly in Terraform, bridges in Ansible, the rest in my head

The question I set out to answer: **if this machine died, could someone else rebuild it from the
repo alone?** The honest answer was no.

---

## What I built, in four phases

### 1. One-command rebuild (on the original host)

- **Brought hand-made things under code.** Imported the `default` network into Terraform. The
  provider only read back part of it, so the import planned a replacement; I did it once, in a
  planned window, with a backup and a written rollback.
- **Golden image + boot hook.** An installed OPNsense with a small boot script that loads a
  config from an attached ISO, once (a checksum marker stops it reloading on every boot).
- **Smoke tests in six layers,** from "bridges are up" to "VLAN 10 cannot reach the firewall."
  For tests inside the isolated VLAN I used the QEMU guest agent, so testing needs no network
  path into it. Every "blocked" test has a positive control next to it.
- **`rebuild.sh`:** converge by default, `--fresh` to destroy and rebuild. 7.5 minutes.

### 2. One repository

Merged the Terraform and Ansible repos into one, keeping both histories (`git filter-repo`),
made scripts find files relative to themselves, scanned the full history with gitleaks, made it
public.

### 3. Firewall as code

The rebuild still *restored a backup* for the firewall: it worked, but nobody could read the rules
in the repo. I split OPNsense's config into two layers, the same pattern firewall vendors use:

- **Baseline** (what the API can't do: interfaces, VLANs, users, API key, certificate), generated
  by a script from OPNsense's own factory config, a shared `network.json` and generated secrets.
  Deterministic: same inputs, byte-identical file.
- **Policy** (aliases, rules, DHCP subnets) as Terraform, pushed through OPNsense's API.

Writing the rules out forced decisions: I dropped a WireGuard setup that could never work behind
my carrier-grade NAT, closed a gap that let Wi-Fi clients reach the hypervisor, forced all DNS
through Pi-hole, and narrowed the host's access. The switch-over ran on a branch, was proven
with a `--fresh` rebuild, then merged.

### 4. A fresh machine

The real test: a machine that has never seen the lab.

- **`lab-in-vm.sh`** creates a fresh Ubuntu VM on any Linux with KVM (I use Bazzite), clones
  the public repo inside it, and runs `setup.sh`. It only deletes VMs it labelled itself.
- **`setup.sh`** installs everything, checks every download against `pins.env`, generates every
  secret and machine-specific file, builds the golden image with **Packer** (which types through
  OPNsense's installer), then runs `rebuild.sh`.
- Acceptance run: `setup.sh` took **62 minutes with no input,** and all 17 checks passed. (The
  VM itself took a few more minutes to create, and Ubuntu's cloud image was already cached from
  earlier runs; a first-ever run also downloads it, about 600 MB.)

---

## The problems, and what caused them

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Importing the `default` network planned a *replacement* | The provider read back only some attributes, so code and state "differed" | Replaced it once in a planned window; later plans clean |
| 2 | VMs would fail to start after a host reboot | Cloud-init ISOs lived in `/tmp`, which is tmpfs (wiped at boot, aged out after 10 days) | VMs attach copies in the storage pool; `TMPDIR` points elsewhere; a Terraform `check` warns |
| 3 | A `--fresh` rebuild came up as a blank firewall | OPNsense's backup API serves the newest *history* entry, which after my hook-based restore was the factory config | Backups rejected if they look like factory configs; later, the config came from code |
| 4 | Smoke test found vlantest on the wrong VLAN | A hand edit inside the VM, invisible to Terraform | Rebuilt the VM from code (cattle, not pets) |
| 5 | The rules API returned 0 rules | The search needs an interface parameter | Query per interface |
| 6 | The restored config carried dead settings and gaps | Restoring copies everything, including old mistakes | Generate the config from code instead |
| 7 | Permanent drift on rules with destination "any" | Known provider bug | Leave the field out (same meaning) |
| 8 | `sudo` asked for a password on a passwordless user | `sudo -v` requires *every* matching sudoers rule to be NOPASSWD | Try `sudo -n true` first |
| 9 | Setup refused HashiCorp's signing key | HashiCorp rotated it the month before | Confirmed the new fingerprint on a different HashiCorp host, updated the pin |
| 10 | `pins.env` wouldn't commit | My `*.env` ignore rule (for secrets) was too broad | An explicit exception for the public file |
| 11 | "Network already active" error at random | `grep -q` exits early; with `pipefail`, the writer's SIGPIPE fails the pipeline | Let the reader consume all input |
| 12 | Harness said "not enough RAM" | It checked before deleting the old VM | Check after |
| 13 | Packer's password step went wrong | The installer takes 5–10 s to apply a password; keys sent sooner were lost | 15 s wait. **Found by watching the build over VNC** |
| 14 | Packer typed into a machine still rebooting | Reboot slower than my estimate | 5 min wait, measured next time |
| 15 | `netplan apply` rejected the bridge config | My template assumed NetworkManager; cloud images use systemd-networkd | NetworkManager block only where it runs |
| 16 | Mirror returned 403 for my OPNsense version | Mirrors keep only the newest major release | Download once from the archive, cache it, verify by pinned checksum |

Problems 8, 9, 13 and 15 only appeared on the fresh machine. My original host had been quietly
covering for them, which is the best argument I know for testing on a clean machine.

---

## Decisions I'd defend in a review

- **Image and config are separate.** A rule change never needs a new image.
- **Everything external is pinned and verified,** and each pin records how it was checked.
  Failing loudly on a changed key is the point: it is also what a compromised server looks like.
- **Deterministic generation,** so the firewall only reloads when something really changed.
- **Least privilege:** root has no API key; automation has its own user; SSH is key-only.
- **Ubuntu 26.04 only for the host,** plus a VM path for everything else. One platform done
  properly beats several done badly.
- **Tests that prove the policy,** not only that traffic flows: an allow-everything firewall
  would pass connectivity tests.

---

## What's next

Verify OPNsense's release signature (not only checksums); let converge mode apply baseline
changes (reboot OPNsense, re-push policy); a read-only API key for monitoring; OPNsense 26.7;
a nightly CI run of the fresh-machine test.

---

## Concepts I learned (my own glossary)

| Concept | In one line |
|---|---|
| Infrastructure as code | The repo is the truth; documentation drifts, code doesn't |
| Terraform state, drift, import | Terraform only knows what is in its state; hand-made things are invisible until imported |
| Idempotent | Safe to run again: it only does what is missing |
| Converge vs fresh | "Make it match the code" vs "destroy and rebuild" |
| Day 0 / Day 1 / Day 2 | Bootstrap / configure / operate |
| Golden image | A prepared disk to build from, never booted directly |
| Single source of truth | Each value written once (`network.json`, `pins.env`) |
| Supply-chain verification | Trust a download only after checking it against a value obtained independently |
| Positive control | A test that must pass, so a "blocked" result can only mean the rule |
| Pets vs cattle | Repair by hand vs replace from code |
| Least privilege | Every account gets only what its job needs |
| Bastion host | One hardened way in; private machines trust only it |
| tmpfs | A filesystem in RAM: gone at reboot |
| `pipefail` and SIGPIPE | Why `grep -q` in a pipe can fail a script at random |
| netplan renderers | NetworkManager on desktops, systemd-networkd on servers |
| Nested virtualization | VMs inside VMs; needed for the fresh-machine test |
| git branches, fast-forward, revert, filter-repo | Change safely, undo safely, reshape history |
