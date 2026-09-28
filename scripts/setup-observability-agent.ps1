<#
.SYNOPSIS
  Validate the Azure Copilot Observability Agent deployed with the lab.

.DESCRIPTION
  Performs read-only validation of the preview resource, monitored Application
  Insights child, autonomous-operation settings, managed identity, and required
  role assignments. It never enables automatic investigation or grants roles.
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'
$apiVersion = '2026-05-01-preview'
$supportedLocations = @(
  'australiaeast', 'canadacentral', 'centralus', 'eastasia', 'eastus',
  'southcentralus', 'uksouth', 'westcentralus', 'westeurope'
)
$issueContributorRoleId = '8d7ecc5c-f27b-43cf-883f-46409d445502'
$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

function Write-Step($Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Check($Label, $Passed, $Detail) {
  $status = if ($Passed) { 'PASS' } else { 'FAIL' }
  $color = if ($Passed) { 'Green' } else { 'Red' }
  Write-Host ("  [{0}] {1}: {2}" -f $status, $Label, $Detail) -ForegroundColor $color
  if (-not $Passed) { throw "$Label validation failed: $Detail" }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI is required. Install it and run az login before continuing.'
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$labConfigPath = Join-Path $repoRoot 'lab.config.json'
$targetPath = Join-Path $repoRoot '.azure-target.json'
$labConfig = if (Test-Path $labConfigPath) { Get-Content -Raw $labConfigPath | ConvertFrom-Json } else { $null }
$target = if (Test-Path $targetPath) { Get-Content -Raw $targetPath | ConvertFrom-Json } else { $null }

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  if ($target -and -not [string]::IsNullOrWhiteSpace($target.expectedSubscriptionId)) {
    $SubscriptionId = $target.expectedSubscriptionId
  } elseif ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.subscriptionId)) {
    $SubscriptionId = $labConfig.subscriptionId
  }
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  throw 'Pass -SubscriptionId or configure it in lab.config.json.'
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  $ResourceGroup = if ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.resourceGroup)) {
    $labConfig.resourceGroup
  } else {
    'rg-azure-monitor-lab'
  }
}

Write-Step "Pinning Azure CLI to subscription $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query '{id:id,tenantId:tenantId,name:name}' -o json | ConvertFrom-Json
Write-Check 'Subscription guard' ($active.id -eq $SubscriptionId) "$($active.name) ($($active.id))"
if ($target -and -not [string]::IsNullOrWhiteSpace($target.expectedTenantId)) {
  Write-Check 'Tenant guard' ($active.tenantId -eq $target.expectedTenantId) $active.tenantId
}

Write-Step "Reading Observability Agent in $ResourceGroup"
$agents = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup --resource-type Microsoft.Monitor/observabilityAgents -o json | ConvertFrom-Json)
Write-Check 'Single Observability Agent' ($agents.Count -eq 1) ("{0} resource(s) found" -f $agents.Count)

$agentOutput = az resource show --subscription $SubscriptionId --ids $agents[0].id --api-version $apiVersion -o json 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Could not read the Observability Agent with API $apiVersion. Azure CLI returned:`n$($agentOutput -join "`n")"
}
$agent = ($agentOutput -join "`n") | ConvertFrom-Json
$normalizedLocation = $agent.location.ToLowerInvariant().Replace(' ', '')
Write-Check 'Supported region' ($normalizedLocation -in $supportedLocations) $agent.location
Write-Check 'System-assigned identity' (-not [string]::IsNullOrWhiteSpace($agent.identity.principalId)) $agent.identity.principalId
Write-Check 'Agent enabled' ([bool]$agent.properties.enabled) 'enabled'

$issueCreation = @($agent.properties.operations | Where-Object type -eq 'IssueCreation')
$investigation = @($agent.properties.operations | Where-Object type -eq 'Investigation')
Write-Check 'Issue correlation' ($issueCreation.Count -eq 1 -and $issueCreation[0].mode -eq 'Auto') $issueCreation[0].mode
Write-Check 'Investigation mode' ($investigation.Count -eq 1 -and $investigation[0].mode -in @('Auto', 'Manual')) $investigation[0].mode

$childrenOutput = az rest --method get --url "https://management.azure.com$($agent.id)/monitoredResources?api-version=$apiVersion" -o json 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Could not list monitored resources. Azure CLI returned:`n$($childrenOutput -join "`n")"
}
$children = @(($childrenOutput -join "`n") | ConvertFrom-Json).value
$appInsightsChildren = @($children | Where-Object {
  $_.properties.enabled -and $_.properties.resourceId -match '/providers/Microsoft\.Insights/components/'
})
Write-Check 'Application Insights scope' ($appInsightsChildren.Count -eq 1) $appInsightsChildren[0].properties.resourceId

$workspaceId = $agent.properties.monitoringAccountId
$workspaceAssignment = @(az role assignment list --subscription $SubscriptionId --assignee-object-id $agent.identity.principalId --scope $workspaceId --query "[?roleDefinitionId=='/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$issueContributorRoleId']" -o json | ConvertFrom-Json)
Write-Check 'Issue Contributor' ($workspaceAssignment.Count -gt 0) $workspaceId

$subscriptionScope = "/subscriptions/$SubscriptionId"
$subscriptionAssignment = @(az role assignment list --subscription $SubscriptionId --assignee-object-id $agent.identity.principalId --scope $subscriptionScope --query "[?roleDefinitionId=='/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$monitoringReaderRoleId']" -o json | ConvertFrom-Json)
Write-Check 'Monitoring Reader' ($subscriptionAssignment.Count -gt 0) $subscriptionScope

Write-Host "`nObservability Agent validation passed." -ForegroundColor Green
Write-Host "  Portal: https://portal.azure.com/#resource$($agent.id)"
Write-Host "  Azure Monitor workspace: $workspaceId"
Write-Host "  Automatic investigation: $($investigation[0].mode -eq 'Auto')"
