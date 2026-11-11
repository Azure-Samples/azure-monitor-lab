variable "enable_stage_health_model_demo" {
  description = "Deploy the optional Cafe workload and native Cafe/lab flow health models. Requires A/B/C plus E, which owns test-<prefix>-app for the console availability signal."
  type        = bool
  default     = false
}

variable "health_model_demo_cafe_location" {
  description = "Cafe workload region. Preserve the existing standalone workload region when adopting it."
  type        = string
  default     = "swedencentral"
}

variable "health_model_demo_cafe_monitoring_reader_assignment_name" {
  description = "Optional existing Cafe RG Monitoring Reader assignment GUID. Empty grants non-conflicting read access scoped to the Cafe site, storage and workspace."
  type        = string
  default     = ""

  validation {
    condition     = var.health_model_demo_cafe_monitoring_reader_assignment_name == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.health_model_demo_cafe_monitoring_reader_assignment_name))
    error_message = "Use an existing role assignment GUID or an empty string."
  }
}

# Native ARM resources compiled from Bicep, deployed with AzAPI like every other
# stage. No model-building CLI, provisioner, or deployment script is involved.
# Disabling/destroying this AzAPI deployment deletes its history record only.
# Nested workload/models/RBAC remain deployed and potentially billable until
# explicit teardown; AzureRM's delete_nested_items_during_deletion is not involved.
resource "azapi_resource" "stage_health_model_demo" {
  count     = var.enable_stage_health_model_demo ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-health-model-demo"
  parent_id = data.azurerm_resource_group.lab.id

  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b, azapi_resource.stage_c, azapi_resource.stage_e]

  lifecycle {
    precondition {
      condition     = var.enable_stage_a && var.enable_stage_b && var.enable_stage_c && var.enable_stage_e
      error_message = "enable_stage_health_model_demo requires enable_stage_a, enable_stage_b, enable_stage_c and enable_stage_e=true. Stage E owns Microsoft.Insights/webtests/test-<name_prefix>-app, consumed by the flow model's console-availability-failures signal."
    }
  }

  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/../infra/stages/80-health-model-demo.json"))
      parameters = {
        namePrefix                         = { value = var.name_prefix }
        location                           = { value = var.health_model_demo_cafe_location }
        deployLinuxVm                      = { value = var.deploy_linux_vm }
        deployWindowsVm                    = { value = var.deploy_windows_vm }
        cafeMonitoringReaderAssignmentName = { value = var.health_model_demo_cafe_monitoring_reader_assignment_name }
        tags                               = { value = { owner = var.owner_tag, purpose = "azure-monitor-lab", costCenter = "demo" } }
      }
    }
  }

  response_export_values = ["properties.outputs"]
}

output "health_model_demo_cafe_web_app_name" {
  value = var.enable_stage_health_model_demo ? azapi_resource.stage_health_model_demo[0].output.properties.outputs.healthModelDemoCafeWebAppName.value : ""
}

output "health_model_demo_cafe_web_app_url" {
  value = var.enable_stage_health_model_demo ? azapi_resource.stage_health_model_demo[0].output.properties.outputs.healthModelDemoCafeWebAppUrl.value : ""
}

output "health_model_demo_cafe_model_name" {
  value = var.enable_stage_health_model_demo ? azapi_resource.stage_health_model_demo[0].output.properties.outputs.healthModelDemoCafeModelName.value : ""
}

output "health_model_demo_flow_model_name" {
  value = var.enable_stage_health_model_demo ? azapi_resource.stage_health_model_demo[0].output.properties.outputs.healthModelDemoFlowModelName.value : ""
}
