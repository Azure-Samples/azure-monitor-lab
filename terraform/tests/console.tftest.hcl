mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
      name     = "test-rg"
      location = "northeurope"
    }
  }
}

mock_provider "azapi" {}

variables {
  subscription_id        = "00000000-0000-0000-0000-000000000000"
  resource_group_name    = "test-rg"
  location               = "northeurope"
  alert_email            = "operator@example.com"
  vm_admin_password      = "<offline-test-placeholder>"
  enable_stage_a         = true
  enable_stage_b         = false
  enable_stage_c         = false
  enable_stage_d         = false
  enable_stage_e         = false
  enable_stage_ai        = false
  enable_stage_sre_agent = false
}

run "foundation_without_console" {
  command = plan

  assert {
    condition     = length(terraform_data.console_ready) == 0
    error_message = "Stage A alone must not publish or provision the Web App console."
  }

  assert {
    condition     = length(terraform_data.sre_ready) == 0
    error_message = "Stage A alone must not run SRE validation."
  }

  assert {
    condition     = length(azapi_resource.stage_fabric) == 0
    error_message = "Fabric must remain off by default."
  }
}

run "workloads_include_console" {
  command = plan

  variables {
    enable_stage_b = true
  }

  assert {
    condition     = length(terraform_data.console_ready) == 1
    error_message = "Stage B must include the automatic console completion hook."
  }

  assert {
    condition     = contains(local.console_sources, "scripts/simulate-high-cpu.ps1")
    error_message = "CPU simulation script updates must rebuild and republish the console runner."
  }

  assert {
    condition     = alltrue([for name in ["setup-health-model.ps1", "setup-slis.ps1", "resolve-service-group-id.ps1"] : contains(local.console_sources, "scripts/${name}")])
    error_message = "Service Group and SLI setup changes must refresh post-deployment completion."
  }

  assert {
    condition     = terraform_data.console_ready[0].triggers_replace.resource_group == data.azurerm_resource_group.lab.id
    error_message = "Console completion must target the selected lab resource group."
  }

  assert {
    condition     = !jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).stage_e
    error_message = "Stage A+B must keep optional Stage E completion disabled."
  }
}

run "stage_e_refreshes_optional_completion" {
  command = plan

  variables {
    enable_stage_b = true
    enable_stage_e = true
  }

  assert {
    condition     = jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).stage_e
    error_message = "Changing Stage E must refresh the selected optional completion work."
  }

  assert {
    condition     = length(azapi_resource.stage_sentinel_content) == 1
    error_message = "Stage E with Sentinel enabled must deploy analytics content after onboarding."
  }
}

run "optional_agents_refresh_console" {
  command = plan

  variables {
    enable_stage_b         = true
    enable_stage_ai        = true
    enable_stage_sre_agent = true
  }

  assert {
    condition     = jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).ai && jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).sre
    error_message = "Changes to both optional agent stages must refresh console setup."
  }

  assert {
    condition     = length(terraform_data.sre_ready) == 0
    error_message = "The console completion path must not duplicate standalone SRE validation."
  }
}

run "sre_without_workloads_is_validated" {
  command = plan

  variables {
    enable_stage_sre_agent = true
  }

  assert {
    condition     = length(terraform_data.console_ready) == 0 && length(terraform_data.sre_ready) == 1
    error_message = "SRE without Stage B must validate the agent without publishing a Web App."
  }

  assert {
    condition     = terraform_data.sre_ready[0].triggers_replace.resource_group == data.azurerm_resource_group.lab.id
    error_message = "Standalone SRE validation must target the selected resource group."
  }
}

run "fabric_without_workloads" {
  command = plan

  variables {
    enable_stage_fabric = true
    fabric_admin_email  = "operator@example.com"
  }

  assert {
    condition     = length(azapi_resource.stage_fabric) == 1 && length(azapi_resource.stage_sre_agent) == 0 && length(terraform_data.console_ready) == 0
    error_message = "Fabric must deploy independently without enabling SRE or the Web App console."
  }

  assert {
    condition     = azapi_resource.stage_fabric[0].parent_id == data.azurerm_resource_group.lab.id && azapi_resource.stage_fabric[0].body.properties.parameters.fabricAdminEmail.value == var.fabric_admin_email
    error_message = "Fabric must retain the selected resource group and administrator input."
  }
}

run "fabric_and_sre_coexist" {
  command = plan

  variables {
    enable_stage_b         = true
    enable_stage_e         = true
    enable_stage_sre_agent = true
    enable_stage_fabric    = true
    fabric_admin_email     = "operator@example.com"
  }

  assert {
    condition     = length(azapi_resource.stage_fabric) == 1 && length(azapi_resource.stage_sre_agent) == 1 && length(terraform_data.console_ready) == 1
    error_message = "Fabric and SRE stages must coexist with integration console completion."
  }

  assert {
    condition     = azapi_resource.stage_e[0].body.properties.parameters.enableFabric.value
    error_message = "Stage E must retain the optional Fabric health tier."
  }
}

run "reject_missing_fabric_administrator" {
  command = plan

  variables {
    enable_stage_fabric = true
    fabric_admin_email  = ""
  }

  expect_failures = [var.fabric_admin_email]
}

run "reject_invalid_operator" {
  command = plan

  variables {
    console_operator_object_ids = ["00000000-0000-0000-0000-000000000000"]
  }

  expect_failures = [var.console_operator_object_ids]
}