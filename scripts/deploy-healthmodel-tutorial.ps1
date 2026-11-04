<#
.SYNOPSIS
  Deploy the Lab Café workload for the health model tutorial.

.DESCRIPTION
  Creates the resource group, deploys infra/healthmodel-tutorial/workload.bicep
  (App Service, storage, Application Insights, availability tests) and publishes
  workloads/cafe to the web app. Takes about 5 minutes.

  Next step: ./scripts/build-healthmodel-tutorial.ps1
  Walkthrough: docs/HEALTH-MODEL-TUTORIAL.md

.PARAMETER ResourceGroup
  Resource group for the tutorial. Created if it doesn't exist.

.PARAMETER Location
  Region for the workload. Defaults to swedencentral.

.PARAMETER SubscriptionId
  Subscription to deploy into. Defaults to .azure-target.json, then the active az subscription.
  When .azure-target.json exists, any other subscription or tenant is blocked.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-healthmodel-tutorial',
  [string] $Location = 'swedencentral',
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Assert-NativeCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
$target = if (Test-Path $targetFile) { Get-Content -Raw $targetFile | ConvertFrom-Json } else { $null }
if ($target -and -not $SubscriptionId) { $SubscriptionId = $target.expectedSubscriptionId }
if ($target -and $SubscriptionId -ne $target.expectedSubscriptionId) {
  throw "BLOCKED: -SubscriptionId '$SubscriptionId' does not match .azure-target.json '$($target.expectedSubscriptionId)'."
}
if ($SubscriptionId) {
  az account set --subscription $SubscriptionId | Out-Null
  Assert-NativeCommandSucceeded "Selecting subscription '$SubscriptionId'"
}
$active = az account show --query "{id:id, name:name, tenantId:tenantId}" -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded 'Reading the active Azure subscription'
if ($target -and $active.tenantId -ne $target.expectedTenantId) {
  throw "BLOCKED: active tenant '$($active.tenantId)' does not match .azure-target.json '$($target.expectedTenantId)'."
}
Write-Info "Subscription: $($active.name) ($($active.id))"
Write-Info "Tenant      : $($active.tenantId)"

$repoRoot = Split-Path $PSScriptRoot -Parent
$template = Join-Path $repoRoot 'infra/healthmodel-tutorial/workload.bicep'
$appDir = Join-Path $repoRoot 'workloads/cafe'

Write-Step "Creating resource group $ResourceGroup in $Location"
az group create -n $ResourceGroup -l $Location --tags purpose=health-model-tutorial -o none
Assert-NativeCommandSucceeded 'Creating the resource group'

Write-Step 'Deploying the café workload (App Service, storage, Application Insights)'
$outputs = az deployment group create -g $ResourceGroup -n healthmodel-tutorial-workload `
  --template-file $template --parameters location=$Location `
  --query properties.outputs -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded 'Deploying the workload template'
$webAppName = $outputs.webAppName.value
$webAppUrl = $outputs.webAppUrl.value
Write-Info "Web app: $webAppName"

Write-Step 'Publishing the café app'
$zip = Join-Path ([System.IO.Path]::GetTempPath()) "lab-cafe-$([guid]::NewGuid()).zip"
try {
  Compress-Archive -Path (Join-Path $appDir '*') -DestinationPath $zip
  az webapp deploy -g $ResourceGroup -n $webAppName --src-path $zip --type zip --async false -o none
  Assert-NativeCommandSucceeded 'Publishing the app'
} finally {
  Remove-Item $zip -ErrorAction SilentlyContinue
}

Write-Step 'Waiting for the café to open its doors'
$deadline = (Get-Date).AddMinutes(5)
do {
  try {
    $menu = Invoke-RestMethod -Uri "$webAppUrl/api/menu" -TimeoutSec 30
    break
  } catch {
    # Role assignments for the app's identity can take a minute to apply.
    Write-Info 'Not ready yet, retrying in 15 s...'
    Start-Sleep -Seconds 15
  }
} while ((Get-Date) -lt $deadline)
if (-not $menu) { throw "The café didn't answer on $webAppUrl/api/menu within 5 minutes." }
Write-Info "Menu: $(($menu | ForEach-Object name) -join ', ')"

$order = Invoke-RestMethod -Method Post -Uri "$webAppUrl/api/orders" -ContentType 'application/json' -Body '{"item":"oat-latte"}'
Write-Info "Test order $($order.id): $($order.item), $($order.status)"

Write-Host "`n☕ Lab Café is open at $webAppUrl" -ForegroundColor Green
Write-Host '   Synthetic customers browse and order every 5 minutes from now on.'
Write-Host '   Next: design the model yourself, docs/HEALTH-MODEL-TUTORIAL.md section 3'
