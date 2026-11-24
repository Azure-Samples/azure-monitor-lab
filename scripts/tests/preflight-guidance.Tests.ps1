$ErrorActionPreference = 'Stop'
$preflight = Join-Path $PSScriptRoot '..\preflight-check.ps1'

$deployPath = Join-Path $PSScriptRoot '..\deploy.ps1'
$deployAst = [Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$null, [ref]$null)
$assignments = $deployAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -in @('$pfDeployHealthModelDemo', '$pfCafeLocation', '$pfAppServicePlanTier')
}, $true)
if ($assignments.Count -ne 3) { throw 'Deployment must derive Cafe inputs and the core App Service tier for preflight.' }
$deriveInputs = [scriptblock]::Create(($assignments.Extent.Text -join "`n") + "`n@{ Enabled = `$pfDeployHealthModelDemo; Region = `$pfCafeLocation; Tier = `$pfAppServicePlanTier }")
foreach ($case in @(
  @{ Parameters = @{}; Enabled = $false; Region = 'francecentral' }
  @{ Parameters = @{ enableHealthModelDemo = @{ value = $true } }; Enabled = $true; Region = 'francecentral' }
  @{ Parameters = @{ enableHealthModelDemo = @{ value = $true }; healthModelDemoCafeLocation = @{ value = 'swedencentral' } }; Enabled = $true; Region = 'swedencentral' }
  @{ Parameters = @{ enableSlotFailureScenario = @{ value = $true } }; Enabled = $false; Region = 'francecentral' }
)) {
  $deploymentInputs = [pscustomobject]@{ parameters = [pscustomobject]$case.Parameters }
  $actual = & $deriveInputs
  if ($actual.Enabled -ne $case.Enabled -or $actual.Region -ne $case.Region -or $actual.Tier -cne 'Standard') { throw 'Deployment preflight must preserve Cafe overrides and use Standard for the core plan with or without the slot scenario.' }
}
$deployText = $deployAst.Extent.Text
foreach ($argument in @('-DeployHealthModelDemo $pfDeployHealthModelDemo', '-HealthModelDemoCafeLocation $pfCafeLocation', '-AppServicePlanTier $pfAppServicePlanTier', '-RequireAzureMonitorPipelineCapacity:$enableAzureMonitorPipeline')) {
  if (-not $deployText.Contains($argument)) { throw "Deployment preflight is missing '$argument'." }
}
Write-Host 'PASS: deployment forwards selected Cafe enablement and independent region to preflight.'

function New-TestSku($name, $family, $cpu, $memory, $restrictions = @()) {
  @{
    name = $name; family = $family; restrictions = $restrictions
    capabilities = @(@{ name = 'vCPUs'; value = "$cpu" }, @{ name = 'MemoryGB'; value = "$memory" })
  }
}

function New-Scenario {
  @{
    Skus = @(
      (New-TestSku 'Standard_B2als_v2' 'standardBasv2Family' 2 4)
      (New-TestSku 'Standard_D4as_v5' 'standardDASv5Family' 4 16)
      (New-TestSku 'Standard_EC2as_v5' 'standardECASv5Family' 2 16)
      (New-TestSku 'Standard_EC4as_v5' 'standardECASv5Family' 4 32)
    )
    Usage = @(
      @{ name = @{ value = 'cores' }; limit = 100; currentValue = 11 }
      @{ name = @{ value = 'standardBasv2Family' }; limit = 100; currentValue = 0 }
      @{ name = @{ value = 'standardDASv5Family' }; limit = 100; currentValue = 0 }
      @{ name = @{ value = 'standardECASv5Family' }; limit = 100; currentValue = 6 }
    )
    FailSkus = $false; FailUsage = $false
    CafeUnsupported = $false; CafeQuota = 10
  }
}

function Invoke-Preflight($scenario, $overrides = @{}) {
  $parameters = @{
    Location = 'northeurope'; VmSize = 'Standard_B2als_v2'
    AksNodeVmSize = 'Standard_D4as_v5'; AksNodeCount = 2; VmssSize = 'Standard_B2als_v2'
  }
  foreach ($key in $overrides.Keys) { $parameters[$key] = $overrides[$key] }
  $worker = {
    param($path, $scenario, $parameters)
    function az {
      $global:LASTEXITCODE = 0
      switch ($args[0..1] -join ' ') {
        'account show' { return '{"name":"test-subscription","id":"11111111-1111-1111-1111-111111111111"}' }
        'account list-locations' { return '["northeurope","westeurope","francecentral","swedencentral"]' }
        'vm list-skus' {
          if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne '11111111-1111-1111-1111-111111111111') { throw 'SKU query lost the verified subscription.' }
          if ($scenario.FailSkus) { $global:LASTEXITCODE = 1; return 'ERROR: SKU inventory AuthorizationFailed' }
          return ConvertTo-Json -InputObject $scenario.Skus -Depth 10
        }
        'vm list-usage' {
          if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne '11111111-1111-1111-1111-111111111111') { throw 'Quota query lost the verified subscription.' }
          if ($scenario.FailUsage) { $global:LASTEXITCODE = 1; return 'ERROR: quota AuthorizationFailed' }
          return ConvertTo-Json -InputObject $scenario.Usage -Depth 5
        }
        'provider show' {
          if ($scenario.CafeUnsupported) { return '["North Europe","West Europe"]' }
          return '["North Europe","West Europe","France Central","Sweden Central"]'
        }
        'rest --method' {
          $url = $args[[Array]::IndexOf($args, '--url') + 1]
          if ($url -match '/locations/(francecentral|swedencentral)/') {
            return @{ value = @(@{ name = @{ localizedValue = 'Standard' }; currentValue = 0; limit = $scenario.CafeQuota }) } | ConvertTo-Json -Depth 5
          }
          return '{"value":[{"name":{"localizedValue":"Basic"},"currentValue":0,"limit":10},{"name":{"localizedValue":"Standard"},"currentValue":3,"limit":-1}]}'
        }
        default { throw "Unexpected Azure command: $args" }
      }
    }
    try { & $path @parameters *>&1 }
    catch [System.Management.Automation.RuntimeException] { Write-Output $_ }
  }
  $runner = [PowerShell]::Create()
  try {
    $null = $runner.AddScript($worker.ToString()).AddArgument($preflight).AddArgument($scenario).AddArgument($parameters)
    $messages = @($runner.Invoke())
    @{
      Failed = $runner.HadErrors -or @($messages | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -gt 0
      Text = ($messages | ForEach-Object { $_.ToString() }) -join "`n"
    }
  } finally { $runner.Dispose() }
}

function Assert-Contains($result, $text) {
  if (-not $result.Text.Contains($text)) { throw "Missing preflight guidance '$text'. Output:`n$($result.Text)" }
}

$result = Invoke-Preflight (New-Scenario)
if ($result.Failed -or $result.Text.Contains('Resolving compute SKU')) { throw "Eligible configuration should pass without remediation guidance.`n$($result.Text)" }
Write-Host 'PASS: eligible sizes and sufficient combined quota preserve successful preflight.'
if ($result.Text.Contains('Cafe App Service')) { throw 'Disabled Cafe demo must not query or report a separate plan.' }
Assert-Contains $result 'Standard tier in westeurope'
$result = Invoke-Preflight (New-Scenario) @{ RequireAzureMonitorPipelineCapacity = $true }
if (-not $result.Failed) { throw 'The pipeline opt-in must reject the 2-vCPU default Linux VM.' }
Assert-Contains $result 'Set linuxVmSize'
$result = Invoke-Preflight (New-Scenario) @{ RequireAzureMonitorPipelineCapacity = $true; VmSize = 'Standard_EC4as_v5' }
if ($result.Failed) { throw "A compatible explicitly selected VM should pass the pipeline sizing check.`n$($result.Text)" }
$result = Invoke-Preflight (New-Scenario) @{
  RequireAzureMonitorPipelineCapacity = $true
  LinuxVmSize = 'Standard_D4as_v5'
  WindowsVmSize = 'Standard_B2als_v2'
}
if ($result.Failed) { throw "A 4-vCPU Linux VM and smaller Windows VM should pass independently.`n$($result.Text)" }
$result = Invoke-Preflight (New-Scenario) @{
  RequireAzureMonitorPipelineCapacity = $true
  LinuxVmSize = 'Standard_B2als_v2'
  WindowsVmSize = 'Standard_EC4as_v5'
}
if (-not $result.Failed) { throw 'A large Windows VM must not satisfy the Linux K3s minimum.' }

$scenario = New-Scenario
$result = Invoke-Preflight $scenario @{ DeployHealthModelDemo = $true; AppServicePlanTier = 'Basic' }
if ($result.Failed) { throw "Cafe defaults must pass independently of the core region.`n$($result.Text)" }
foreach ($text in @('Cafe App Service (S1)', 'available in francecentral', 'Cafe App Service quota', 'Standard tier in francecentral', 'Basic tier in westeurope', 'not a live capacity guarantee')) {
  Assert-Contains $result $text
}
$scenario.CafeQuota = 0
$result = Invoke-Preflight $scenario @{ DeployHealthModelDemo = $true; AppServicePlanTier = 'Standard' }
Assert-Contains $result 'region reports 0 Standard quota'
Assert-Contains $result '[WARN] Cafe App Service quota'
$scenario.CafeUnsupported = $true
$result = Invoke-Preflight $scenario @{ DeployHealthModelDemo = $true }
if (-not $result.Failed) { throw 'Unavailable Cafe region must block deployment even when core App Service is supported.' }
Assert-Contains $result 'NOT available in francecentral'
$scenario = New-Scenario
$result = Invoke-Preflight $scenario @{ DeployHealthModelDemo = $true; HealthModelDemoCafeLocation = 'swedencentral' }
Assert-Contains $result 'Standard tier in swedencentral'
$result = Invoke-Preflight $scenario @{ DeployHealthModelDemo = $true; HealthModelDemoCafeLocation = 'invalidregion' }
if (-not $result.Failed) { throw 'An invalid Cafe region must fail preflight.' }
Write-Host 'PASS: Cafe checks use the independent configured region and Standard tier, preserve overrides, and never promise live capacity.'

$scenario = New-Scenario
foreach ($sku in $scenario.Skus[0..1]) {
  $sku.restrictions = @(@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' })
}
$result = Invoke-Preflight $scenario
if (-not $result.Failed) { throw 'Location-restricted SKUs must block deployment.' }
foreach ($text in @("linuxVmSize='Standard_B2als_v2'", "windowsVmSize='Standard_B2als_v2'", "aksNodeVmSize='Standard_D4as_v5'", "vmssSize='Standard_B2als_v2'", 'Standard_EC2as_v5 : 2 vCPUs', 'Standard_EC4as_v5 : 4 vCPUs', 'More quota may not remove the restriction', 'Nothing was changed automatically', 'confidential compute and may cost more', 'not a combined reservation')) {
  Assert-Contains $result $text
}
$aksCandidates = [regex]::Match($result.Text, '(?s)aksNodeVmSize=.*?(?=vmssSize=)').Value
if ($aksCandidates.Contains('Standard_EC2as_v5')) { throw 'Two-vCPU EC2 must not be suggested for AKS.' }
Write-Host 'PASS: restricted sizes identify config keys and eligible role-specific alternatives without promising combined capacity.'

$result = Invoke-Preflight $scenario @{ WarnOnly = $true }
if ($result.Failed) { throw 'WarnOnly must retain its reporting-only exit behavior.' }
Assert-Contains $result 'continuing despite'

$scenario.Usage[3].limit = 6
$result = Invoke-Preflight $scenario
Assert-Contains $result 'No shortlist candidate has verified eligibility and headroom'
if ($result.Text.Contains('Standard_EC4as_v5 :')) { throw 'Quota-exhausted candidates must not be suggested.' }

$scenario = New-Scenario
$result = Invoke-Preflight $scenario @{ AksNodeVmSize = 'Standard_EC2as_v5' }
if (-not $result.Failed) { throw 'Two-vCPU AKS system nodes must fail preflight.' }
Assert-Contains $result 'non-B-series, at least 4 vCPUs and 4 GiB RAM'
$scenario.Skus += New-TestSku 'Standard_B4as_v2' 'standardBasv2Family' 4 16
$result = Invoke-Preflight $scenario @{ AksNodeVmSize = 'Standard_B4as_v2' }
if (-not $result.Failed) { throw 'B-series AKS system nodes must fail even with sufficient CPU/RAM.' }
$scenario.Skus[1].capabilities[1].value = '2'
$result = Invoke-Preflight $scenario
if (-not $result.Failed) { throw 'AKS system nodes with less than 4 GiB RAM must fail.' }
$scenario.Skus[1].capabilities[1].value = '16'
$result = Invoke-Preflight $scenario @{ AksNodeCount = 1 }
if (-not $result.Failed) { throw 'A single system node must fail the documented minimum check.' }
Assert-Contains $result 'configure at least two system nodes'
Write-Host 'PASS: AKS CPU, B-series, and system-node-count incompatibilities are actionable blockers.'

$scenario = New-Scenario
$scenario.Usage[1].limit = 5
$result = Invoke-Preflight $scenario
if (-not $result.Failed) { throw 'Insufficient combined family quota must block deployment.' }
Assert-Contains $result 'need 6 vCPU, have 5 free'
Assert-Contains $result 'Request increase'
Assert-Contains $result 'new TOTAL limit'
$scenario = New-Scenario
$scenario.Usage[0].currentValue = 95
$result = Invoke-Preflight $scenario
if (-not $result.Failed) { throw 'Insufficient combined regional quota must block deployment.' }
Assert-Contains $result 'need 14 vCPU, have 5 free'
Write-Host 'PASS: family and regional shortages distinguish quota increases from SKU eligibility.'

$scenario = New-Scenario
$scenario.Skus[0].restrictions = @(@{ type = 'Zone'; reasonCode = 'NotAvailableForSubscription' })
$result = Invoke-Preflight $scenario
if ($result.Failed) { throw 'Zone-only restrictions must not block the non-zonal lab.' }
Assert-Contains $result 'OK for non-zonal deploy'
$result = Invoke-Preflight $scenario @{ VmSize = 'Standard_NotOffered' }
if (-not $result.Failed) { throw 'A size absent from successful inventory must block deployment.' }
Assert-Contains $result 'not offered in northeurope'

$scenario = New-Scenario
$scenario.Usage = @($scenario.Usage | Where-Object { $_.name.value -ne 'cores' })
$result = Invoke-Preflight $scenario
Assert-Contains $result 'Regional usage/limit not reported'
if ($result.Text.Contains('Standard_EC4as_v5 :')) { throw 'Unknown regional quota must not produce verified-headroom suggestions.' }

foreach ($failure in @('FailSkus', 'FailUsage')) {
  $scenario = New-Scenario
  $scenario[$failure] = $true
  $result = Invoke-Preflight $scenario
  if (-not $result.Failed) { throw 'Azure lookup failures must not look like success.' }
  Assert-Contains $result 'AuthorizationFailed'
  if ($result.Text.Contains('not offered in northeurope') -or $result.Text.Contains('Pre-flight OK')) { throw 'Lookup failures must not be misreported as unavailable SKUs or success.' }
}
Write-Host 'PASS: zone-only restrictions, unknown quota, and lookup failures are reported accurately. No live Azure calls.'
