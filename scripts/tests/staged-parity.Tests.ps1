$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert-Parity([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}
function Read-Template([string] $Path) {
  Get-Content -LiteralPath (Join-Path $root $Path) -Raw | ConvertFrom-Json
}
function Get-Module($Template, [string] $Name) {
  $matches = @($Template.resources | Where-Object name -CEQ $Name)
  Assert-Parity ($matches.Count -eq 1) "Expected exactly one module '$Name'."
  $matches[0]
}
$main = Read-Template 'infra\main.json'
$foundation = Read-Template 'infra\stages\00-foundation.json'
$alerts = Read-Template 'infra\stages\20-alerting.json'
$workloads = Read-Template 'infra\stages\10-workloads.json'
$advanced = Read-Template 'infra\stages\40-optional-advanced.json'
$cafe = Read-Template 'infra\stages\80-health-model-demo.json'
foreach ($case in @(
  @{ Name = 'summary-rules'; Stage = $foundation },
  @{ Name = 'vm-cpu-dynamic-alert'; Stage = $alerts },
  @{ Name = 'customer-dependencies'; Stage = $workloads },
  @{ Name = 'customer-health-model'; Stage = $advanced }
)) {
  $oneShot = Get-Module $main $case.Name
  $staged = Get-Module $case.Stage $case.Name
  Assert-Parity (($oneShot.properties.template | ConvertTo-Json -Depth 100 -Compress) -ceq
    ($staged.properties.template | ConvertTo-Json -Depth 100 -Compress)) "Compiled implementation differs for '$($case.Name)'."
}
$dynamic = Get-Module $alerts 'vm-cpu-dynamic-alert'
Assert-Parity ($dynamic.condition -ceq "[or(parameters('deployLinuxVm'), parameters('deployWindowsVm'))]") 'Do not deploy the dynamic CPU alert when both VMs are disabled.'
$vmScopes = $dynamic.properties.parameters.vmIds.value
Assert-Parity ($vmScopes -match "parameters\('deployLinuxVm'\)" -and $vmScopes -match "parameters\('deployWindowsVm'\)" -and
  $vmScopes -match "variables\('linuxVmName'\)" -and $vmScopes -match "variables\('windowsVmName'\)" -and
  $dynamic.properties.parameters.actionGroupId.value -match "actiongroup.*outputs.id") 'Dynamic alert scopes and routing must follow the staged VMs and action group.'
$tableModule = Get-Module $foundation 'summary-rules'
$table = @($tableModule.properties.template.resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces/tables')
Assert-Parity ($table.Count -eq 1 -and $table[0].properties.schema.name -ceq 'Perf_Hourly_CL' -and
  $table[0].properties.plan -ceq 'Analytics' -and $table[0].properties.retentionInDays -eq 180 -and
  @($table[0].properties.schema.columns | Where-Object name -eq 'SampleCount')[0].type -ceq 'long') 'Stage A must create the exact hourly summary table contract.'

$mainSource = Get-Content (Join-Path $root 'infra\main.bicep') -Raw
$stageSources = @(Get-ChildItem (Join-Path $root 'infra\stages') -Filter '*.bicep')
$pattern = "(?m)^module\s+\w+\s+'([^']+)'"
$stageModules = foreach ($file in $stageSources) {
  $file.Name
  foreach ($match in [regex]::Matches((Get-Content $file.FullName -Raw), $pattern)) {
    Split-Path $match.Groups[1].Value -Leaf
  }
}
foreach ($match in [regex]::Matches($mainSource, $pattern)) {
  $name = Split-Path $match.Groups[1].Value -Leaf
  if ($name -eq 'sentinel.bicep') {
    Assert-Parity ('sentinel-onboarding.bicep' -in $stageModules -and 'sentinel-rule.bicep' -in $stageModules) 'Staged Sentinel must cover both onboarding and content.'
  } else {
    Assert-Parity ($name -in $stageModules) "One-shot module '$name' has no staged counterpart. Wire it or document and test an explicit exception."
  }
}
$inlineStageResources = foreach ($file in $stageSources) {
  $template = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($file.FullName, '.json')) -Raw | ConvertFrom-Json
  $template.resources | Where-Object type -ne 'Microsoft.Resources/deployments'
}
foreach ($resource in $main.resources | Where-Object type -ne 'Microsoft.Resources/deployments') {
  $matches = @($inlineStageResources | Where-Object { $_.type -ceq $resource.type -and $_.name -ceq $resource.name })
  Assert-Parity ($matches.Count -gt 0) "One-shot inline resource '$($resource.type)/$($resource.name)' has no staged counterpart."
}
Write-Output 'PASS: every one-shot module has staged coverage; shared dynamic CPU, summary table and customer templates match.'

$tf = Get-Content (Join-Path $root 'terraform\main.tf') -Raw
$variables = Get-Content (Join-Path $root 'terraform\variables.tf') -Raw
$console = Get-Content (Join-Path $root 'terraform\console.tf') -Raw
$stageB = [regex]::Match($tf, '(?s)resource "azapi_resource" "stage_b" \{.*?(?=\r?\nresource |\z)').Value
foreach ($pair in @{
  enableCustomerDependencies = 'enable_customer_dependencies'
  sqlEntraAdminObjectId = 'sql_entra_admin_object_id'
  sqlEntraAdminName = 'sql_entra_admin_name'
  sqlEntraAdminType = 'sql_entra_admin_type'
  slotAppServicePlanSku = 'slot_app_service_plan_sku'
}.GetEnumerator()) {
  Assert-Parity ($variables -match "variable `"$($pair.Value)`"" -and
    $stageB -match "$($pair.Key)\s*=\s*\{\s*value\s*=\s*var\.$($pair.Value)\s*\}") "Terraform Stage B lost parameter '$($pair.Key)'."
}
$stageE = [regex]::Match($tf, '(?s)resource "azapi_resource" "stage_e" \{.*?(?=\r?\nresource |\z)').Value
Assert-Parity ($stageE -match 'enableCustomerDependencies\s*=\s*\{\s*value\s*=\s*var.enable_customer_dependencies\s*\}') 'Terraform Stage E must enable the dedicated customer Health Model.'
Assert-Parity ($tf -match '!var.enable_customer_dependencies \|\| \(var.enable_stage_a && var.enable_stage_b && var.enable_slot_failure_scenario' -and
  $tf -match 'trimspace\(var.sql_entra_admin_name\)' -and $variables -match '00000000-0000-0000-0000-000000000000') 'Customer infrastructure must fail validation without prerequisites and an explicit nonzero Entra administrator.'
Assert-Parity ($console.Contains("-CustomerDependencyDeploymentName 'stage-b-workloads'") -and
  $console.Contains('customer_dependencies = var.enable_customer_dependencies')) 'Terraform completion must track customer enablement and target its exact Stage B deployment.'
foreach ($source in @('scripts/create-summary-rule.ps1', 'scripts/complete-customer-dependencies.ps1',
  'scripts/customer-dependency-helpers.ps1', 'scripts/bootstrap-customer-sql.ps1', 'scripts/deploy-customer-dependencies.ps1',
  'workloads/customer-processor/*.cs', 'scripts/customer-sql-bootstrap/*.py')) {
  Assert-Parity ($console.Contains($source)) "Terraform completion does not track '$source'."
}
$tfDemo = Get-Content (Join-Path $root 'terraform\health-model-demo.tf') -Raw
Assert-Parity ($tfDemo -match 'enable_stage_a && var.enable_stage_b && var.enable_stage_c && var.enable_stage_e' -and
  $tfDemo -match 'infra/stages/80-health-model-demo.json' -and
  $console -match '-EnableStageHealthModelDemo' -and $console -match 'azapi_resource.stage_health_model_demo') 'Cafe infrastructure and publication must stay ordered after A/B/C/E.'
$embeddedCafe = (Get-Module $main 'health-model-demo').properties.template
Assert-Parity (($embeddedCafe | ConvertTo-Json -Depth 100 -Compress) -ceq
  ($cafe | ConvertTo-Json -Depth 100 -Compress)) 'One-shot and staged Cafe/model implementations must be identical.'
Write-Output 'PASS: Terraform forwards customer inputs and completion; Cafe/models share infrastructure and ordered publication. No Azure calls.'
