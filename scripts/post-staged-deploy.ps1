<#
.SYNOPSIS
  Run the local post-deployment setup after staged Bicep or Terraform deployment.

.DESCRIPTION
  Discovers the lab's App Service, AKS cluster, and suffixed central Log
  Analytics workspace, then runs the same post-deployment helpers used by deploy.ps1.

.PARAMETER ResourceGroup
  Resource group containing the staged lab deployment.

.PARAMETER NamePrefix
  Resource name prefix used by the deployment. Defaults to 'amlab'.

.PARAMETER EnableStageE
  Run the optional Service Group and SLI setup. Explicit values override the
  central config; when omitted, use stageToggles.enableStageE or default false.

.PARAMETER EnableStageSreAgent
  Validate SRE Agent when true. When omitted, detect the deployed SRE resource.
  Explicit false skips validation without deleting or disabling the agent.

.PARAMETER EnableStageObservabilityAgent
  Validate Azure Copilot Observability Agent when true. When omitted, detect the
  deployed resource. Explicit false skips validation without changing it.

.EXAMPLE
  ./scripts/post-staged-deploy.ps1 -ResourceGroup rg-azure-monitor-lab

.EXAMPLE
  ./scripts/post-staged-deploy.ps1 -ResourceGroup rg-my-lab -NamePrefix demo
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $SubscriptionId,
  [guid[]] $ConsoleOperatorObjectIds,
  [bool] $EnableStageE = $false,
  [bool] $EnableStageSreAgent = $false,
  [bool] $EnableStageObservabilityAgent = $false
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

$labConfigPath = Join-Path $PSScriptRoot '..' 'lab.config.json'
$labConfig = $null
if (Test-Path $labConfigPath) {
  $labConfig = Get-Content -Raw $labConfigPath | ConvertFrom-Json
  if (-not $PSBoundParameters.ContainsKey('EnableStageE') -and $null -ne $labConfig.stageToggles.enableStageE) {
    if ($labConfig.stageToggles.enableStageE -isnot [bool]) { throw 'stageToggles.enableStageE must be a JSON boolean.' }
    $EnableStageE = $labConfig.stageToggles.enableStageE
  }
}

# Honor the generated subscription and tenant guardrail when available.
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if ($SubscriptionId) {
  az account set --subscription $SubscriptionId --only-show-errors
  $active = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $active.id -ne $SubscriptionId) { throw 'The staged deployment subscription could not be verified.' }
} elseif (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: active subscription or tenant does not match .azure-target.json."
  }
} else {
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
}

Write-Info "Subscription: $($active.id)"
Write-Info "Resource group: $ResourceGroup"
Write-Info "Name prefix: $NamePrefix"

Write-Step "Discovering staged deployment resources"
$resources = @(az resource list --subscription $active.id -g $ResourceGroup -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Staged resource discovery failed.' }
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

if (-not $webApp) {
  throw "Could not find App Service 'app-$NamePrefix-<suffix>' in resource group '$ResourceGroup'. Complete the workload stage first."
}
if (-not $aks) {
  throw "Could not find AKS cluster 'aks-$NamePrefix' in resource group '$ResourceGroup'. Complete the workload stage first."
}
if (-not $centralLaw) {
  throw "Could not find central LAW 'law-$NamePrefix-central-<suffix>' in resource group '$ResourceGroup'. Complete the foundation stage first."
}

$webAppHost = "$($webApp.name).azurewebsites.net"
Write-Info "Web App: $($webApp.name)"
Write-Info "AKS: $($aks.name)"
Write-Info "Central LAW: $($centralLaw.name)"

Write-Step "Ensuring subscription Activity Log ships to the central LAW"
& (Join-Path $PSScriptRoot 'setup-activity-log.ps1') `
  -SubscriptionId $active.id `
  -ResourceGroup $ResourceGroup `
  -WorkspaceName $centralLaw.name

Write-Step "Running App Service and AKS post-deployment setup"
$postDeploy = Join-Path $PSScriptRoot 'post-deploy.ps1'
& $postDeploy `
  -SubscriptionId $active.id -TenantId $active.tenantId `
  -ResourceGroup $ResourceGroup `
  -WebAppName $webApp.name `
  -AksName $aks.name `
  -WebAppHost $webAppHost `
  -CentralLawName $centralLaw.name `
  -ConsoleOperatorObjectIds $ConsoleOperatorObjectIds

if ($EnableStageE) {
  Write-Step "Provisioning service group and health model prerequisites"
  $setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
  & $setupHm -ResourceGroup $ResourceGroup

  $sliIdentity = @($resources | Where-Object {
    $_.type -ieq 'Microsoft.ManagedIdentity/userAssignedIdentities' -and $_.name -ieq "id-sli-$NamePrefix"
  }) | Select-Object -First 1
  if ($sliIdentity) {
    Write-Step "Verifying demo SLI prerequisites and source metrics"
    $setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
    & $setupSli -SubscriptionId $active.id -ResourceGroup $ResourceGroup
  } else {
    Write-Info "SLI identity id-sli-$NamePrefix is not deployed. Complete Stage E before SLI verification."
  }
} else {
  Write-Info 'Stage E is disabled. Skipping Service Group and SLI setup; existing optional resources are unchanged.'
}

if ($EnableStageSreAgent) {
  Write-Step "SRE Agent stage enabled - validating readiness and printing the swedencentral trial setup handoff"
  & (Join-Path $PSScriptRoot 'setup-sre-agent.ps1') `
    -SubscriptionId $active.id `
    -ResourceGroup $ResourceGroup
}

if ($EnableStageObservabilityAgent) {
  Write-Step 'Observability Agent stage enabled - validating scope, operations, and least-privilege RBAC'
  & (Join-Path $PSScriptRoot 'setup-observability-agent.ps1') `
    -SubscriptionId $active.id `
    -ResourceGroup $ResourceGroup
}

Write-Host "`nPost-staged deployment setup completed." -ForegroundColor Green
