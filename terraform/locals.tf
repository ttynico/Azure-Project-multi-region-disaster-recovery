resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Two tiers so the recovery plan can demonstrate ordered boot groups:
  #   group 1 = app tier (dependencies come up first)
  #   group 2 = web tier (front end comes up once the app tier is running)
  vms = {
    app = { name = "vm-app-01", tier = "app", private_ip = "10.10.1.10", dr_ip = "10.20.1.10", test_ip = "10.30.1.10" }
    web = { name = "vm-web-01", tier = "web", private_ip = "10.10.1.20", dr_ip = "10.20.1.20", test_ip = "10.30.1.20" }
  }

  # Distinct, non-overlapping address spaces so the DR and test VNets could be
  # peered to a hub later without re-IPing. Static IPs are preserved per VM.
  primary_vnet_cidr = "10.10.0.0/16"
  primary_subnet    = "10.10.1.0/24"
  dr_vnet_cidr      = "10.20.0.0/16"
  dr_subnet         = "10.20.1.0/24"
  test_vnet_cidr    = "10.30.0.0/16"
  test_subnet       = "10.30.1.0/24"

  tags = merge({
    project     = "azure-multi-region-disaster-recovery"
    managed_by  = "terraform"
    environment = "lab"
    owner       = "ttynico"
  }, var.tags)
}
