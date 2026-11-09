$ErrorActionPreference = 'Stop'
$preflight = Join-Path $PSScriptRoot '..\preflight-check.ps1'

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
        'account list-locations' { return '["northeurope","westeurope"]' }
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
        'provider show' { return '["North Europe","West Europe"]' }
        'rest --method' { return '{"value":[{"name":{"localizedValue":"Basic"},"currentValue":0,"limit":10}]}' }
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

$scenario = New-Scenario
foreach ($sku in $scenario.Skus[0..1]) {
  $sku.restrictions = @(@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' })
}
$result = Invoke-Preflight $scenario
if (-not $result.Failed) { throw 'Location-restricted SKUs must block deployment.' }
foreach ($text in @("vmSize='Standard_B2als_v2'", "aksNodeVmSize='Standard_D4as_v5'", "vmssSize='Standard_B2als_v2'", 'Standard_EC2as_v5 : 2 vCPUs', 'Standard_EC4as_v5 : 4 vCPUs', 'More quota may not remove the restriction', 'Nothing was changed automatically', 'confidential compute and may cost more', 'not a combined reservation')) {
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
