# libvirt's NAT network. OPNsense's WAN sits on it.
# Terraform creates it (setup.sh first removes libvirt's stock 'default').

locals {
  # The DHCP reservation, OPNsense's WAN NIC and the route to SERVERS
  # all depend on these two values agreeing. Define them once.
  opnsense_wan_mac = "52:54:00:b4:49:cb"
  opnsense_wan_ip  = "192.168.122.69"
}

resource "libvirt_network" "default" {
  name      = "default"
  autostart = true

  forward = {
    mode = "nat"
  }

  bridge = {
    name  = "virbr0"
    stp   = "on"
    delay = "0"
  }

  ips = [{
    address = "192.168.122.1"
    netmask = "255.255.255.0"
    dhcp = {
      ranges = [{ start = "192.168.122.2", end = "192.168.122.254" }]
      hosts = [{
        mac  = local.opnsense_wan_mac
        name = "opnsense"
        ip   = local.opnsense_wan_ip
      }]
    }
  }]

  # Host route to SERVERS, through OPNsense's WAN.
  routes = [{
    address = "192.168.100.0"
    prefix  = 24
    gateway = local.opnsense_wan_ip
  }]
}
