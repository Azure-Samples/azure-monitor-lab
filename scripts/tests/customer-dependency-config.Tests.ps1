$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
$fixture = Join-Path $PSScriptRoot ('customer-config-fixture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts'), (Join-Path $fixture 'infra'), (Join-Path $fixture 'terraform') -Force | Out-Null
try {
  Copy-Item (Join-Path $repo 'scripts\sync-config.ps1') (Join-Path $fixture 'scripts\sync-config.ps1')
  $cfg = Get-Content (Join-Path $repo 'lab.config.json.example') -Raw | ConvertFrom-Json
  $cfg.subscriptionId = [guid]::NewGuid().ToString()
  $cfg.tenantId = [guid]::NewGuid().ToString()
  $cfg.vmAdminPassword = 'Fixture-only-N0tASecret!'
  $file = Join-Path $fixture 'lab.config.json'
  function Invoke-FixtureSync {
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $file
    & (Join-Path $fixture 'scripts\sync-config.ps1') -ConfigPath $file | Out-Null
  }
  Invoke-FixtureSync
  $parameters = (Get-Content (Join-Path $fixture 'infra\main.parameters.json') -Raw | ConvertFrom-Json).parameters
  if ($parameters.enableCustomerDependencies.value -ne $false -or $parameters.slotAppServicePlanSku.value -ne 'S2') { throw 'Dependencies must default false; current S2 slot plan must be retained.' }
  $tf = Get-Content (Join-Path $fixture 'terraform\stages.tfvars') -Raw
  if ($tf -match 'customer_dependencies|sql_entra') { throw 'Disabled baseline must not introduce unsupported Terraform settings.' }
  foreach ($invalid in @('true',1,$null)) {
    $cfg.stageToggles.enableCustomerDependencies = $invalid
    $failed = $false
    try { Invoke-FixtureSync } catch { $failed = $true }
    if (-not $failed) { throw 'Non-Boolean customer dependency toggle must fail.' }
  }
  $cfg.stageToggles.enableCustomerDependencies = $true
  $failed = $false
  try { Invoke-FixtureSync } catch { $failed = $true }
  if (-not $failed) { throw 'Customer feature must require dedicated slot app.' }
  $cfg.stageToggles.enableSlotFailureScenario = $true
  $cfg.sqlEntraAdminObjectId = '22222222-aaaa-bbbb-cccc-dddddddddddd'
  $cfg.sqlEntraAdminName = 'Customer SQL Operators'
  $cfg.stageToggles.enableStageB = $false
  $failed = $false
  try { Invoke-FixtureSync } catch { $failed = $true }
  if (-not $failed) { throw 'Customer feature must require Stage B.' }
  $cfg.stageToggles.enableStageB = $true
  $cfg.stageToggles.enableSlotFailureScenario = 'false'
  $failed = $false
  try { Invoke-FixtureSync } catch { $failed = $true }
  if (-not $failed) { throw 'String slot prerequisite must not be coerced into true.' }
  $cfg.stageToggles.enableSlotFailureScenario = $true
  Invoke-FixtureSync
  $parameters = (Get-Content (Join-Path $fixture 'infra\main.parameters.json') -Raw | ConvertFrom-Json).parameters
  if ($parameters.enableCustomerDependencies.value -ne $true -or $parameters.sqlEntraAdminName.value -ne 'Customer SQL Operators' -or $parameters.sqlEntraAdminType.value -ne 'Group') { throw 'Enabled Entra configuration was not materialized.' }
  $cfg.sqlEntraAdminObjectId = ''
  $failed = $false
  try { Invoke-FixtureSync } catch { $failed = $true }
  if (-not $failed) { throw 'Enabled feature must require explicit Entra administrator.' }
  $ui = Get-Content (Join-Path $repo 'infra\createUiDefinition.json') -Raw | ConvertFrom-Json
  $elements = @($ui.parameters.steps | Where-Object name -eq 'advanced').elements
  if (@($elements | Where-Object name -eq 'enableCustomerDependencies').defaultValue -ne $false -or
      @($elements | Where-Object name -eq 'slotAppServicePlanSku').defaultValue -ne 'S2') { throw 'Portal customer feature defaults do not match deployment defaults.' }
  foreach ($parameter in @('enableCustomerDependencies','slotAppServicePlanSku','sqlEntraAdminObjectId','sqlEntraAdminName','sqlEntraAdminType')) {
    if (-not $ui.parameters.outputs.$parameter) { throw "Portal is missing output $parameter." }
  }
  Write-Output 'PASS: customer feature default-off, Boolean validation, Stage B/slot prerequisites, Entra admin parameters, S2 preservation and Terraform disabled compatibility.'
} finally {
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
