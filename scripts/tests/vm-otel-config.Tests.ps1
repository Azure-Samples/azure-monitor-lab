$ErrorActionPreference = 'Stop'
$repoRoot = Join-Path $PSScriptRoot '..\..'
$root = Join-Path $PSScriptRoot "vm-otel-config-fixture-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts'), (Join-Path $root 'infra'), (Join-Path $root 'terraform') -Force
$helper = Join-Path $root 'scripts\sync-config.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\sync-config.ps1') -Destination $helper
$configPath = Join-Path $root 'lab.config.json'
$config = @{
  subscriptionId = [guid]::NewGuid().ToString(); tenantId = [guid]::NewGuid().ToString()
  alertEmail = 'operator@example.com'; vmAdminPassword = [guid]::NewGuid().ToString()
  resourceGroup = 'test-rg'; location = 'northeurope'; namePrefix = 'test'
}
try {
  foreach ($case in @('missing', 'false', 'true')) {
    $config.Remove('enableVmOtelMetrics')
    if ($case -ne 'missing') { $config.enableVmOtelMetrics = $case -eq 'true' }
    $config | ConvertTo-Json | Set-Content -LiteralPath $configPath
    & $helper -ConfigPath $configPath
    $bicep = Get-Content -LiteralPath (Join-Path $root 'infra\main.parameters.json') -Raw | ConvertFrom-Json
    $terraform = Get-Content -LiteralPath (Join-Path $root 'terraform\stages.tfvars') -Raw
    $expected = $case -ne 'false'
    if ($bicep.parameters.enableVmOtelMetrics.value -isnot [bool] -or $bicep.parameters.enableVmOtelMetrics.value -ne $expected) {
      throw "Bicep VM OTel Boolean was not preserved for $case."
    }
    if ($terraform -notmatch "(?m)^enable_vm_otel_metrics\s*=\s*$($expected.ToString().ToLower())\r?$") {
      throw "Terraform VM OTel Boolean was not preserved for $case."
    }
  }
  $outputs = @((Join-Path $root 'infra\main.parameters.json'), (Join-Path $root 'terraform\stages.tfvars'), (Join-Path $root '.azure-target.json'))
  $before = Get-FileHash -LiteralPath $outputs
  foreach ($invalid in @('false', 'true', '', 0, 1, $null, @(), @{})) {
    $config.enableVmOtelMetrics = $invalid
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
    $rejected = $false
    try { & $helper -ConfigPath $configPath } catch {
      if ($_.Exception.Message -notmatch 'enableVmOtelMetrics must be a JSON Boolean') { throw }
      $rejected = $true
    }
    if (-not $rejected) { throw 'A non-Boolean VM OTel value was accepted.' }
    $after = Get-FileHash -LiteralPath $outputs
    if (Compare-Object $before.Hash $after.Hash) { throw 'Invalid config changed generated deployment inputs.' }
  }
  foreach ($path in @('lab.config.json.example', 'infra\main.parameters.json.template')) {
    $example = Get-Content -LiteralPath (Join-Path $repoRoot $path) -Raw | ConvertFrom-Json
    $value = if ($path -eq 'lab.config.json.example') { $example.enableVmOtelMetrics } else { $example.parameters.enableVmOtelMetrics.value }
    if ($value -isnot [bool] -or -not $value) { throw "$path must default VM OTel to Boolean true." }
  }
  $ui = Get-Content -LiteralPath (Join-Path $repoRoot 'infra\createUiDefinition.json') -Raw | ConvertFrom-Json
  $control = @($ui.parameters.steps | Where-Object name -EQ 'workloads').elements | Where-Object name -EQ 'enableVmOtelMetrics'
  if ($control.defaultValue -ne 'Yes' -or $ui.parameters.outputs.enableVmOtelMetrics -ne "[steps('workloads').enableVmOtelMetrics]") {
    throw 'Portal VM OTel control must default on and output its Boolean to the main parameter.'
  }
  foreach ($option in $control.constraints.allowedValues) {
    if ($option.value -isnot [bool] -or $option.value -ne ($option.label -eq 'Yes')) { throw 'Portal options must use real Boolean values.' }
  }
  if (@($control.constraints.allowedValues).Count -ne 2) { throw 'Portal must provide both Boolean options.' }
  Write-Host 'PASS: VM OTel config missing/false/true, invalid types, no writes on validation failure, and example/UI defaults.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
