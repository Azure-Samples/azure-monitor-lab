variable "subscription_id" { type = string }

variable "resource_group_name" {
  type        = string
  default     = "rg-azure-monitor-lab"
  description = "Name of the resource group hosting the lab. The RG MUST already exist in the subscription before running terraform apply (Terraform only looks it up via data source, it does not create or destroy the RG). Create it with: az group create -n <name> -l <location>."
}

variable "location" { type = string }
variable "alert_email" { type = string }
variable "vm_admin_password" {
  type      = string
  sensitive = true
}

variable "name_prefix" {
  type    = string
  default = "amlab"
}

variable "owner_tag" {
  type    = string
  default = "demo-lab"
}

variable "daily_cap_gb" {
  type    = number
  default = 1
}

variable "enable_law_replication" {
  type    = bool
  default = false
}

variable "law_replication_location" {
  type    = string
  default = ""
}

variable "vm_admin_username" {
  type    = string
  default = "azureuser"
}

variable "deploy_windows_vm" {
  type    = bool
  default = true
}

variable "deploy_linux_vm" {
  type    = bool
  default = true
}

variable "enable_vm_otel_metrics" {
  type        = bool
  default     = true
  nullable    = false
  description = "Add OpenTelemetry system metrics to standalone VMs in Stage B, using the existing Azure Monitor workspace. Classic VM Insights remains enabled; VMSS is unchanged. Setting false after deployment does not remove existing DCR associations."
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "aks_node_vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "aks_node_count" {
  type    = number
  default = 1
}

variable "grafana_admin_object_id" {
  type        = string
  default     = ""
  nullable    = false
  description = "Microsoft Entra object ID of the Grafana lab operator or group. Empty grants Grafana Admin to the ARM deployment identity; set explicitly for CI deployments."

  validation {
    condition = var.grafana_admin_object_id == "" || (
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.grafana_admin_object_id)) &&
      var.grafana_admin_object_id != "00000000-0000-0000-0000-000000000000"
    )
    error_message = "Use an empty value or a nonzero Microsoft Entra user or group object ID in GUID format."
  }
}

variable "siem_webhook_url" {
  type      = string
  default   = ""
  sensitive = true
}

variable "enable_sentinel" {
  type    = bool
  default = true
}

variable "enable_platform_logs_dcr" {
  type    = bool
  default = false
}

variable "enable_metrics_export_dcr" {
  type    = bool
  default = false
}

variable "enable_stage_a" { type = bool }
variable "enable_stage_b" { type = bool }
variable "enable_stage_c" { type = bool }
variable "enable_stage_d" { type = bool }
variable "enable_stage_e" { type = bool }

variable "enable_stage_ai" {
  type    = bool
  default = false
}

variable "enable_stage_sre_agent" {
  type        = bool
  default     = false
  description = "Deploy the optional preview Azure SRE Agent stage. The agent is hard pinned to swedencentral and can incur billable usage."
}

variable "enable_slot_failure_scenario" {
  type        = bool
  default     = false
  description = "Provision an S1 App Service plan and a preloaded broken slot for the opt-in SRE rollback scenario."
}

variable "ai_location" {
  type        = string
  default     = "swedencentral"
  description = "Region for the optional AI stage's Foundry account + models. Pinned to swedencentral (gpt-5-* / model-router SKUs + Foundry portal features are region-limited), independent of var.location."
}

variable "router_model_version" {
  type        = string
  default     = "2025-08-07"
  description = "Model Router deployment version for the AI stage. VERIFY for your region with 'az cognitiveservices account list-models' before enabling the stage."
}
