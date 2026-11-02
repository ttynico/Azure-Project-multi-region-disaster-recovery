############################################
# Resource groups
############################################

resource "azurerm_resource_group" "primary" {
  name     = "rg-${var.project}-primary-${var.primary_location}"
  location = var.primary_location
  tags     = local.tags
}

# Holds the vault, the DR network, and every resource ASR creates on failover.
# It lives in the recovery region so it survives a primary-region outage.
resource "azurerm_resource_group" "secondary" {
  name     = "rg-${var.project}-dr-${var.secondary_location}"
  location = var.secondary_location
  tags     = local.tags
}

############################################
# Shared NSG rules (applied per region at the subnet level)
############################################

locals {
  nsg_rules = [
    { name = "Allow-SSH-From-Admin", priority = 100, port = "22" },
    { name = "Allow-HTTP-From-Admin", priority = 110, port = "80" },
  ]
}

############################################
# Primary region network
############################################

resource "azurerm_virtual_network" "primary" {
  name                = "vnet-${var.project}-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  address_space       = [local.primary_vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "primary" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = [local.primary_subnet]
}

resource "azurerm_network_security_group" "primary" {
  name                = "nsg-${var.project}-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  tags                = local.tags

  dynamic "security_rule" {
    for_each = local.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = var.allowed_source_cidr
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "primary" {
  subnet_id                 = azurerm_subnet.primary.id
  network_security_group_id = azurerm_network_security_group.primary.id
}

############################################
# Recovery region network (real failover target)
############################################

resource "azurerm_virtual_network" "secondary" {
  name                = "vnet-${var.project}-dr"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  address_space       = [local.dr_vnet_cidr]
  tags                = local.tags
}

# Same subnet name as primary: ASR maps NICs by subnet name across the network mapping.
resource "azurerm_subnet" "secondary" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.secondary.name
  virtual_network_name = azurerm_virtual_network.secondary.name
  address_prefixes     = [local.dr_subnet]
}

resource "azurerm_network_security_group" "secondary" {
  name                = "nsg-${var.project}-dr"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  tags                = local.tags

  dynamic "security_rule" {
    for_each = local.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = var.allowed_source_cidr
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "secondary" {
  subnet_id                 = azurerm_subnet.secondary.id
  network_security_group_id = azurerm_network_security_group.secondary.id
}

############################################
# Isolated test-failover network (no peering, no route to prod)
# DR drills land here so they never collide with production.
############################################

resource "azurerm_virtual_network" "test" {
  name                = "vnet-${var.project}-drtest"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  address_space       = [local.test_vnet_cidr]
  tags                = merge(local.tags, { purpose = "asr-test-failover" })
}

resource "azurerm_subnet" "test" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.secondary.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = [local.test_subnet]
}

resource "azurerm_subnet_network_security_group_association" "test" {
  subnet_id                 = azurerm_subnet.test.id
  network_security_group_id = azurerm_network_security_group.secondary.id
}

############################################
# Public IPs
# Standard SKU is closed by default; NSGs above open 22/80 to your CIDR only.
############################################

resource "azurerm_public_ip" "primary" {
  for_each            = local.vms
  name                = "pip-${each.value.name}-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# Pre-created in the DR region and attached by ASR at failover time.
# Pre-staging them removes a manual step from the recovery path.
resource "azurerm_public_ip" "secondary" {
  for_each            = local.vms
  name                = "pip-${each.value.name}-dr"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_public_ip" "test" {
  for_each            = local.vms
  name                = "pip-${each.value.name}-drtest"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.tags, { purpose = "asr-test-failover" })
}
