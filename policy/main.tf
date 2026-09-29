# OPNsense policy: aliases, firewall rules and Kea subnets, pushed through the API.
# A separate stack from ../terraform because it can only plan once OPNsense runs.
# Credentials come from the environment: OPNSENSE_API_KEY and OPNSENSE_API_SECRET,
# the automation user's key (~/.config/opnsense-iac-lab/api.env).

terraform {
  required_providers {
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.26"
    }
  }
}

variable "opnsense_uri" {
  description = "OPNsense API address (its WAN, reached from the host)"
  default     = "https://192.168.122.69"
}

provider "opnsense" {
  uri            = var.opnsense_uri
  allow_insecure = true # self-signed certificate on a lab firewall
}

locals {
  # The network's shape, shared with scripts/render-baseline.py
  net = jsondecode(file("${path.module}/../network.json"))

  zones        = { for z in local.net.zones : z.name => z } # e.g. zones["VLAN10"].key = "opt3"
  client_zones = { for n, z in local.zones : n => z if z.policy == "client" }
}
