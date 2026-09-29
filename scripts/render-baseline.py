#!/usr/bin/env python3
"""render-baseline.py: build OPNsense's baseline config.xml.

Starts from OPNsense's own factory config (opnsense-image/factory-config-26.1.xml)
and applies this lab's decisions: interfaces, VLANs, users, the web GUI
certificate, SSH, Kea on / dnsmasq off, and the two bootstrap rules that let the
host (and Terraform) in. Aliases, firewall policy and Kea subnets are pushed
afterwards by the Terraform stack in policy/.

Deterministic: the same inputs always give byte-identical output, so the boot
hook only reloads the firewall when something actually changed.
"""
import base64, hashlib, os, subprocess, sys, uuid
import xml.etree.ElementTree as ET
from pathlib import Path

REPO    = Path(__file__).resolve().parent.parent
FACTORY = REPO / "opnsense-image" / "factory-config-26.1.xml"
SECRETS = Path(os.environ.get("SECRETS_DIR", Path.home() / ".config/opnsense-iac-lab"))
SSH_PUB = Path(os.environ.get("SSH_PUB", Path.home() / ".ssh/id_ed25519.pub"))
OUT     = Path(os.environ.get("BASELINE_OUT", Path.home() / ".cache/opnsense-iac-lab/baseline.xml"))

MGMT_HOST = "192.168.122.1"   # mera-server, on libvirt's default network
WAN_DEV   = "vtnet0"
TRUNK     = "vtnet3"
# The lab's zones: OPNsense's internal name, device, description, address, prefix
ZONES = [
    ("lan",  "vtnet1", "SERVERS", "192.168.100.1", 24),
    ("opt2", "vtnet2", "CLIENTS", "192.168.200.1", 24),
    ("opt3", "vlan01", "VLAN10",  "10.20.10.1",    24),
    ("opt4", "vlan02", "VLAN20",  "10.20.20.1",    24),
    ("opt5", "vlan03", "VLAN30",  "10.20.30.1",    24),
]
# VLAN devices on the trunk: device, 802.1Q tag, description
VLANS = [("vlan01", 10, "VLAN10"), ("vlan02", 20, "VLAN20"), ("vlan03", 30, "VLAN30")]

NS = uuid.UUID("3f6c1c1e-6d8e-4c7a-9a55-0b2a6f1d0c01")   # fixed, so every ID is stable
def uid(name): return str(uuid.uuid5(NS, name))

def sub(parent, tag, text=None, **attrs):
    e = ET.SubElement(parent, tag, attrs)
    if text is not None: e.text = str(text)
    return e

def setx(parent, tag, text):
    e = parent.find(tag)
    if e is None: e = ET.SubElement(parent, tag)
    e.text = str(text)
    return e

def drop(parent, tag):
    for e in parent.findall(tag): parent.remove(e)

def read_env(path):
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1); out[k.strip()] = v.strip()
    return out

def api_secret_hash(secret):
    # OPNsense stores API secrets as SHA-512 crypt with an empty salt ($6$$...).
    # Python no longer ships a crypt module; Perl's calls the system library.
    return subprocess.run(["perl", "-e", "print crypt($ENV{S}, q{$6$$})"],
                          env={**os.environ, "S": secret},
                          capture_output=True, text=True, check=True).stdout

def main():
    os.umask(0o077)
    for p in (FACTORY, SECRETS / "root-password.hash", SECRETS / "api.env",
              SECRETS / "webgui.crt", SECRETS / "webgui.key", SSH_PUB):
        if not p.exists(): sys.exit(f"missing {p} (run scripts/gen-secrets.sh first?)")

    tree = ET.parse(FACTORY); r = tree.getroot()
    api       = read_env(SECRETS / "api.env")
    root_hash = (SECRETS / "root-password.hash").read_text().strip()
    crt, key  = (SECRETS / "webgui.crt").read_bytes(), (SECRETS / "webgui.key").read_bytes()
    pub       = SSH_PUB.read_text().strip()

    # 1. no setup wizard
    drop(r, "trigger_initial_wizard")

    # 2. system: console, SSH, users, web GUI certificate
    s = r.find("system")
    setx(s, "disableconsolemenu", 1)             # console menu asks for the root password
    drop(s, "ssh"); ssh = sub(s, "ssh")
    sub(ssh, "enabled", "enabled"); sub(ssh, "permitrootlogin", 1)
    # deliberately no <passwordauth> (key-only) and no <no_sshlockout> (lockout stays on)

    root = next(u for u in s.findall("user") if u.findtext("name") == "root")
    setx(root, "password", root_hash)
    setx(root, "authorizedkeys", base64.b64encode(pub.encode()).decode())
    setx(root, "apikeys", "")                    # root gets no API key; automation does

    auto = sub(s, "user", uuid=uid("user:automation"))
    for tag, val in [("uid", 2000), ("name", "automation"), ("disabled", 0), ("scope", "user"),
                     ("expires", ""), ("authorizedkeys", ""), ("otp_seed", ""), ("shell", ""),
                     ("password", ""), ("pwd_changed_at", ""), ("landing_page", ""),
                     ("comment", ""), ("email", ""),
                     ("apikeys", f'{api["OPN_KEY"]}|{api_secret_hash(api["OPN_SECRET"])}'),
                     ("priv", "page-all"), ("language", ""),
                     ("descr", "Automation: Terraform and scripts, API only"), ("dashboard", "")]:
        sub(auto, tag, val)
    if s.find("nextuid") is not None: setx(s, "nextuid", 2001)

    refid = hashlib.sha256(crt).hexdigest()[:13]
    cert = sub(r, "cert", uuid=uid("cert:webgui"))
    for tag, val in [("refid", refid), ("descr", "opnsense-iac-lab web GUI"), ("caref", ""),
                     ("crt", base64.b64encode(crt).decode()), ("csr", ""),
                     ("prv", base64.b64encode(key).decode())]:
        sub(cert, tag, val)
    setx(s.find("webgui"), "ssl-certref", refid)

    # 3. interfaces
    ifs = r.find("interfaces")
    wan = ifs.find("wan")
    setx(wan, "if", WAN_DEV)
    drop(wan, "blockpriv"); drop(wan, "blockbogons")   # WAN is itself a private network
    for name, dev, descr, ip, prefix in ZONES:
        e = ifs.find(name)
        if e is None: e = sub(ifs, name)
        for c in list(e): e.remove(c)          # start clean (drops the factory's IPv6 tracking)
        for tag, val in [("if", dev), ("descr", descr), ("enable", 1), ("spoofmac", ""),
                         ("ipaddr", ip), ("subnet", prefix)]:
            sub(e, tag, val)

    # 4. VLAN devices on the trunk
    vl = r.find("vlans")
    for c in list(vl): vl.remove(c)
    for dev, tag, descr in VLANS:
        v = sub(vl, "vlan", uuid=uid(f"vlan:{dev}"))
        for t, val in [("if", TRUNK), ("tag", tag), ("pcp", 0), ("proto", ""),
                       ("descr", descr), ("vlanif", dev)]:
            sub(v, t, val)

    # 5. DHCP: Kea on for every zone; dnsmasq (the factory's DHCP) off
    dm = r.find("dnsmasq")
    setx(dm, "enable", 0)
    for tag in ("dhcp_ranges", "dhcp_options", "hosts"): drop(dm, tag)
    setx(dm, "interface", "")
    kg = r.find("OPNsense/Kea/dhcp4/general")
    setx(kg, "enabled", 1)
    setx(kg, "interfaces", ",".join(z[0] for z in ZONES))

    # 6. firewall: only the bootstrap rules; everything else comes from policy/
    f = r.find("filter")
    drop(f, "rule")
    for port, what in [(443, "web GUI and API"), (22, "SSH")]:
        ru = sub(f, "rule", uuid=uid(f"rule:bootstrap:{port}"))
        for t, val in [("type", "pass"), ("interface", "wan"), ("ipprotocol", "inet"),
                       ("statetype", "keep state"),
                       ("descr", f"Bootstrap: host to firewall, {what} (baseline)"),
                       ("direction", "in"), ("quick", 1), ("protocol", "tcp")]:
            sub(ru, t, val)
        src = sub(ru, "source"); sub(src, "address", MGMT_HOST)
        dst = sub(ru, "destination"); sub(dst, "network", "(self)"); sub(dst, "port", port)

    OUT.parent.mkdir(parents=True, exist_ok=True); os.chmod(OUT.parent, 0o700)
    tmp = OUT.with_name(OUT.name + ".tmp")
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    tmp.replace(OUT)
    print(f"wrote {OUT}")

if __name__ == "__main__":
    main()
