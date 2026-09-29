# Kea DHCP: one subnet per zone, from network.json. Kea itself (on/off and
# which interfaces it listens on) is switched on by the baseline.

resource "opnsense_kea_dhcpv4_subnet" "zone" {
  for_each     = local.zones
  subnet       = each.value.subnet
  pools        = [each.value.pool]
  routers      = [each.value.gateway]
  dns_servers  = [local.net.pihole]
  auto_collect = false # use exactly these values, not ones guessed from the interface
  description  = "${each.key} (managed by Terraform)"
  # No ntp_servers: client zones may not reach the firewall, so they use internet time.
}
