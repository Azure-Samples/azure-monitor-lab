<#
.SYNOPSIS
  Prepare and verify the lab prerequisites for portal-created Service Level
  Indicators (Microsoft.Monitor/slis preview), scenario 46.

.DESCRIPTION
  The SLI resource provider is preview and its control-plane contract can
  change independently of the portal. This script deliberately does not create
  SLIs. It verifies the service group, locates the SLI identity and Azure
  Monitor Workspace, grants the destination ingestion permissions, confirms
  the documented Managed Prometheus metrics are flowing, and prints the exact
  values needed to create the sample SLIs in the Azure portal.

  The script is idempotent. Re-running it verifies the same prerequisites and
  reuses existing role assignments.

.PARAMETER ResourceGroup
  Lab resource group containing the Azure Monitor Workspace and SLI identity.

.PARAMETER SubscriptionId
  Expected Azure subscription. Required when .azure-target.json is absent.

.PARAMETER ServiceGroupId
  Service group that owns the portal-created SLIs. Defaults to the existing RG
  membership target, or the same subscription/RG-derived ID used by setup-health-model.ps1.

.PARAMETER Teardown
  Delete the documented sample SLIs if they were created in the portal.

.PARAMETER MetricWaitMinutes
  Maximum time to wait for all required Managed Prometheus source metrics.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup  = 'rg-azure-monitor-lab',
  [string] $SubscriptionId,
  [string] $ServiceGroupId,
  [ValidateRange(0, 60)]
  [int] $MetricWaitMinutes = 10,
  [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info($Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  if ($SubscriptionId -and $SubscriptionId -ne $target.expectedSubscriptionId) {
    throw "BLOCKED: -SubscriptionId '$SubscriptionId' does not match .azure-target.json '$($target.expectedSubscriptionId)'."
  }
  $SubscriptionId = $target.expectedSubscriptionId
} else {
  if (-not $SubscriptionId) {
    throw 'BLOCKED: specify -SubscriptionId when .azure-target.json is absent.'
  }
  $target = $null
}

az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "BLOCKED: active subscription '$($active.id)' does not match expected subscription '$SubscriptionId'."
}
if ($target -and $active.tenantId -ne $target.expectedTenantId) {
  throw "BLOCKED: active tenant '$($active.tenantId)' does not match expected tenant '$($target.expectedTenantId)'."
}
Write-Info "Sub: $($active.id)"
Write-Info "RG : $ResourceGroup"
$ServiceGroupId = & (Join-Path $PSScriptRoot 'resolve-service-group-id.ps1') `
  -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -ServiceGroupId $ServiceGroupId
Write-Info "SG : $ServiceGroupId"

$sliApi = '2025-03-01-preview'
$sgApi = '2024-02-01-preview'
$sgUrl = "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$ServiceGroupId" + "?api-version=$sgApi"

if ($Teardown) {
  Write-Step 'Removing documented sample SLIs'
  foreach ($sliName in @('sli-aks-pods-running', 'sli-aks-pod-start-latency')) {
    $sliResourceId = "/providers/Microsoft.Management/serviceGroups/$ServiceGroupId/providers/Microsoft.Monitor/slis/$sliName"
    $submitted = & (Join-Path $PSScriptRoot 'remove-arm-resource.ps1') `
      -SubscriptionId $SubscriptionId -ResourceId $sliResourceId -ApiVersion $sliApi
    if ($submitted) { Write-Info "Delete submitted: $sliName" }
    else { Write-Info "Already absent: $sliName" }
  }
  Write-Host "`nSLI cleanup finished: deletes submitted or resources already absent." -ForegroundColor Green
  return
}

Write-Step "Verifying service group '$ServiceGroupId'"
$serviceGroup = az rest --method get --url $sgUrl --only-show-errors 2>$null | ConvertFrom-Json
if (-not $serviceGroup -or $serviceGroup.properties.provisioningState -ne 'Succeeded') {
  throw "Service group '$ServiceGroupId' was not found in Succeeded state. Run scripts/setup-health-model.ps1 first."
}
Write-Info "Service group state: $($serviceGroup.properties.provisioningState)"

Write-Step "Locating SLI identity and Azure Monitor Workspace in '$ResourceGroup'"
$uami = az identity show -g $ResourceGroup -n id-sli-amlab --query '{id:id,clientId:clientId,principalId:principalId}' -o json 2>$null | ConvertFrom-Json
if (-not $uami.id -or -not $uami.clientId -or -not $uami.principalId) {
  throw "User-assigned identity 'id-sli-amlab' was not found or is incomplete in '$ResourceGroup'."
}

$amw = az resource show -g $ResourceGroup -n amw-amlab --resource-type Microsoft.Monitor/accounts -o json 2>$null | ConvertFrom-Json
if (-not $amw.id) {
  throw "Azure Monitor Workspace 'amw-amlab' was not found in '$ResourceGroup'."
}
Write-Info "UAMI: $($uami.id)"
Write-Info "AMW : $($amw.id)"

Write-Step 'Ensuring SLI source and destination permissions'
$ingestion = $amw.properties.defaultIngestionSettings
if (-not $ingestion.dataCollectionRuleResourceId) {
  throw "Azure Monitor Workspace 'amw-amlab' has no default ingestion DCR."
}

$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
$metricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
$roleRequirements = @(
  [pscustomobject]@{ Name = 'Monitoring Reader'; Id = $monitoringReaderRoleId; Scope = $amw.id }
  [pscustomobject]@{ Name = 'Monitoring Metrics Publisher'; Id = $metricsPublisherRoleId; Scope = $amw.id }
  [pscustomobject]@{ Name = 'Monitoring Reader'; Id = $monitoringReaderRoleId; Scope = $ingestion.dataCollectionRuleResourceId }
  [pscustomobject]@{ Name = 'Monitoring Metrics Publisher'; Id = $metricsPublisherRoleId; Scope = $ingestion.dataCollectionRuleResourceId }
  [pscustomobject]@{ Name = 'Monitoring Metrics Publisher'; Id = $metricsPublisherRoleId; Scope = $ingestion.dataCollectionEndpointResourceId }
)

foreach ($requirement in $roleRequirements) {
  if (-not $requirement.Scope) { continue }
  $assignments = az role assignment list --assignee-object-id $uami.principalId --scope $requirement.Scope -o json 2>$null | ConvertFrom-Json
  $existing = $assignments | Where-Object { $_.roleDefinitionId -like "*/$($requirement.Id)" } | Select-Object -First 1
  if ($existing) {
    Write-Info "$($requirement.Name) already assigned on $($requirement.Scope)"
    continue
  }

  az role assignment create `
    --assignee-object-id $uami.principalId `
    --assignee-principal-type ServicePrincipal `
    --role $requirement.Id `
    --scope $requirement.Scope `
    --only-show-errors | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to assign $($requirement.Name) on '$($requirement.Scope)'."
  }
  Write-Info "Assigned $($requirement.Name) on $($requirement.Scope)"
}

Write-Step 'Verifying Managed Prometheus source metrics'
$queryEndpoint = $amw.properties.metrics.prometheusQueryEndpoint
if (-not $queryEndpoint) {
  throw "Azure Monitor Workspace 'amw-amlab' has no Prometheus query endpoint."
}

function Get-PrometheusQueryToken {
  $PSNativeCommandUseErrorActionPreference = $false
  $tokenOutput = az account get-access-token --subscription $SubscriptionId `
    --resource https://prometheus.monitor.azure.com --query accessToken -o tsv --only-show-errors 2>&1
  $tokenExitCode = $LASTEXITCODE
  if ($tokenExitCode -ne 0) {
    if (($tokenOutput -join "`n") -match 'Audience\s+https://prometheus[.]monitor[.]azure[.]com/?\s+is not a supported MSI token audience') {
      throw @"
Cloud Shell's built-in credential cannot request the Azure Monitor Prometheus token audience. Source metrics have not been verified.

The Cloud Shell post-deployment wrapper handles this limitation automatically and continues after preparing SLI permissions. To verify source series separately, run this helper from a host whose user or workload credential supports the Prometheus audience. No workload redeployment is required.
"@
    }
    throw "Could not acquire an Azure Monitor Prometheus query token (Azure CLI exit code $tokenExitCode). Source metrics have not been verified; check your sign-in for the selected tenant and subscription."
  }
  $tokenLines = @($tokenOutput | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
  if ($tokenLines.Count -ne 1) {
    throw 'Could not acquire an Azure Monitor Prometheus query token: Azure CLI returned no single token. Source metrics have not been verified.'
  }
  return $tokenLines[0].Trim()
}

$metricQueries = [ordered]@{
  'up' = 'up'
  'kube_pod_status_phase' = 'kube_pod_status_phase'
  'kubelet_pod_start_duration_seconds_bucket{le="30"}' = 'kubelet_pod_start_duration_seconds_bucket{le="30"}'
  'kubelet_pod_start_duration_seconds_count' = 'kubelet_pod_start_duration_seconds_count'
}
$metricDeadline = (Get-Date).AddMinutes($MetricWaitMinutes)
do {
  $queryToken = Get-PrometheusQueryToken

  $metricCounts = @{}
  foreach ($entry in $metricQueries.GetEnumerator()) {
    $query = [uri]::EscapeDataString($entry.Value)
    $response = Invoke-RestMethod `
      -Method Get `
      -Uri "$queryEndpoint/api/v1/query?query=$query" `
      -Headers @{ Authorization = "Bearer $queryToken" } `
      -TimeoutSec 30
    $seriesCount = @($response.data.result).Count
    $metricCounts[$entry.Key] = $seriesCount
    Write-Info "$($entry.Key): $seriesCount series"
  }

  $missingMetrics = @($metricQueries.Keys | Where-Object { $metricCounts[$_] -eq 0 })
  if ($missingMetrics.Count -gt 0 -and (Get-Date) -lt $metricDeadline) {
    Write-Info "Waiting 30 seconds for Managed Prometheus propagation: $($missingMetrics -join ', ')"
    Start-Sleep -Seconds 30
  }
} while ($missingMetrics.Count -gt 0 -and (Get-Date) -lt $metricDeadline)

if ($missingMetrics.Count -gt 0) {
  throw "Required Managed Prometheus metrics did not appear within $MetricWaitMinutes minute(s): $($missingMetrics -join ', '). Verify AKS Managed Prometheus collection, then rerun this script."
}

$portalUrl = "https://portal.azure.com/#@$($active.tenantId)/resource/providers/Microsoft.Management/serviceGroups/$ServiceGroupId/serviceLevelIndicators"
Write-Host @"

SLI prerequisites verified. Create the sample SLIs in the portal:

  Portal       : $portalUrl
  Service group: $ServiceGroupId
  Source AMW   : $($amw.id)
  Destination  : $($amw.id)
  Identity     : $($uami.id)
  Client ID    : $($uami.clientId)

Suggested source metrics:
  Availability: kube_pod_status_phase, filtered to phase=running
  Latency     : kubelet_pod_start_duration_seconds_bucket, filtered to le=30
                kubelet_pod_start_duration_seconds_count

All four documented source metrics are currently flowing. See scenario 46 in
docs/DEMO-SCENARIOS.md for the complete portal field values.

"@ -ForegroundColor Green