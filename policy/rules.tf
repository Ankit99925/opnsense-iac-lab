# Firewall policy. Lower sequence = checked first; the first matching rule wins.
# W1/W2 (host to firewall on 443/22) are in the baseline, so Terraform can always
# reach the API. Destinations meaning "any" leave `net` out: writing net = "any"
# causes permanent plan drift (provider issue #183).

# --- WAN: what the host may reach on the Pi-hole server ---------------------
locals {
  host_to_pihole = {
    ssh = { seq = 100, protocol = "TCP", port = "22", why = "Ansible manages the server" }
    dns = { seq = 101, protocol = "TCP/UDP", port = "53", why = "DNS (smoke tests use dig)" }
    web = { seq = 102, protocol = "TCP", port = "80", why = "Pi-hole admin page" }
  }
}

resource "opnsense_firewall_filter" "host_to_pihole" {
  for_each    = local.host_to_pihole
  sequence    = each.value.seq
  description = "WAN: host to Pi-hole ${each.key}, ${each.value.why}"
  interface   = { interface = ["wan"] }
  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet"
    protocol    = each.value.protocol
    source      = { net = opnsense_firewall_alias.mgmt_host.name }
    destination = { net = opnsense_firewall_alias.pihole.name, port = each.value.port }
  }
}

# --- SERVERS: may reach anything -------------------------------------------
resource "opnsense_firewall_filter" "servers_out" {
  sequence    = 150
  description = "SERVERS: to anywhere (IPv4 and IPv6)"
  interface   = { interface = [local.zones["SERVERS"].key] }
  filter = {
    action      = "pass"
    direction   = "in"
    ip_protocol = "inet46"
    protocol    = "any"
    source      = { net = local.zones["SERVERS"].key }
  }
}

# --- Client zones (CLIENTS, VLANs): one pattern, applied to each -----------
locals {
  client_pattern = [
    { id = "dns-pihole", action = "pass", protocol = "TCP/UDP", dest = opnsense_firewall_alias.pihole.name, port = "53", why = "DNS through Pi-hole" },
    { id = "dns-other", action = "block", protocol = "TCP/UDP", dest = null, port = "53", why = "no plain DNS to anywhere else" },
    { id = "dot", action = "block", protocol = "TCP", dest = null, port = "853", why = "no DNS-over-TLS (Android Private DNS)" },
    { id = "firewall", action = "block", protocol = "any", dest = "(self)", port = null, why = "no reaching the firewall itself" },
    { id = "private", action = "block", protocol = "any", dest = opnsense_firewall_alias.rfc1918.name, port = null, why = "no other private networks, incl. the host" },
    { id = "internet", action = "pass", protocol = "any", dest = null, port = null, why = "internet" },
  ]
  client_names = sort(keys(local.client_zones)) # CLIENTS, VLAN10, VLAN20, VLAN30

  # every client zone x every pattern rule; sequence 200 + 10 per zone + position
  client_rules = {
    for pair in setproduct(local.client_names, range(length(local.client_pattern))) :
    "${pair[0]}-${local.client_pattern[pair[1]].id}" => merge(local.client_pattern[pair[1]], {
      zone = pair[0]
      seq  = 200 + index(local.client_names, pair[0]) * 10 + pair[1]
    })
  }
}

resource "opnsense_firewall_filter" "client" {
  for_each    = local.client_rules
  sequence    = each.value.seq
  description = "${each.value.zone}: ${each.value.why}"
  interface   = { interface = [local.zones[each.value.zone].key] }
  filter = {
    action      = each.value.action
    direction   = "in"
    ip_protocol = "inet"
    protocol    = each.value.protocol
    source      = { net = local.zones[each.value.zone].key }
    destination = { net = each.value.dest, port = each.value.port }
  }
}
