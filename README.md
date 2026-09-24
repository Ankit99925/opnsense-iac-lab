# lab

A segmented home network running as virtual machines on one Ubuntu host
(`mera-server`). OPNsense is the firewall and router; everything else sits
behind it in a zone.

This file is the runbook. It covers the topology, which tool owns which piece,
how to rebuild it, the steps that are still manual, and the things that cost
hours to work out the first time.

---

## Topology

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

Four bridges exist on the host, created by three different things. This matters
because none of them knows about the others.

| Bridge       | Zone     | Created by                          |
|--------------|----------|-------------------------------------|
| `virbr0`     | WAN      | libvirt's built-in `default` network |
| `virbr2`     | SERVERS  | libvirt, from `libvirt_network.servers` here |
| `br-clients` | CLIENTS  | Ansible, via netplan                |
| `br-trunk`   | trunk    | Ansible, via netplan                |

| Piece                                   | Managed by            |
|-----------------------------------------|-----------------------|
| SERVERS network, all VMs, all volumes   | Terraform (this repo) |
| `br-clients`, `br-trunk`                | Ansible (`~/ansible/lab`) |
| Pi-hole                                 | Ansible               |
| DHCP reservation for OPNsense, host route | libvirt `default` network, edited by hand |
| Firewall rules, VLANs, Kea DHCP         | OPNsense, by hand     |

Terraform refers to `br-clients` and `br-trunk` by name only. Nothing checks
that Ansible has created them. A typo on either side breaks the link silently.

---

## Rebuild order

1. **Ansible** creates the bridges. Terraform will define VMs that attach to
   them, and a VM cannot start if its bridge does not exist.

       cd ~/ansible/lab
       ansible-playbook -i inventory.ini bridge.yml -K

2. **Terraform** creates the SERVERS network, the VMs and their disks.

       cd ~/terraform/lab
       terraform init
       terraform plan
       terraform apply

3. **Install OPNsense by hand** — see below.

4. **Restore the OPNsense config** — see below.

5. **Ansible** deploys Pi-hole.

       cd ~/ansible/lab
       ssh-keygen -R 192.168.100.10     # the server has new host keys
       ansible-playbook -i inventory.ini pihole.yml

6. **Check the wiring.**

       ops tapcheck

---

## The manual steps

### Installing OPNsense

OPNsense ships an interactive installer, not a pre-built cloud image, so this
cannot be automated here. Do it once and keep the result.

1. `terraform apply` with the cdrom at `boot = { order = 1 }`
2. `virsh start opnsense`, then open the console in Virt-Manager
3. At the live prompts, decline VLANs, WAN `vtnet0`, LAN `vtnet1`
4. Log in as `installer` / `opnsense`, install to `vtbd0`, UFS
5. **Halt at the end — do not reboot**, or it boots the installer again
6. Swap the boot orders in `main.tf` (disk 1, cdrom 2) and `terraform apply`
7. Save a golden image before first boot:

       sudo cp /var/lib/libvirt/images/opnsense.qcow2 \
               /var/lib/libvirt/images/opnsense-26.1-base.qcow2

That copy is a clean installed system with no configuration. Pointing the
volume at it as a backing store would remove this step from future rebuilds.

### Reaching the web interface for the first time

A fresh install serves its interface on the LAN side, and blocks the WAN side.
The host is only on WAN. So:

1. OPNsense console, option **8** for a shell
2. `pfctl -d` — disables the packet filter until the next reboot
3. Browse from the host to `https://192.168.122.69`, accept the certificate
4. Restore the config; the firewall comes back with your own rules

Afterwards, an SSH tunnel is the tidier route and needs no rule:

    ssh -N -L 8080:localhost:443 root@192.168.122.69
    # then browse to https://localhost:8080

### Restoring the config

System → Configuration → Backups → Restore, with the newest file from
`~/lab-backup/`. It reboots.

**The restore replaces the root password** with the one from the backup. Know
it before you start.

Check the console header afterwards: WAN, SERVERS and CLIENTS should be on
`vtnet0`, `vtnet1` and `vtnet2`. If they are not, the NIC order in `main.tf` is
wrong — see below.

### The libvirt `default` network

Two things live in libvirt's own network definition, not in this repo:

    virsh net-edit default

A reservation, inside `<dhcp>`:

    <host mac='52:54:00:b4:49:cb' name='opnsense' ip='192.168.122.69'/>

And a route, after the closing `</ip>`:

    <route address='192.168.100.0' prefix='24' gateway='192.168.122.69'/>

The route is what lets the host reach the server on SERVERS, which is what
Ansible needs. The reservation is what keeps that gateway address stable, and
it works because the WAN MAC is pinned in `main.tf`.

Restart the network for changes to take effect, with OPNsense stopped first:

    virsh net-destroy default && virsh net-start default

A copy of the definition is kept at `~/lab-backup/net-default.xml`.

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

---

## What is not in this repo

Firewall rules, VLAN definitions, Kea DHCP and aliases live inside OPNsense.
They are backed up by `~/python/opnwatch`, which fetches the config daily and
reports which sections changed.

Pi-hole is deployed by `~/ansible/lab/pihole.yml`.

Nothing here is reproducible on Windows: the libvirt provider and netplan are
both Linux-only.
