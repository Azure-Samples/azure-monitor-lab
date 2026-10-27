<#
.SYNOPSIS
  Provision the optional AI demo from Azure Cloud Shell.

.DESCRIPTION
  Pins and verifies the selected subscription, discovers the Microsoft Foundry
  project and Application Insights through core ARM commands, then invokes the
  existing setup-ai.ps1 with the verified subscription and tenant, without
  requiring optional Azure CLI extensions. Traffic runs in the background unless skipped.

.EXAMPLE
  ./scripts/setup-ai-cloud-shell.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [ValidateRange(1, 2147483647)] [int] $Conversations = 150,
  [switch] $SkipTraffic
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if ([string]::IsNullOrWhiteSpace($NamePrefix)) { $NamePrefix = 'amlab' }

Write-Step "Pinning the Azure subscription"
az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'The AI setup subscription could not be selected.' }
$active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
$verifiedTenantId = [guid]::Empty
if ($LASTEXITCODE -ne 0 -or $active.id -ne $SubscriptionId -or
    -not [guid]::TryParse([string]$active.tenantId, [ref]$verifiedTenantId) -or $verifiedTenantId -eq [guid]::Empty) {
  throw 'The AI setup subscription and tenant could not be verified.'
}

Write-Step "Discovering Microsoft Foundry through ARM"
$accounts = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.CognitiveServices/accounts `
  -o json | ConvertFrom-Json
$account = @($accounts | Where-Object {
  $_.kind -eq 'AIServices' -and $_.name -like "ai$NamePrefix*"
}) | Select-Object -First 1
if (-not $account) {
  $account = @($accounts | Where-Object { $_.kind -eq 'AIServices' }) | Select-Object -First 1
}
if (-not $account) {
  throw "No Microsoft Foundry AIServices account was found in '$ResourceGroup'."
}

$projectEndpoint = "https://$($account.name).services.ai.azure.com/api/projects/$NamePrefix-ai-proj"
Write-Info "Account: $($account.name)"
Write-Info "Project endpoint: $projectEndpoint"

Write-Step "Resolving Application Insights through ARM"
$appInsights = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Insights/components `
  --query "[?starts_with(name, 'appi-$NamePrefix-')] | sort_by(@, &name) | [0].{id:id,name:name}" `
  -o json | ConvertFrom-Json
if (-not $appInsights) {
  throw "Application Insights 'appi-$NamePrefix-<suffix>' was not found in '$ResourceGroup'."
}

$appInsightsConnectionString = az resource show `
  --subscription $SubscriptionId `
  --ids $appInsights.id `
  --api-version 2020-02-02 `
  --query properties.ConnectionString `
  -o tsv
if ([string]::IsNullOrWhiteSpace($appInsightsConnectionString)) {
  throw "Application Insights connection string lookup returned no value."
}

Write-Step "Running AI agent and traffic setup"
$setupAiParameters = @{
  SubscriptionId = $active.id
  TenantId = $verifiedTenantId
  ResourceGroup = $ResourceGroup
  NamePrefix = $NamePrefix
  ProjectEndpoint = $projectEndpoint
  AppInsightsConnectionString = $appInsightsConnectionString
  Conversations = $Conversations
}
if ($SkipTraffic) {
  $setupAiParameters.SkipTraffic = $true
}
& (Join-Path $PSScriptRoot 'setup-ai.ps1') @setupAiParameters