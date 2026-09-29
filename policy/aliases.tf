# Named addresses: rules say what they mean, and each address is written once.

resource "opnsense_firewall_alias" "mgmt_host" {
  name        = "MGMT_HOST"
  type        = "host"
  content     = [local.net.mgmt_host]
  description = "mera-server, the lab host (managed by Terraform)"
}

resource "opnsense_firewall_alias" "pihole" {
  name        = "PIHOLE"
  type        = "host"
  content     = [local.net.pihole]
  description = "Pi-hole DNS server (managed by Terraform)"
}

resource "opnsense_firewall_alias" "rfc1918" {
  name        = "RFC1918"
  type        = "network"
  content     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  description = "All private IPv4 ranges (managed by Terraform)"
}
