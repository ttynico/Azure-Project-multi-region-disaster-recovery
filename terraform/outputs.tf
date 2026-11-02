output "primary_resource_group" {
  value = azurerm_resource_group.primary.name
}

output "dr_resource_group" {
  value = azurerm_resource_group.secondary.name
}

output "recovery_vault_name" {
  value = azurerm_recovery_services_vault.dr.name
}

output "recovery_plan_name" {
  value = azurerm_site_recovery_replication_recovery_plan.dr.name
}

output "test_network_id" {
  description = "Isolated VNet used for test failovers (passed to the drill script)."
  value       = azurerm_virtual_network.test.id
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.dr.workspace_id
}

output "endpoints" {
  description = "Health endpoints per VM in each environment."
  value       = {
    for k, v in local.vms : k => {
      primary = "http://${azurerm_public_ip.primary[k].ip_address}/health.json"
      dr      = "http://${azurerm_public_ip.secondary[k].ip_address}/health.json"
      drtest  = "http://${azurerm_public_ip.test[k].ip_address}/health.json"
    }
  }
}

output "drill_command" {
  description = "Copy/paste to run a DR drill (test failover + RTO measurement + cleanup)."
  value       = "pwsh ../scripts/Start-DrDrill.ps1 -ResourceGroupName ${azurerm_resource_group.secondary.name} -VaultName ${azurerm_recovery_services_vault.dr.name} -RecoveryPlanName ${azurerm_site_recovery_replication_recovery_plan.dr.name} -TestNetworkId ${azurerm_virtual_network.test.id} -HealthUrl http://${azurerm_public_ip.test["web"].ip_address}/health.json -ExpectedRegion ${var.secondary_location}"
}
