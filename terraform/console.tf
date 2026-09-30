variable "console_operator_object_ids" {
  description = "Approved console users for noninteractive deployment. Empty uses existing console operators or the signed-in Azure CLI user."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.console_operator_object_ids) <= 10 && alltrue([for value in var.console_operator_object_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", value)) && value != "00000000-0000-0000-0000-000000000000"])
    error_message = "Specify at most ten nonempty Microsoft Entra user object IDs."
  }
}

locals {
  console_sources = sort(distinct(concat(
    tolist(fileset("${path.module}/..", "workloads/webapp/*.cs")),
    tolist(fileset("${path.module}/..", "workloads/webapp/wwwroot/**")),
    tolist(fileset("${path.module}/..", "workloads/operations/*")),
    tolist(fileset("${path.module}/..", "workloads/ai/*.py")),
    [
      "workloads/webapp/AmlabHello.csproj",
      "workloads/ai/requirements.txt",
      "workloads/k8s/02-loadgen.yaml",
      "workloads/k8s/03-loadgen-ramp.yaml",
      "scripts/post-staged-deploy.ps1",
      "scripts/setup-activity-log.ps1",
      "scripts/setup-health-model.ps1",
      "scripts/setup-slis.ps1",
      "scripts/resolve-service-group-id.ps1",
      "scripts/post-deploy.ps1",
      "scripts/prepare-webapp-package.ps1",
      "scripts/wait-webapp-publication.ps1",
      "scripts/write-webapp-console-config.ps1",
      "scripts/initialize-webapp-console.ps1",
      "scripts/setup-webapp-agent-access.ps1",
      "scripts/setup-ai.ps1",
      "scripts/setup-sre-agent.ps1",
      "scripts/install-sre-mcp.ps1",
      "scripts/invoke-lab-operation.ps1",
      "scripts/start-the-lab.ps1",
      "scripts/break-the-lab.ps1",
      "scripts/restore-the-lab.ps1",
      "scripts/start-ramp.ps1",
      "scripts/simulate-high-cpu.ps1",
      "scripts/send-custom-logs.ps1",
      "scripts/send-release-annotation.ps1",
      "infra/modules/lab-console-platform.json",
      "infra/modules/lab-console-job.json",
      "infra/modules/custom-logs.json",
      "infra/stages/10-workloads.json",
      "infra/stages/50-ai.json",
      "infra/stages/60-sre-agent.json"
    ]
  )))
}

resource "terraform_data" "console_ready" {
  count = var.enable_stage_b ? 1 : 0

  triggers_replace = {
    resource_group = data.azurerm_resource_group.lab.id
    prefix         = var.name_prefix
    sources        = sha256(join("", [for name in local.console_sources : filesha256("${path.module}/../${name}")]))
    integrations   = jsonencode({ ai = var.enable_stage_ai, sre = var.enable_stage_sre_agent, stage_e = var.enable_stage_e, ai_location = var.ai_location, router_model_version = var.router_model_version })
    operators      = jsonencode(var.console_operator_object_ids)
  }

  depends_on = [azapi_resource.stage_b, azapi_resource.stage_c, azapi_resource.stage_d, azapi_resource.stage_e, azapi_resource.stage_sentinel_content, azapi_resource.stage_ai, azapi_resource.stage_sre_agent]

  lifecycle {
    replace_triggered_by = [azapi_resource.stage_b]
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& (Join-Path $env:LAB_REPOSITORY_ROOT 'scripts/post-staged-deploy.ps1') -SubscriptionId $env:LAB_SUBSCRIPTION_ID -ResourceGroup $env:LAB_RESOURCE_GROUP -NamePrefix $env:LAB_NAME_PREFIX -ConsoleOperatorObjectIds @($env:LAB_OPERATOR_IDS | ConvertFrom-Json) -EnableStageE ([bool]::Parse($env:LAB_ENABLE_STAGE_E)) -EnableStageSreAgent ([bool]::Parse($env:LAB_ENABLE_STAGE_SRE_AGENT))"
    environment = {
      LAB_REPOSITORY_ROOT        = abspath("${path.module}/..")
      LAB_SUBSCRIPTION_ID        = var.subscription_id
      LAB_RESOURCE_GROUP         = var.resource_group_name
      LAB_NAME_PREFIX            = var.name_prefix
      LAB_OPERATOR_IDS           = jsonencode(var.console_operator_object_ids)
      LAB_ENABLE_STAGE_E         = tostring(var.enable_stage_e)
      LAB_ENABLE_STAGE_SRE_AGENT = tostring(var.enable_stage_sre_agent)
    }
  }
}

resource "terraform_data" "sre_ready" {
  count = var.enable_stage_sre_agent && !var.enable_stage_b ? 1 : 0

  triggers_replace = {
    resource_group = data.azurerm_resource_group.lab.id
    validator      = filesha256("${path.module}/../scripts/setup-sre-agent.ps1")
    template       = filesha256("${path.module}/../infra/stages/60-sre-agent.json")
  }

  depends_on = [azapi_resource.stage_sre_agent]

  lifecycle {
    replace_triggered_by = [azapi_resource.stage_sre_agent]
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-Command"]
    command     = "& (Join-Path $env:LAB_REPOSITORY_ROOT 'scripts/setup-sre-agent.ps1') -SubscriptionId $env:LAB_SUBSCRIPTION_ID -ResourceGroup $env:LAB_RESOURCE_GROUP"
    environment = {
      LAB_REPOSITORY_ROOT = abspath("${path.module}/..")
      LAB_SUBSCRIPTION_ID = var.subscription_id
      LAB_RESOURCE_GROUP  = var.resource_group_name
    }
  }
}