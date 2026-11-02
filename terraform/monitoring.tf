############################################
# Observability: ASR logs to Log Analytics in the DR region
# (so you can still query replication history if the primary region is down)
############################################

resource "azurerm_log_analytics_workspace" "dr" {
  name                = "log-${var.project}-dr-${local.suffix}"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "vault" {
  name                           = "diag-${azurerm_recovery_services_vault.dr.name}"
  target_resource_id             = azurerm_recovery_services_vault.dr.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.dr.id
  log_analytics_destination_type = "Dedicated"

  # Includes AzureSiteRecoveryJobs, ...ReplicatedItems, ...RecoveryPoints,
  # ...ReplicationStats, ...ProtectedDiskDataChurn, etc.
  enabled_log {
    category_group = "allLogs"
  }
}
