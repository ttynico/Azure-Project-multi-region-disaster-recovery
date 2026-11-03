terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Uncomment to keep state in Azure Storage (recommended once you move past a solo lab).
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "<your-state-account>"
  #   container_name       = "tfstate"
  #   key                  = "azure-multi-region-dr.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  features {
    resource_group {
      # ASR creates resources (replica disks, failed-over VMs, NICs) that Terraform
      # does not track. Without this, `terraform destroy` refuses to delete the DR
      # resource group after a drill. Teardown is intentional for this lab.
      prevent_deletion_if_contains_resources = false
    }

    recovery_service {
      vm_backup_stop_protection_and_retain_data_on_destroy = false
      purge_protected_items_from_vault_on_destroy          = true
    }
  }

  subscription_id = var.subscription_id
}
