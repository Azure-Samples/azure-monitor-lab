<#
.SYNOPSIS
  Deploy the Azure Monitor Lab.

.DESCRIPTION
  1. Creates the resource group (if missing).
  2. Deploys infra/main.bicep at RG scope (LAW x2, App Insights, AMW, VNet, VMs, AKS,
     Grafana, App Service, Action Group, Alerts, Diagnostic-Settings Policies,
     Saved Queries, Workbook).
  3. Calls post-deploy.ps1 to:
       - Push the .NET hello-world sample to the App Service (auto-instrumented App Insights)
       - Wire kubectl to AKS
       - Apply the K8s frontend + k6 load generator (pointing at the App Service URL)

.PARAMETER ResourceGroup
  Resource group name. Created if it does not already exist; reused if it does.
  Precedence: explicit -ResourceGroup > lab.config.json 'resourceGroup' > default 'rg-azure-monitor-lab'.

.PARAMETER Location
  Region. Precedence: explicit -Location > lab.config.json 'location' > default 'northeurope'.

.PARAMETER ParametersFile
  Bicep parameters file. Defaults to infra/main.parameters.json.

.EXAMPLE
  ./scripts/deploy.ps1

.EXAMPLE
  ./scripts/deploy.ps1 -ResourceGroup rg-my-lab -Location westeurope
#>

[CmdletBinding()]
param(
  [string] $ResourceGroup  = 'rg-azure-monitor-lab',
  [string] $Location       = 'northeurope',
  [string] $ParametersFile = (Join-Path $PSScriptRoot '..' 'infra' 'main.parameters.json'),
  [switch] $SkipPreflight,
  [int]    $MaxDeployRetries = 0,
  [guid[]] $ConsoleOperatorObjectIds
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
  Write-Host "`n==> $msg" -ForegroundColor Cyan
}

# Deployment sizing used by the pre-flight availability/quota check. Defaults match the
# Bicep defaults; overridden from lab.config.json below when present.
$pfAksNodeCount    = 1
$pfDeployWindowsVm = $true
$pfDeployLinuxVm   = $true
$pfDeployObservabilityAgent = $false
$pfObservabilityAgentLocation = 'westeurope'

# -------------------------------------------------------------------
# Materialize derived files (.azure-target.json, main.parameters.json,
# terraform/stages.tfvars) from the central lab.config.json — but only
# if the user has bootstrapped lab.config.json. Skipped silently for
# users who hand-manage the legacy per-tool files.
# -------------------------------------------------------------------
$labConfigPath = Join-Path $PSScriptRoot '..' 'lab.config.json'
if (Test-Path $labConfigPath) {
  Write-Host "==> Syncing derived config files from lab.config.json" -ForegroundColor Cyan
  & (Join-Path $PSScriptRoot 'sync-config.ps1')

  # Honor lab.config.json as the single source of truth for RG + region, but only
  # when the caller did not pass an explicit override. Precedence:
  #   explicit -ResourceGroup/-Location  >  lab.config.json  >  built-in defaults.
  $labCfg = Get-Content -Raw $labConfigPath | ConvertFrom-Json
  if (-not $PSBoundParameters.ContainsKey('ResourceGroup') -and -not [string]::IsNullOrWhiteSpace($labCfg.resourceGroup)) {
    $ResourceGroup = $labCfg.resourceGroup
  }
  if (-not $PSBoundParameters.ContainsKey('Location') -and -not [string]::IsNullOrWhiteSpace($labCfg.location)) {
    $Location = $labCfg.location
  }

  # Mirror the deployment sizing so the pre-flight check validates the real footprint.
  if ($null -ne $labCfg.aksNodeCount)    { $pfAksNodeCount    = [int]$labCfg.aksNodeCount }
  if ($null -ne $labCfg.deployWindowsVm) { $pfDeployWindowsVm = [bool]$labCfg.deployWindowsVm }
  if ($null -ne $labCfg.deployLinuxVm)   { $pfDeployLinuxVm   = [bool]$labCfg.deployLinuxVm }
  if ($null -ne $labCfg.stageToggles.enableStageObservabilityAgent) {
    $pfDeployObservabilityAgent = [bool]$labCfg.stageToggles.enableStageObservabilityAgent
  }
  if (-not [string]::IsNullOrWhiteSpace($labCfg.observabilityAgentLocation)) {
    $pfObservabilityAgentLocation = $labCfg.observabilityAgentLocation
  }
}

# -------------------------------------------------------------------
# Subscription guardrail — hard-fail if not pointed at the lab sub.
# -------------------------------------------------------------------
function Assert-AllowedSubscription {
  $targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
  if (-not (Test-Path $targetFile)) { throw ".azure-target.json not found at $targetFile. Bootstrap with: Copy-Item lab.config.json.example lab.config.json; edit it; re-run this script." }
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json

  Write-Host "==> Pinning active az subscription to $($target.expectedSubscriptionName) ($($target.expectedSubscriptionId))" -ForegroundColor Cyan
  az account set --subscription $target.expectedSubscriptionId | Out-Null

  $active = az account show --query "{id:id, tenantId:tenantId, name:name}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: active sub '$($active.name)' ($($active.id), tenant $($active.tenantId)) is not the allowed lab sub ($($target.expectedSubscriptionId), tenant $($target.expectedTenantId)). Run 'az login --tenant $($target.expectedTenantId)' and retry."
  }
  if ($target.forbiddenSubscriptionIds -contains $active.id) {
    throw "BLOCKED: active sub '$($active.name)' is on the forbidden list."
  }
  Write-Host "   OK — $($active.name)" -ForegroundColor Green
  return $active
}

$active = Assert-AllowedSubscription

# 0. Sanity
Write-Step "Active subscription"
az account show --query "{name:name, id:id, tenantId:tenantId, user:user.name}" -o table

# 0b. Pre-flight availability + quota check — fail in ~15s instead of 20min in.
if ($SkipPreflight) {
  Write-Step "Skipping pre-flight availability/quota check (-SkipPreflight)"
} else {
  Write-Step "Pre-flight: validating SKUs + quota + resource availability in $Location"
  $preflight = Join-Path $PSScriptRoot 'preflight-check.ps1'
  & $preflight -Location $Location `
               -AksNodeCount $pfAksNodeCount `
               -DeployWindowsVm $pfDeployWindowsVm `
               -DeployLinuxVm $pfDeployLinuxVm `
               -DeployObservabilityAgent $pfDeployObservabilityAgent `
               -ObservabilityAgentLocation $pfObservabilityAgentLocation `
               -ResourceGroup $ResourceGroup
  if ($LASTEXITCODE -ne 0) {
    throw "Pre-flight check failed for region '$Location'. Fix the FAIL rows above (or re-run with -SkipPreflight to bypass) before deploying."
  }
}

# 1. Resource group
Write-Step "Ensuring resource group $ResourceGroup in $Location"
az group create -n $ResourceGroup -l $Location --tags purpose=azure-monitor-lab owner=demo-lab | Out-Null

# 1b. Resource provider registration — Health Models (preview) is not auto-registered
function Register-ResourceProvider {
  param([string] $Namespace)
  $state = az provider show -n $Namespace --query registrationState -o tsv 2>$null
  if ($state -eq 'Registered') {
    Write-Host "   $Namespace already Registered" -ForegroundColor DarkGray
    return
  }
  Write-Host "   $Namespace : state = $state, registering..." -ForegroundColor Yellow
  az provider register -n $Namespace --only-show-errors 2>$null | Out-Null
  do {
    Start-Sleep -Seconds 10
    $state = az provider show -n $Namespace --query registrationState -o tsv
    Write-Host "   $Namespace : $state" -ForegroundColor DarkGray
  } while ($state -eq 'Registering')
  if ($state -ne 'Registered') { throw "Failed to register $Namespace (final state: $state)" }
}

Write-Step "Ensuring preview resource providers are registered"
Register-ResourceProvider -Namespace 'Microsoft.CloudHealth'
Register-ResourceProvider -Namespace 'Microsoft.App'
Register-ResourceProvider -Namespace 'Microsoft.ContainerRegistry'

# 2. Deploy
Write-Step "Deploying main.bicep (this takes about 5 minutes: AKS + VMs + Grafana)"
$deploymentName = "amlab-$(Get-Date -Format 'yyyyMMddHHmmss')"
$mainBicep = Join-Path $PSScriptRoot '..' 'infra' 'main.bicep'

# Transient allocation/capacity error codes. These are region-wide, service-side, and
# NOT knowable ahead of time via any quota/SKU/availability API (see preflight-check.ps1) —
# so we detect them here and surface actionable guidance instead of silently continuing.
$capacityCodes = @(
  'AksCapacityHeavyUsage','CapacityHeavyUsage','AllocationFailed','ZonalAllocationFailed',
  'OverconstrainedAllocationRequest','SkuNotAvailable','InsufficientCapacity'
)

# Hard per-subscription quota limits (NOT transient) — e.g. a region with 0 App Service
# quota for a tier. Retrying won't help; the fix is a different region or a quota request.
$quotaCodes = @(
  'InternalSubscriptionIsOverQuotaForSku','QuotaExceeded','OverQuota','SubscriptionIsOverQuotaForSku'
)

function Get-FailedOperationMessages {
  param([string] $Rg, [string] $Name)
  $msgs = az deployment operation group list -g $Rg -n $Name `
            --query "[?properties.provisioningState=='Failed'].properties.statusMessage" -o json 2>$null
  if ($msgs) { ($msgs | ConvertFrom-Json | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join "`n" } else { '' }
}

$attempt = 0
$sentinelRetryCount = 0
$appServiceCapacityRetryCount = 0
$ambaMetricRetryCount = 0
while ($true) {
  $attempt++
  if ($attempt -gt 1) {
    $deploymentName = "amlab-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "   Retry $($attempt - 1)/$MaxDeployRetries — capacity is often reclaimed as others delete clusters..." -ForegroundColor Yellow
  }

  az deployment group create `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --template-file $mainBicep `
    --parameters "@$ParametersFile" `
    --parameters location=$Location `
    --output none

  if ($LASTEXITCODE -eq 0) { break }

  # Deployment failed — figure out whether it's a transient capacity/allocation problem.
  $failMessages = Get-FailedOperationMessages -Rg $ResourceGroup -Name $deploymentName
  $matchedCode  = $capacityCodes | Where-Object { $failMessages -match $_ } | Select-Object -First 1
  $matchedQuota = $quotaCodes    | Where-Object { $failMessages -match $_ } | Select-Object -First 1
  $sentinelQueryNotReady = $failMessages -match 'Failed to run the analytics rule query.*workspace.*could not be found'
  $appServiceCapacityNotReady = $failMessages -match 'No available instances to satisfy this request|App Service is attempting to increase capacity'
  $ambaMetricNotReady = $failMessages -match "Couldn't find a metric named (Http4xx|Http5xx|HttpResponseTime)"

  if ($sentinelQueryNotReady -and $sentinelRetryCount -lt 2) {
    $sentinelRetryCount++
    Write-Host "`n   ⚠ Sentinel analytics-rule validation is not ready yet. Waiting 60 seconds and retrying deployment ($sentinelRetryCount/2)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
    continue
  }

  if ($appServiceCapacityNotReady -and $appServiceCapacityRetryCount -lt 2) {
    $appServiceCapacityRetryCount++
    Write-Host "`n   ⚠ App Service capacity is not ready in its deployment region. Waiting 60 seconds and retrying deployment ($appServiceCapacityRetryCount/2)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
    continue
  }

  if ($ambaMetricNotReady -and $ambaMetricRetryCount -lt 2) {
    $ambaMetricRetryCount++
    Write-Host "`n   WARNING: App Service metrics are not ready yet. Waiting 60 seconds and retrying deployment ($ambaMetricRetryCount/2)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 60
    continue
  }

  if ($matchedCode) {
    Write-Host "`n   ⚠ Capacity/allocation failure ($matchedCode) in region '$Location'." -ForegroundColor Yellow
    if ($attempt -le $MaxDeployRetries) {
      Start-Sleep -Seconds 60
      continue
    }
    throw @"
Deployment failed: '$matchedCode' in region '$Location'.

This is a transient, region-wide Azure capacity condition — it can't be pre-validated by any
quota/SKU API, so the pre-flight check can't catch it. Fixes (see https://aka.ms/akscapacityheavyusage):
  • Deploy to another region (fastest). The RG + region are now parameters, e.g.:
        ./scripts/deploy.ps1 -ResourceGroup $ResourceGroup -Location northeurope
  • Or retry later — capacity is reclaimed as others delete clusters:
        ./scripts/deploy.ps1 -ResourceGroup $ResourceGroup -Location $Location -MaxDeployRetries 3
"@
  }

  if ($matchedQuota) {
    throw @"
Deployment failed: '$matchedQuota' in region '$Location'.

This subscription has a hard quota limit (often 0) for a required SKU in this region — for
example App Service Basic-tier compute. Retrying will NOT help. Fixes:
  • Deploy to a region where the SKU has quota (fastest), e.g.:
        ./scripts/deploy.ps1 -ResourceGroup $ResourceGroup -Location northeurope
  • Or request a quota increase: https://aka.ms/antquotahelp
Run ./scripts/preflight-check.ps1 -Location <region> to find a region with quota.

Failed operation details:
$failMessages
"@
  }

  # Not a capacity/quota problem — surface the real error and stop.
  throw "Deployment '$deploymentName' failed. Failed operation details:`n$failMessages"
}

Write-Step "Capturing deployment outputs"
$outputsJson = az deployment group show -g $ResourceGroup -n $deploymentName --query properties.outputs -o json
$outputs = $outputsJson | ConvertFrom-Json

$webAppName       = $outputs.webAppName.value
$webAppHost       = $outputs.webAppDefaultHost.value
$aksName          = $outputs.aksName.value
$grafanaEndpoint  = $outputs.grafanaEndpoint.value
$workbookId       = $outputs.workbookId.value
$centralLawName   = $outputs.centralLawName.value
$linuxVm          = $outputs.linuxVmNameOut.value
$winVm            = $outputs.windowsVmNameOut.value

# 2b. Subscription-level Activity Log -> central LAW.
#     Subscription-scope diagnostic settings cannot be deployed from RG-scope Bicep,
#     so we manage this small piece via CLI. Idempotent (create-or-update by name).
#     Without this, AzureActivity is empty in the lab LAW and scenario 43's Sentinel
#     rule has no data to fire on — see scenario 43.
#
#     Note: we use `az monitor log-analytics workspace show` (which pins a known-good
#     API version) instead of `az resource show`. `az resource show` dynamically picks
#     the highest API version the CLI knows about, which in newer CLI builds (2.85+)
#     can be a future version that hasn't shipped to all regions yet (e.g. '2026-03-01'
#     returning NoRegisteredProviderFound in swedencentral).
Write-Step "Ensuring subscription Activity Log ships to law-amlab-central (scenario 43 prereq)"
& (Join-Path $PSScriptRoot 'setup-activity-log.ps1') `
  -SubscriptionId $active.id `
  -ResourceGroup $ResourceGroup `
  -WorkspaceName $centralLawName

Write-Host ""
Write-Host "Deployment outputs:" -ForegroundColor Green
Write-Host "  Web App        : https://$webAppHost"
Write-Host "  AKS            : $aksName"
Write-Host "  Grafana        : $grafanaEndpoint"
Write-Host "  Workbook id    : $workbookId"
Write-Host "  Linux VM       : $linuxVm"
Write-Host "  Windows VM     : $winVm"

# 3. Post-deploy
$postDeploy = Join-Path $PSScriptRoot 'post-deploy.ps1'
& $postDeploy -SubscriptionId $active.id -TenantId $active.tenantId -ResourceGroup $ResourceGroup -WebAppName $webAppName -AksName $aksName -WebAppHost $webAppHost -CentralLawName $centralLawName -ConsoleOperatorObjectIds $ConsoleOperatorObjectIds

# 4. Service Group (tenant-scoped, preview) + service group member relationship.
#    Required before SLIs can be attached as extensions on the group.
Write-Step "Provisioning service group + RG member (scenario 45 prerequisite)"
$setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
& $setupHm -ResourceGroup $ResourceGroup

# 5. Verify the portal-created SLI prerequisites and source metrics (scenario 46).
Write-Step "Verifying demo SLI prerequisites and source metrics (scenario 46)"
$setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
& $setupSli -SubscriptionId $active.id -ResourceGroup $ResourceGroup

# 6. Optional SRE Agent stage. Bicep creates the agent and Azure Monitor connectors;
#    this verifies the deployed resource and prints the portal URL.
$sreAgentEnabled = $false
if ($null -ne $labCfg -and $null -ne $labCfg.stageToggles -and $null -ne $labCfg.stageToggles.enableStageSreAgent) {
  $sreAgentEnabled = [bool]$labCfg.stageToggles.enableStageSreAgent
}
if ($sreAgentEnabled) {
  Write-Step "SRE Agent stage enabled - verifying the deployed agent and Azure Monitor connectors"
  $setupSreAgent = Join-Path $PSScriptRoot 'setup-sre-agent.ps1'
  & $setupSreAgent -SubscriptionId $active.id -ResourceGroup $ResourceGroup
}

# 7. Optional Azure Copilot Observability Agent. Bicep creates the agent, its
#    dedicated Azure Monitor workspace, monitored Application Insights child,
#    and least-privilege role assignments; this verifies the deployed contract.
$observabilityAgentEnabled = $false
if ($null -ne $labCfg -and $null -ne $labCfg.stageToggles -and $null -ne $labCfg.stageToggles.enableStageObservabilityAgent) {
  $observabilityAgentEnabled = [bool]$labCfg.stageToggles.enableStageObservabilityAgent
}
if ($observabilityAgentEnabled) {
  Write-Step "Observability Agent stage enabled - verifying resource, scope, operations, and RBAC"
  $setupObservabilityAgent = Join-Path $PSScriptRoot 'setup-observability-agent.ps1'
  & $setupObservabilityAgent -SubscriptionId $active.id -ResourceGroup $ResourceGroup
}

# 8. Optional AI feature - create the demo agents + simulate GenAI traffic, but only
#    when lab.config.json enabled it (stageToggles.enableStageAI -> Bicep enableAi).
$aiEnabled = $false
$aiTrafficStarted = $false
if ($null -ne $labCfg -and $null -ne $labCfg.stageToggles -and $null -ne $labCfg.stageToggles.enableStageAI) {
  $aiEnabled = [bool]$labCfg.stageToggles.enableStageAI
}
if ($aiEnabled) {
  Write-Step "AI feature enabled - preparing agents and starting background traffic"
  $setupAi = Join-Path $PSScriptRoot 'setup-ai.ps1'
  try {
    & $setupAi -ResourceGroup $ResourceGroup -SubscriptionId $active.id -TenantId $active.tenantId -BackgroundTraffic
    $aiTrafficStarted = $true
  } catch {
    Write-Host "  Optional AI traffic could not start: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host '  Console agent provisioning completed earlier. This warning concerns optional demo traffic.' -ForegroundColor Yellow
  }
}

$completionMessage = 'Lab setup complete.'
if ($aiTrafficStarted) { $completionMessage += ' Agent traffic started in the background.' }
Write-Host "`n$completionMessage" -ForegroundColor Green
