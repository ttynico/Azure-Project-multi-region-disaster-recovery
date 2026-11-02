############################################
# Recovery plan: the ordered, one-click failover for the whole workload
#
#   Failover group  -> manual gate: incident commander confirms the declaration
#   Boot group 1    -> app tier
#   Boot group 2    -> web tier, then a manual post-check
#
# Manual actions only fire for Planned/Unplanned failover. Test failover
# (the drill) skips them so it can run unattended from a script or pipeline.
############################################

resource "azurerm_site_recovery_replication_recovery_plan" "dr" {
  name                      = "rp-${var.project}-${var.primary_location}-to-${var.secondary_location}"
  recovery_vault_id         = azurerm_recovery_services_vault.dr.id
  source_recovery_fabric_id = azurerm_site_recovery_fabric.primary.id
  target_recovery_fabric_id = azurerm_site_recovery_fabric.secondary.id

  shutdown_recovery_group {}

  failover_recovery_group {
    pre_action {
      name                      = "Confirm-DR-Declaration"
      type                      = "ManualActionDetails"
      fail_over_directions      = ["PrimaryToRecovery"]
      fail_over_types           = ["PlannedFailover", "UnplannedFailover"]
      manual_action_instruction = "Incident commander confirms the primary-region outage is declared per docs/DR-PLAN.md section 3 and records the decision time (RTO clock start). Then resume the job."
    }
  }

  boot_recovery_group {
    replicated_protected_items = [azurerm_site_recovery_replicated_vm.vm["app"].id]
  }

  boot_recovery_group {
    replicated_protected_items = [azurerm_site_recovery_replicated_vm.vm["web"].id]

    post_action {
      name                      = "Validate-Web-Tier"
      type                      = "ManualActionDetails"
      fail_over_directions      = ["PrimaryToRecovery", "RecoveryToPrimary"]
      fail_over_types           = ["PlannedFailover", "UnplannedFailover"]
      manual_action_instruction = "Browse http://<web DR public IP>/health.json and confirm region equals the recovery region. Update DNS / Traffic Manager if applicable, then resume the job."
    }
  }
}
