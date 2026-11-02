variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Can also come from ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "project" {
  description = "Short name used as a prefix in resource names."
  type        = string
  default     = "drlab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,10}$", var.project))
    error_message = "project must be 3-11 lowercase letters/digits and start with a letter (it is used in storage account names)."
  }
}

variable "primary_location" {
  description = "Primary (production) Azure region."
  type        = string
  default     = "eastus"
}

variable "secondary_location" {
  description = "Recovery (DR) Azure region. Must be a supported Azure-to-Azure ASR target for the primary region."
  type        = string
  default     = "westus2"
}

variable "vm_size" {
  description = "Size for the protected VMs. B-series keeps the lab cheap; ASR supports it."
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = "Admin username for the Linux VMs."
  type        = string
  default     = "azureadmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key (contents, not path) for the Linux VMs. Password auth is disabled."
  type        = string
}

variable "allowed_source_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.10/32). Only this CIDR can reach SSH/HTTP. Never use 0.0.0.0/0."
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_source_cidr, 0)) && var.allowed_source_cidr != "0.0.0.0/0"
    error_message = "allowed_source_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "recovery_point_retention_minutes" {
  description = "How long ASR keeps crash-consistent recovery points (minutes). 1440 = 24h."
  type        = number
  default     = 1440
}

variable "app_consistent_frequency_minutes" {
  description = "How often ASR takes app-consistent snapshots (minutes). Must be <= retention."
  type        = number
  default     = 240
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
