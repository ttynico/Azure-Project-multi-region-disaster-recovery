############################################
# Recovery Services vault (lives in the DR region)
############################################

resource "azurerm_recovery_services_vault" "dr" {
  name                = "rsv-${var.project}-dr-${local.suffix}"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  sku                 = "Standard"
  storage_mode_type   = "GeoRedundant"
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }

  # Built-in Azure Monitor alerts for replication health and failover problems.
  monitoring {
    alerts_for_all_job_failures_enabled            = true
    alerts_for_all_replication_issues_enabled      = true
    alerts_for_all_failover_issues_enabled         = true
    alerts_for_critical_operation_failures_enabled = true
  }
}

############################################
# Cache storage account (must be in the SOURCE region)
# ASR writes disk changes here first, then ships them to the replica disks
# in the recovery region.
############################################

resource "azurerm_storage_account" "asr_cache" {
  name                            = "st${var.project}cache${local.suffix}"
  location                        = azurerm_resource_group.primary.location
  resource_group_name             = azurerm_resource_group.primary.name
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.tags, { purpose = "asr-cache" })
}

############################################
# Fabrics: one per Azure region in the replication relationship
############################################

resource "azurerm_site_recovery_fabric" "primary" {
  name                = "fabric-${var.primary_location}"
  resource_group_name = azurerm_resource_group.secondary.name
  recovery_vault_name = azurerm_recovery_services_vault.dr.name
  location            = azurerm_resource_group.primary.location
}

resource "azurerm_site_recovery_fabric" "secondary" {
  name                = "fabric-${var.secondary_location}"
  resource_group_name = azurerm_resource_group.secondary.name
  recovery_vault_name = azurerm_recovery_services_vault.dr.name
  location            = azurerm_resource_group.secondary.location
}

############################################
# Protection containers
############################################

resource "azurerm_site_recovery_protection_container" "primary" {
  name                 = "pc-${var.primary_location}"
  resource_group_name  = azurerm_resource_group.secondary.name
  recovery_vault_name  = azurerm_recovery_services_vault.dr.name
  recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
}

resource "azurerm_site_recovery_protection_container" "secondary" {
  name                 = "pc-${var.secondary_location}"
  resource_group_name  = azurerm_resource_group.secondary.name
  recovery_vault_name  = azurerm_recovery_services_vault.dr.name
  recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
}

############################################
# Replication policy: defines the RPO envelope
############################################

resource "azurerm_site_recovery_replication_policy" "dr" {
  name                                                 = "policy-${var.project}-24h"
  resource_group_name                                  = azurerm_resource_group.secondary.name
  recovery_vault_name                                  = azurerm_recovery_services_vault.dr.name
  recovery_point_retention_in_minutes                  = var.recovery_point_retention_minutes
  application_consistent_snapshot_frequency_in_minutes = var.app_consistent_frequency_minutes
}

############################################
# Container mappings
# Forward (primary -> DR) is used now. Reverse (DR -> primary) is pre-created
# so re-protect after a real failover doesn't require building it under pressure.
############################################

resource "azurerm_site_recovery_protection_container_mapping" "forward" {
  name                                      = "map-${var.primary_location}-to-${var.secondary_location}"
  resource_group_name                       = azurerm_resource_group.secondary.name
  recovery_vault_name                       = azurerm_recovery_services_vault.dr.name
  recovery_fabric_name                      = azurerm_site_recovery_fabric.primary.name
  recovery_source_protection_container_name = azurerm_site_recovery_protection_container.primary.name
  recovery_target_protection_container_id   = azurerm_site_recovery_protection_container.secondary.id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.dr.id
}

resource "azurerm_site_recovery_protection_container_mapping" "reverse" {
  name                                      = "map-${var.secondary_location}-to-${var.primary_location}"
  resource_group_name                       = azurerm_resource_group.secondary.name
  recovery_vault_name                       = azurerm_recovery_services_vault.dr.name
  recovery_fabric_name                      = azurerm_site_recovery_fabric.secondary.name
  recovery_source_protection_container_name = azurerm_site_recovery_protection_container.secondary.name
  recovery_target_protection_container_id   = azurerm_site_recovery_protection_container.primary.id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.dr.id
}

############################################
# Network mappings (both directions, for the same reason)
############################################

resource "azurerm_site_recovery_network_mapping" "forward" {
  name                        = "netmap-${var.primary_location}-to-${var.secondary_location}"
  resource_group_name         = azurerm_resource_group.secondary.name
  recovery_vault_name         = azurerm_recovery_services_vault.dr.name
  source_recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  target_recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
  source_network_id           = azurerm_virtual_network.primary.id
  target_network_id           = azurerm_virtual_network.secondary.id
}

resource "azurerm_site_recovery_network_mapping" "reverse" {
  name                        = "netmap-${var.secondary_location}-to-${var.primary_location}"
  resource_group_name         = azurerm_resource_group.secondary.name
  recovery_vault_name         = azurerm_recovery_services_vault.dr.name
  source_recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
  target_recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  source_network_id           = azurerm_virtual_network.secondary.id
  target_network_id           = azurerm_virtual_network.primary.id
}

############################################
# Replicated VMs (this is "enable replication")
# First sync (initial replication) typically takes 30-60+ minutes per VM.
############################################

resource "azurerm_site_recovery_replicated_vm" "vm" {
  for_each = local.vms

  name                                      = "repl-${each.value.name}"
  resource_group_name                       = azurerm_resource_group.secondary.name
  recovery_vault_name                       = azurerm_recovery_services_vault.dr.name
  source_recovery_fabric_name               = azurerm_site_recovery_fabric.primary.name
  source_vm_id                              = azurerm_linux_virtual_machine.vm[each.key].id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.dr.id
  source_recovery_protection_container_name = azurerm_site_recovery_protection_container.primary.name

  target_resource_group_id                = azurerm_resource_group.secondary.id
  target_recovery_fabric_id               = azurerm_site_recovery_fabric.secondary.id
  target_recovery_protection_container_id = azurerm_site_recovery_protection_container.secondary.id
  target_network_id                       = azurerm_virtual_network.secondary.id
  test_network_id                         = azurerm_virtual_network.test.id
  target_virtual_machine_size             = var.vm_size

  # Both VMs share crash- and app-consistent recovery points, so the app and
  # web tiers fail over to the same point in time.
  multi_vm_group_name = "mvg-${var.project}"

  managed_disk {
    disk_id                    = azurerm_linux_virtual_machine.vm[each.key].os_disk[0].id
    staging_storage_account_id = azurerm_storage_account.asr_cache.id
    target_resource_group_id   = azurerm_resource_group.secondary.id
    target_disk_type           = "StandardSSD_LRS"
    target_replica_disk_type   = "Standard_LRS"
  }

  network_interface {
    source_network_interface_id = azurerm_network_interface.vm[each.key].id

    ip_configuration {
      name                               = "ipconfig1"
      target_subnet_name                 = azurerm_subnet.secondary.name
      target_static_ip                   = each.value.dr_ip
      recovery_public_ip_address_id      = azurerm_public_ip.secondary[each.key].id
      failover_test_subnet_name          = azurerm_subnet.test.name
      failover_test_static_ip            = each.value.test_ip
      failover_test_public_ip_address_id = azurerm_public_ip.test[each.key].id
    }
  }

  timeouts {
    create = "3h"
  }

  depends_on = [
    azurerm_site_recovery_protection_container_mapping.forward,
    azurerm_site_recovery_network_mapping.forward,
  ]
}
