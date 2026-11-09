mock_provider "azurerm" {
  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
      name     = "test-rg"
      location = "swedencentral"
    }
  }
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000000" }
  }
}

mock_provider "azapi" {}

variables {
  subscription_id        = "00000000-0000-0000-0000-000000000000"
  resource_group_name    = "test-rg"
  location               = "swedencentral"
  alert_email            = "operator@example.com"
  vm_admin_password      = "<offline-test-placeholder>"
  enable_stage_a         = false
  enable_stage_b         = false
  enable_stage_c         = false
  enable_stage_d         = false
  enable_stage_e         = false
  enable_stage_ai        = false
  enable_stage_sre_agent = false
}

run "disabled_adds_nothing" {
  command = plan

  assert {
    condition     = length(azapi_resource.stage_health_model_demo) == 0
    error_message = "The optional demo must add no resources by default."
  }
  assert {
    condition     = output.health_model_demo_cafe_web_app_name == "" && output.health_model_demo_cafe_web_app_url == "" && output.health_model_demo_cafe_model_name == "" && output.health_model_demo_flow_model_name == ""
    error_message = "All demo outputs must be empty when disabled."
  }
}

run "enabled_preserves_native_contract" {
  command = plan

  variables {
    enable_stage_a                                           = true
    enable_stage_b                                           = true
    enable_stage_c                                           = true
    enable_stage_e                                           = true
    enable_stage_health_model_demo                           = true
    name_prefix                                              = "custom"
    deploy_linux_vm                                          = false
    deploy_windows_vm                                        = true
    health_model_demo_cafe_monitoring_reader_assignment_name = "11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = length(azapi_resource.stage_health_model_demo) == 1 && azapi_resource.stage_health_model_demo[0].body.properties.mode == "Incremental"
    error_message = "The demo must use one incremental native ARM deployment, not a local model builder."
  }
  assert {
    condition     = azapi_resource.stage_health_model_demo[0].body.properties.parameters.namePrefix.value == "custom" && !azapi_resource.stage_health_model_demo[0].body.properties.parameters.deployLinuxVm.value && azapi_resource.stage_health_model_demo[0].body.properties.parameters.deployWindowsVm.value
    error_message = "Core IDs must use the configured prefix and only deployed VMs."
  }
  assert {
    condition     = azapi_resource.stage_health_model_demo[0].body.properties.parameters.location.value == "swedencentral" && azapi_resource.stage_health_model_demo[0].body.properties.parameters.cafeMonitoringReaderAssignmentName.value == "11111111-1111-1111-1111-111111111111"
    error_message = "Adoption must preserve the standalone Cafe region and existing reader assignment GUID."
  }
  assert {
    condition     = length(azapi_resource.stage_health_model_demo[0].body.properties.template.resources) == 3 && azapi_resource.stage_health_model_demo[0].body.properties.template.outputs.healthModelDemoCafeModelName.value == "hm-lab-cafe" && azapi_resource.stage_health_model_demo[0].body.properties.template.outputs.healthModelDemoFlowModelName.value == "hm-amlab-flows"
    error_message = "The native stage must include Cafe workload and both original model names."
  }
  assert {
    condition     = jsondecode(terraform_data.console_ready[0].triggers_replace.integrations).health_model_demo && contains(local.console_sources, "scripts/setup-health-model-demo.ps1") && contains(local.console_sources, "scripts/publish-healthmodel-cafe.ps1") && contains(local.console_sources, "workloads/cafe/server.js") && contains(local.console_sources, "infra/stages/80-health-model-demo.json")
    error_message = "The flag, Cafe code, completion helpers and native template must trigger ordered console completion."
  }
}

run "reject_missing_foundation" {
  command = plan
  variables {
    enable_stage_health_model_demo = true
    enable_stage_b                 = true
    enable_stage_c                 = true
    enable_stage_e                 = true
  }
  expect_failures = [azapi_resource.stage_health_model_demo]
}

run "reject_missing_workloads" {
  command = plan
  variables {
    enable_stage_health_model_demo = true
    enable_stage_a                 = true
    enable_stage_c                 = true
    enable_stage_e                 = true
  }
  expect_failures = [azapi_resource.stage_health_model_demo]
}

run "reject_missing_alerting" {
  command = plan
  variables {
    enable_stage_health_model_demo = true
    enable_stage_a                 = true
    enable_stage_b                 = true
    enable_stage_e                 = true
  }
  expect_failures = [azapi_resource.stage_health_model_demo]
}

run "reject_missing_availability_test" {
  command = plan
  variables {
    enable_stage_health_model_demo = true
    enable_stage_a                 = true
    enable_stage_b                 = true
    enable_stage_c                 = true
  }
  expect_failures = [azapi_resource.stage_health_model_demo]
}
