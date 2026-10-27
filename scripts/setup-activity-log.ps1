<#
.SYNOPSIS
  Route the subscription Activity Log to the lab's central Log Analytics workspace.

.DESCRIPTION
  Pins and verifies the selected subscription, resolves the workspace with a stable
  Azure CLI command, and creates or updates the subscription diagnostic setting.
  Repeated runs are a no-op when the setting already targets the expected workspace.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $WorkspaceName
)

$ErrorActionPreference = 'Stop'
$diagnosticSettingName = 'amlab-activity-to-law'

az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Could not select subscription '$SubscriptionId'." }
$activeSubscriptionId = az account show --query id -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or $activeSubscriptionId -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$activeSubscriptionId'."
}

$workspaceId = az monitor log-analytics workspace show `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --workspace-name $WorkspaceName `
  --query id -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceId)) {
  throw "Could not resolve Log Analytics workspace '$WorkspaceName' in '$ResourceGroup'."
}

$existingWorkspaceId = az monitor diagnostic-settings subscription list `
  --subscription $SubscriptionId `
  --query "value[?name=='$diagnosticSettingName'].workspaceId | [0]" `
  -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Could not inspect subscription diagnostic setting '$diagnosticSettingName'." }

if ($existingWorkspaceId -and $existingWorkspaceId -ieq $workspaceId) {
  Write-Host "   '$diagnosticSettingName' already routes Activity Log to '$WorkspaceName'" -ForegroundColor DarkGray
  return
}

$logs = '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
az monitor diagnostic-settings subscription create `
  --subscription $SubscriptionId `
  --name $diagnosticSettingName `
  --location global `
  --workspace $workspaceId `
  --logs $logs `
  --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not configure subscription diagnostic setting '$diagnosticSettingName'." }

Write-Host "   '$diagnosticSettingName' created -> Activity Log will start landing in '$WorkspaceName' (5-15 min latency)" -ForegroundColor Green