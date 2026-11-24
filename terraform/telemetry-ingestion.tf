# Optional ARM stage compiled from infra/stages/90-telemetry-ingestion.bicep.
# Disabling this deployment does not delete retained data or nested ARM resources.
variable "enable_stage_telemetry_ingestion" {
  type        = bool
  default     = false
  nullable    = false
  description = "Deploy isolated JSON ingestion resources after Stage A. No events are sent by deployment."
}

variable "enable_telemetry_ingestion_auxiliary" {
  type        = bool
  default     = false
  nullable    = false
  description = "Add separate Auxiliary table and tiered DCR; requires enable_stage_telemetry_ingestion."
}

variable "enable_telemetry_ingestion_native_otlp" {
  type        = bool
  default     = false
  nullable    = false
  description = "Experimental direct OTLP logs DCR. Requires Stage A, Stage B, Linux VM and telemetry ingestion; no Collector is installed."
}

resource "terraform_data" "native_otlp_prerequisites" {
  count = var.enable_telemetry_ingestion_native_otlp ? 1 : 0
  lifecycle {
    precondition {
      condition     = var.enable_stage_telemetry_ingestion && var.enable_stage_a && var.enable_stage_b && var.deploy_linux_vm
      error_message = "Native OTLP requires telemetry ingestion, Stage A, Stage B and deploy_linux_vm=true for a separately installed Collector (Azure Monitor pipeline not required)."
    }
  }
}

variable "telemetry_ingestion_sender_principal_id" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional managed identity/service principal object ID assigned Monitoring Metrics Publisher only on scenario DCRs."
  validation {
    condition     = var.telemetry_ingestion_sender_principal_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.telemetry_ingestion_sender_principal_id))
    error_message = "Use an empty string or a service principal object ID in GUID format."
  }
}

resource "azapi_resource" "stage_telemetry_ingestion" {
  count     = var.enable_stage_telemetry_ingestion ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-telemetry-ingestion"
  parent_id = data.azurerm_resource_group.lab.id

  depends_on = [azapi_resource.stage_a, terraform_data.native_otlp_prerequisites]

  lifecycle {
    precondition {
      condition     = var.enable_stage_a
      error_message = "Telemetry ingestion requires Stage A's central Log Analytics workspace in the same region."
    }
    precondition {
      condition     = !var.enable_telemetry_ingestion_auxiliary || var.enable_stage_telemetry_ingestion
      error_message = "Auxiliary routing requires enable_stage_telemetry_ingestion=true."
    }
  }

  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/../infra/stages/90-telemetry-ingestion.json"))
      parameters = {
        namePrefix        = { value = var.name_prefix }
        location          = { value = var.location }
        enableAuxiliary   = { value = var.enable_telemetry_ingestion_auxiliary }
        enableNativeOtlp  = { value = var.enable_telemetry_ingestion_native_otlp }
        senderPrincipalId = { value = var.telemetry_ingestion_sender_principal_id }
        tags              = { value = { owner = var.owner_tag, purpose = "azure-monitor-lab", costCenter = "demo" } }
      }
    }
  }

  response_export_values = ["properties.outputs"]
}

output "telemetry_ingestion_outputs" {
  description = "Exact DCE URL, DCR immutable IDs and destination tables. Empty when disabled."
  value       = var.enable_stage_telemetry_ingestion ? azapi_resource.stage_telemetry_ingestion[0].output.properties.outputs : {}
}
