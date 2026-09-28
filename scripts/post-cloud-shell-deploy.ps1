<#
.SYNOPSIS
  Run the lab post-deployment setup from Azure Cloud Shell.

.DESCRIPTION
  Signs in to the selected tenant, pins and verifies the selected subscription, discovers the portal-deployed lab
  resources, resolves Application Insights through the core ARM CLI surface, and
  runs the same workload, Health Model, SLI, SRE, and Observability Agent validation helpers used by deploy.ps1.

.PARAMETER EnableStageSreAgent
  Validate SRE Agent when true. When omitted, detect the deployed SRE resource.
  Explicit false skips validation without deleting or disabling the agent.

.PARAMETER EnableStageObservabilityAgent
  Validate Azure Copilot Observability Agent when true. When omitted, detect the
  deployed resource. Explicit false skips validation without changing it.

.EXAMPLE
  ./scripts/post-cloud-shell-deploy.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [guid[]] $ConsoleOperatorObjectIds,
  [bool] $EnableStageSreAgent = $false,
  [bool] $EnableStageObservabilityAgent = $false
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

Write-Step "Signing in to the Azure tenant"
az login --tenant $TenantId --use-device-code --scope https://prometheus.monitor.azure.com/.default | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure login failed for tenant '$TenantId'." }

Write-Step "Pinning the Azure subscription"
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}
if ($active.tenantId -ne $TenantId) {
  throw "Tenant guardrail failed: expected '$TenantId', got '$($active.tenantId)'."
}

Write-Info "Subscription: $($active.id)"
Write-Info "Resource group: $ResourceGroup"
Write-Info "Name prefix: $NamePrefix"

Write-Step "Discovering portal deployment resources"
$resources = @(az resource list --subscription $active.id -g $ResourceGroup -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Portal resource discovery failed.' }
if (-not $PSBoundParameters.ContainsKey('EnableStageSreAgent')) {
  $EnableStageSreAgent = @($resources | Where-Object { $_.type -ieq 'Microsoft.App/agents' }).Count -gt 0
}
if (-not $PSBoundParameters.ContainsKey('EnableStageObservabilityAgent')) {
  $EnableStageObservabilityAgent = @($resources | Where-Object { $_.type -ieq 'Microsoft.Monitor/observabilityAgents' }).Count -gt 0
}
$webApp = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.Web/sites' -and $_.name -like "app-$NamePrefix-*"
}) | Select-Object -First 1
$aks = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.ContainerService/managedClusters' -and $_.name -ieq "aks-$NamePrefix"
}) | Select-Object -First 1
$centralLaw = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.OperationalInsights/workspaces' -and $_.name -like "law-$NamePrefix-central-*"
}) | Select-Object -First 1
$appInsights = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.Insights/components' -and $_.name -ieq "appi-$NamePrefix"
}) | Select-Object -First 1

if (-not $webApp) { throw "Could not find App Service 'app-$NamePrefix-<suffix>' in '$ResourceGroup'." }
if (-not $aks) { throw "Could not find AKS cluster 'aks-$NamePrefix' in '$ResourceGroup'." }
if (-not $centralLaw) { throw "Could not find central LAW 'law-$NamePrefix-central-<suffix>' in '$ResourceGroup'." }
if (-not $appInsights) { throw "Could not find Application Insights 'appi-$NamePrefix' in '$ResourceGroup'." }

$webAppHost = "$($webApp.name).azurewebsites.net"
Write-Info "Web App: $($webApp.name)"
Write-Info "AKS: $($aks.name)"
Write-Info "Central LAW: $($centralLaw.name)"
Write-Info "Application Insights: $($appInsights.name)"

Write-Step "Ensuring subscription Activity Log ships to the central LAW"
& (Join-Path $PSScriptRoot 'setup-activity-log.ps1') `
  -SubscriptionId $active.id `
  -ResourceGroup $ResourceGroup `
  -WorkspaceName $centralLaw.name

Write-Step "Resolving App Insights through ARM"
$appInsightsConnectionString = az resource show `
  --ids $appInsights.id `
  --api-version 2020-02-02 `
  --query properties.ConnectionString `
  -o tsv
if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
  throw "Application Insights connection string lookup returned no value."
}

Write-Step "Running App Service and AKS post-deployment setup"
& (Join-Path $PSScriptRoot 'post-deploy.ps1') `
  -SubscriptionId $active.id -TenantId $active.tenantId `
  -ResourceGroup $ResourceGroup `
  -WebAppName $webApp.name `
  -AksName $aks.name `
  -WebAppHost $webAppHost `
  -CentralLawName $centralLaw.name `
  -AppInsightsConnectionString $appInsightsConnectionString `
  -ConsoleOperatorObjectIds $ConsoleOperatorObjectIds

Write-Step "Provisioning service group and health model prerequisites"
& (Join-Path $PSScriptRoot 'setup-health-model.ps1') -ResourceGroup $ResourceGroup

Write-Step "Verifying demo SLI prerequisites and source metrics"
$sliSourceMetricsVerified = $true
try {
  & (Join-Path $PSScriptRoot 'setup-slis.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
} catch {
  if ($_.Exception.Message -notlike "Cloud Shell's built-in credential cannot request the Azure Monitor Prometheus token audience.*") {
    throw
  }
  $sliSourceMetricsVerified = $false
  Write-Warning 'Cloud Shell cannot request the Managed Prometheus token audience. SLI permissions are prepared, but source metric series were not verified. Continuing post-deployment.'
}

if ($EnableStageSreAgent) {
  Write-Step 'Validating the deployed SRE Agent and monitoring connectors'
  & (Join-Path $PSScriptRoot 'setup-sre-agent.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
}

if ($EnableStageObservabilityAgent) {
  Write-Step 'Validating the deployed Observability Agent, monitored Application Insights resource, and RBAC'
  & (Join-Path $PSScriptRoot 'setup-observability-agent.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup
}

Write-Host @"

Cloud Shell post-deployment setup completed.

Managed Prometheus source metrics verified: $sliSourceMetricsVerified

Manual SLI step still required:
  1. Open the SLI portal URL printed above.
  2. Create sli-aks-pods-running and sli-aks-pod-start-latency.
  3. Use amw-$NamePrefix and id-sli-$NamePrefix from resource group '$ResourceGroup'.
  4. Follow Scenario 46 in docs/DEMO-SCENARIOS.md for the exact fields and warm-up step.

The Deploy to Azure button and this wrapper prepare SLI prerequisites but do not
create the Microsoft.Monitor/slis preview resources.
"@ -ForegroundColor Green