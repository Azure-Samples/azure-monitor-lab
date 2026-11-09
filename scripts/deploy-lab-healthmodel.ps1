<#
.SYNOPSIS
  Deploy the lab's user-flow health model hm-amlab-flows.

.DESCRIPTION
  Finds the lab resources in the resource group and deploys
  infra/healthmodel-lab/main.bicep next to the resource-tier demo model
  hm-amlab-workload, which stays unchanged.
  Plan: docs/healthmodel/lab/plan.md. Needs a deployed lab (scripts/deploy.ps1).

.PARAMETER ResourceGroup
  Lab resource group. Defaults to lab.config.json, then rg-azure-monitor-lab.

.PARAMETER Location
  Region for the health model. Defaults to the resource group's region.

.PARAMETER WhatIf
  Show the change without deploying.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup,
  [string] $Location,
  [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Assert-NativeCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

$repoRoot = Split-Path $PSScriptRoot -Parent

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $repoRoot '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription ($($target.expectedSubscriptionId)). Aborting."
  }
}

$labConfig = Join-Path $repoRoot 'lab.config.json'
$config = if (Test-Path $labConfig) { Get-Content -Raw $labConfig | ConvertFrom-Json } else { $null }
if (-not $ResourceGroup) { $ResourceGroup = $config.resourceGroup ?? 'rg-azure-monitor-lab' }
$prefix = $config.namePrefix ?? 'amlab'
if (-not $Location) {
  $Location = az group show -n $ResourceGroup --query location -o tsv
  Assert-NativeCommandSucceeded "Reading resource group '$ResourceGroup'"
}

Write-Step "Finding lab resources in $ResourceGroup"
# $Where is a JMESPath condition on the resource name.
function Get-LabResourceId([string] $Type, [string] $Where) {
  $ids = @(az resource list -g $ResourceGroup --resource-type $Type --query "[?$Where].id" -o tsv)
  Assert-NativeCommandSucceeded "Listing $Type"
  if ($ids.Count -ne 1 -or -not $ids[0]) { throw "Expected one $Type where $Where in $ResourceGroup, found $($ids.Count)." }
  Write-Info $ids[0].Split('/')[-1]
  $ids[0]
}

$parameters = @{
  location               = @{ value = $Location }
  webAppId               = @{ value = Get-LabResourceId 'Microsoft.Web/sites' "starts_with(name, 'app-$prefix')" }
  appInsightsWorkspaceId = @{ value = Get-LabResourceId 'Microsoft.OperationalInsights/workspaces' "starts_with(name, 'law-$prefix-appinsights')" }
  centralWorkspaceId     = @{ value = Get-LabResourceId 'Microsoft.OperationalInsights/workspaces' "starts_with(name, 'law-$prefix-central')" }
  monitorWorkspaceId     = @{ value = Get-LabResourceId 'Microsoft.Monitor/accounts' "name == 'amw-$prefix'" }
  aksId                  = @{ value = Get-LabResourceId 'Microsoft.ContainerService/managedClusters' "contains(name, '$prefix')" }
  vmssId                 = @{ value = Get-LabResourceId 'Microsoft.Compute/virtualMachineScaleSets' "contains(name, '$prefix')" }
  # One-shot deployment names it avail-<prefix>-appservice, the staged guide test-<prefix>-app.
  availabilityTestName   = @{ value = (Get-LabResourceId 'Microsoft.Insights/webtests' "name == 'avail-$prefix-appservice' || name == 'test-$prefix-app'").Split('/')[-1] }
  actionGroupId          = @{ value = az monitor action-group list -g $ResourceGroup --query "[?ends_with(name, '-email')] | [0].id" -o tsv }
  vmIds                  = @{ value = @(az vm list -g $ResourceGroup --query '[].id' -o tsv) }
}
Assert-NativeCommandSucceeded 'Listing VMs'
if (-not $parameters.actionGroupId.value) { throw "No lab action group (*-email) found in $ResourceGroup." }
Write-Info $parameters.actionGroupId.value.Split('/')[-1]
Write-Info "$($parameters.vmIds.value.Count) VM(s)"

$parametersFile = Join-Path ([System.IO.Path]::GetTempPath()) "hm-amlab-flows-$([guid]::NewGuid()).json"
@{
  '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  contentVersion = '1.0.0.0'
  parameters     = $parameters
} | ConvertTo-Json -Depth 6 | Set-Content -Path $parametersFile -Encoding utf8

try {
  $template = Join-Path $repoRoot 'infra/healthmodel-lab/main.bicep'
  $verb = if ($WhatIf) { 'what-if' } else { 'create' }
  $output = if ($WhatIf) { @() } else { @('-o', 'none') }
  Write-Step "Deployment $verb of hm-amlab-flows in $Location"
  az deployment group $verb -g $ResourceGroup -n hm-amlab-flows --template-file $template --parameters "@$parametersFile" @output
  Assert-NativeCommandSucceeded "Deployment $verb"
} finally {
  Remove-Item $parametersFile -ErrorAction SilentlyContinue
}

if (-not $WhatIf) {
  Write-Host "`n🩺 hm-amlab-flows is live. Log signals need about 10 minutes for the model's roles to apply." -ForegroundColor Green
  Write-Host "   az monitor health-models entity list -g $ResourceGroup --health-model-name hm-amlab-flows --query `"[].{entity:name, state:properties.healthState}`" -o table"
}
