# Resource group: external (BYO). The user (or a wrapper script / pipeline) is
# responsible for creating the RG before running terraform apply. Terraform
# only LOOKS IT UP via data source so it can hand each stage a parent_id.
# Benefit: `terraform destroy` removes only the resources inside the RG, leaving
# the RG (and anything else the user put in it) intact. This matches the BYO-RG
# intent and avoids count-flipping / state-ownership issues of create-if-missing.
#
# Create the RG first (idempotent):
#   az group create -n <resource_group_name> -l <location>
data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

check "slot_failure_requires_workloads" {
  assert {
    condition     = !var.enable_slot_failure_scenario || var.enable_stage_b
    error_message = "enable_slot_failure_scenario requires enable_stage_b=true."
  }
}

resource "azapi_resource" "stage_a" {
  count     = var.enable_stage_a ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-a-foundation"
  parent_id = data.azurerm_resource_group.lab.id

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/00-foundation.json")))
      parameters = {
        location               = { value = var.location }
        namePrefix             = { value = var.name_prefix }
        dailyCapGb             = { value = var.daily_cap_gb }
        ownerTag               = { value = var.owner_tag }
        enableLawReplication   = { value = var.enable_law_replication }
        lawReplicationLocation = { value = var.law_replication_location }
      }
    }
  }
}

resource "azapi_resource" "stage_b" {
  count     = var.enable_stage_b ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-b-workloads"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage B references Stage A's LAW via 'existing' — wait for A to finish.
  depends_on = [azapi_resource.stage_a]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/10-workloads.json")))
      parameters = {
        location                  = { value = var.location }
        namePrefix                = { value = var.name_prefix }
        vmAdminUsername           = { value = var.vm_admin_username }
        vmAdminPassword           = { value = var.vm_admin_password }
        deployWindowsVm           = { value = var.deploy_windows_vm }
        deployLinuxVm             = { value = var.deploy_linux_vm }
        enableVmOtelMetrics       = { value = var.enable_vm_otel_metrics }
        vmSize                    = { value = var.vm_size }
        aksNodeVmSize             = { value = var.aks_node_vm_size }
        aksNodeCount              = { value = var.aks_node_count }
        grafanaAdminObjectId      = { value = var.grafana_admin_object_id }
        enableSlotFailureScenario = { value = var.enable_slot_failure_scenario }
        ownerTag                  = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_c" {
  count     = var.enable_stage_c ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-c-alerting"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage C targets Stage B's VMs and Stage A's LAW — wait for both.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/20-alerting.json")))
      parameters = {
        location        = { value = var.location }
        namePrefix      = { value = var.name_prefix }
        alertEmail      = { value = var.alert_email }
        siemWebhookUrl  = { value = var.siem_webhook_url }
        vmAdminUsername = { value = var.vm_admin_username }
        vmAdminPassword = { value = var.vm_admin_password }
        deployWindowsVm = { value = var.deploy_windows_vm }
        deployLinuxVm   = { value = var.deploy_linux_vm }
        ownerTag        = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_d" {
  count     = var.enable_stage_d ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-d-security-posture"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage D references Stage A's LAW via 'existing' AND Stage C's Action Group
  # ('ag-${namePrefix}-email') as an alert target. Without depending on C, an
  # all-at-once apply races C and D in parallel and Azure rejects the alerts
  # with `BadRequest: Action Group ... is invalid`.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_c]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/30-security-posture.json")))
      parameters = {
        location   = { value = var.location }
        namePrefix = { value = var.name_prefix }
        ownerTag   = { value = var.owner_tag }
      }
    }
  }
}

resource "azapi_resource" "stage_e" {
  count     = var.enable_stage_e ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-e-optional-advanced"
  parent_id = data.azurerm_resource_group.lab.id

  # Stage E targets Stage A's LAW and Stage B's webapp/AKS, AND Stage C's
  # Action Group ('ag-${namePrefix}-email') as an alert target. Without depending
  # on C, an all-at-once apply races C and E in parallel and Azure rejects the
  # alerts with `BadRequest: Action Group ... is invalid`.
  # Also depends on the AI stage so the workload health model can fold in the AI tier.
  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b, azapi_resource.stage_c, azapi_resource.stage_ai]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/40-optional-advanced.json")))
      parameters = {
        location               = { value = var.location }
        namePrefix             = { value = var.name_prefix }
        enableSentinel         = { value = var.enable_sentinel }
        deployWindowsVm        = { value = var.deploy_windows_vm }
        deployLinuxVm          = { value = var.deploy_linux_vm }
        ownerTag               = { value = var.owner_tag }
        enablePlatformLogsDcr  = { value = var.enable_platform_logs_dcr }
        enableMetricsExportDcr = { value = var.enable_metrics_export_dcr }
        enableAi               = { value = var.enable_stage_ai }
      }
    }
  }
}

resource "azapi_resource" "stage_sentinel_content" {
  count     = var.enable_stage_e && var.enable_sentinel ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-e-sentinel-content"
  parent_id = data.azurerm_resource_group.lab.id

  depends_on = [azapi_resource.stage_e]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/41-sentinel-content.json")))
      parameters = {
        namePrefix = { value = var.name_prefix }
      }
    }
  }
}

# Optional AI stage: Microsoft Foundry workload (account, project, chat/embed/optimize/
# model-router deployments) + App Insights connection + token metric alerts. Pinned to
# swedencentral (var.ai_location). References Stage A's App Insights ('appi-<prefix>'),
# so it depends only on Stage A. Agents + traffic are provisioned by scripts/setup-ai.ps1.
resource "azapi_resource" "stage_ai" {
  count     = var.enable_stage_ai ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-ai-foundry"
  parent_id = data.azurerm_resource_group.lab.id

  depends_on = [azapi_resource.stage_a]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/50-ai.json")))
      parameters = {
        namePrefix         = { value = var.name_prefix }
        aiLocation         = { value = var.ai_location }
        alertEmail         = { value = var.alert_email }
        ownerTag           = { value = var.owner_tag }
        routerModelVersion = { value = var.router_model_version }
      }
    }
  }
}

# Optional SRE Agent stage: Azure SRE Agent, managed identities, Azure Monitor,
# Application Insights and Log Analytics connectors, and required RBAC. The shared
# Bicep module hard pins the agent to swedencentral. It references Stage A resources.
resource "azapi_resource" "stage_sre_agent" {
  count     = var.enable_stage_sre_agent ? 1 : 0
  type      = "Microsoft.Resources/deployments@2022-09-01"
  name      = "stage-sre-agent"
  parent_id = data.azurerm_resource_group.lab.id

  depends_on = [azapi_resource.stage_a, azapi_resource.stage_b]

  body = {
    properties = {
      mode     = "Incremental"
      template = sensitive(jsondecode(file("${path.module}/../infra/stages/60-sre-agent.json")))
      parameters = {
        namePrefix                = { value = var.name_prefix }
        ownerTag                  = { value = var.owner_tag }
        enableSlotFailureScenario = { value = var.enable_slot_failure_scenario }
      }
    }
  }
}
