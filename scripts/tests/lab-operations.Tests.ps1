$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../invoke-lab-operation.ps1'
$subscription = [guid]::NewGuid().ToString()
$tenant = [guid]::NewGuid().ToString()
$environment = @{
  LAB_RUNNER_MODE = 'ContainerAppsJob'
  LAB_SUBSCRIPTION_ID = $subscription; LAB_TENANT_ID = $tenant; LAB_RESOURCE_GROUP = 'test-rg'
  LAB_WEB_APP_NAME = 'app-amlab-test'; LAB_CUSTOMER_WEB_APP_NAME = 'app-amlab-test-customer'
}
$previous = @{}
foreach ($name in $environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
$parameters = @{ SubscriptionId = $subscription; TenantId = $tenant; ResourceGroup = 'test-rg'; RequestId = ('b' * 32); ValidateOnly = $true }

function Assert-Rejected([hashtable] $Changes) {
  $values = $parameters.Clone()
  $values.Operation = 'start'
  foreach ($name in $Changes.Keys) { $values[$name] = $Changes[$name] }
  $rejected = $false
  try { & $scriptPath @values | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw 'Unsafe runner parameters were accepted.' }
}

try {
  foreach ($operation in @('start', 'break', 'restore', 'ramp', 'cpu')) { & $scriptPath @parameters -Operation $operation | Out-Null }
  & $scriptPath @parameters -Operation logs -Count 100 | Out-Null
  & $scriptPath @parameters -Operation annotation -Name 'Release 1.2 (demo)' -Category Deployment | Out-Null
  Assert-Rejected @{ Operation = 'teardown' }
  Assert-Rejected @{ ResourceGroup = 'other-rg' }
  Assert-Rejected @{ SubscriptionId = [guid]::NewGuid().ToString() }
  Assert-Rejected @{ TenantId = [guid]::NewGuid().ToString() }
  Assert-Rejected @{ RequestId = 'invalid' }
  Assert-Rejected @{ Count = 12 }
  Assert-Rejected @{ Operation = 'cpu'; Count = 1 }
  Assert-Rejected @{ Operation = 'cpu'; Name = 'command' }
  Assert-Rejected @{ Operation = 'cpu'; Category = 'Incident' }
  Assert-Rejected @{ Operation = 'logs'; Count = 0 }
  Assert-Rejected @{ Operation = 'logs'; Count = 101 }
  Assert-Rejected @{ Operation = 'annotation'; Name = '$(whoami)'; Category = 'Deployment' }
  Assert-Rejected @{ Operation = 'annotation'; Name = 'marker'; Category = 'Other' }
  foreach ($setting in @(@('LAB_RUNNER_MODE', 'other'), @('LAB_RESOURCE_GROUP', 'other-rg'))) {
    [Environment]::SetEnvironmentVariable($setting[0], $setting[1])
    Assert-Rejected @{}
    [Environment]::SetEnvironmentVariable($setting[0], $environment[$setting[0]])
  }
  $tokens = $null; $parseErrors = $null
  $null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
  Write-Output 'PASS: runner allowlist, deployed-target checks, bounded inputs, and PowerShell syntax. No Azure calls executed.'
} finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }