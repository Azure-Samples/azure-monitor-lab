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
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  resource_group_name = "test-rg"
  location            = "northeurope"
  alert_email         = "operator@example.com"
  vm_admin_password   = "<offline-test-placeholder>"
  enable_stage_a      = true
  enable_stage_b      = true
  enable_stage_c      = false
  enable_stage_d      = false
  enable_stage_e      = false
}

run "classic_and_otel_by_default" {
  command = plan

  assert {
    condition     = azapi_resource.stage_b[0].body.properties.parameters.enableVmOtelMetrics.value == true
    error_message = "Stage B must default to both classic VM Insights and OTel metrics."
  }

  assert {
    condition     = !contains(keys(azapi_resource.stage_a[0].body.properties.parameters), "enableVmOtelMetrics")
    error_message = "The VM OTel setting must not be passed to Stage A."
  }
}

run "explicit_enable" {
  command = plan

  variables {
    enable_vm_otel_metrics = true
  }

  assert {
    condition     = azapi_resource.stage_b[0].body.properties.parameters.enableVmOtelMetrics.value == true
    error_message = "Stage B must receive the enabled VM OTel setting."
  }

  assert {
    condition     = !contains(keys(azapi_resource.stage_a[0].body.properties.parameters), "enableVmOtelMetrics")
    error_message = "Opting in must not change Stage A parameters."
  }
}

run "explicit_opt_out" {
  command = plan

  variables {
    enable_vm_otel_metrics = false
  }

  assert {
    condition     = azapi_resource.stage_b[0].body.properties.parameters.enableVmOtelMetrics.value == false
    error_message = "An explicit false must remain false in Stage B parameters."
  }
}

run "foundation_only_does_not_deploy_workloads" {
  command = plan

  variables {
    enable_stage_b         = false
    enable_vm_otel_metrics = true
  }

  assert {
    condition     = length(azapi_resource.stage_b) == 0
    error_message = "The optional VM OTel toggle must not enable Stage B implicitly."
  }
}
