############################################
# Vault managed identity -> ASR cache storage account
#
# Because the vault has a system-assigned identity, ASR uses that identity
# (not a hidden service key) to write to the cache storage account. Without
# these roles, enable replication fails with error 28143:
#   "Recovery Services vault does not have permission to access storage account"
############################################

resource "azurerm_role_assignment" "vault_cache_contributor" {
  scope                = azurerm_storage_account.asr_cache.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_recovery_services_vault.dr.identity[0].principal_id
}

resource "azurerm_role_assignment" "vault_cache_blob_data" {
  scope                = azurerm_storage_account.asr_cache.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_recovery_services_vault.dr.identity[0].principal_id
}

# Entra ID role assignments take a minute or two to propagate.
resource "time_sleep" "rbac_propagation" {
  create_duration = "120s"

  depends_on = [
    azurerm_role_assignment.vault_cache_contributor,
    azurerm_role_assignment.vault_cache_blob_data,
  ]
}
