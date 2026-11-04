<#
.SYNOPSIS
  Break (and fix) Lab Café on purpose so the health model has something to show.

.DESCRIPTION
  Scenarios, matching "What happens when something breaks" in docs/healthmodel/plan.md:

    NetworkCut       the web app loses its private path to storage -> both flows Unhealthy
    BaristaQueue     the barista queue is deleted           -> Order coffee only Degraded (limited impact)
    BadRelease       every order fails with HTTP 500        -> Order coffee Unhealthy, browsing stays Healthy

  After breaking, a few customers visit the café so failures show up within minutes,
  instead of waiting for the next synthetic customer. Use -Restore to fix it again.

.PARAMETER Scenario
  Which failure to inject or restore.

.PARAMETER Restore
  Undo the scenario.

.PARAMETER ResourceGroup
  Resource group of the café workload.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [ValidateSet('NetworkCut', 'BaristaQueue', 'BadRelease')] [string] $Scenario,
  [switch] $Restore,
  [string] $ResourceGroup = 'rg-healthmodel-tutorial',
  [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Magenta }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

function Assert-NativeCommandSucceeded([string] $Operation) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with exit code $LASTEXITCODE."
  }
}

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (-not $SubscriptionId -and (Test-Path $targetFile)) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  $SubscriptionId = $target.expectedSubscriptionId
}
if ($SubscriptionId) {
  az account set --subscription $SubscriptionId | Out-Null
  Assert-NativeCommandSucceeded "Selecting subscription '$SubscriptionId'"
}

$workload = az deployment group show -g $ResourceGroup -n healthmodel-tutorial-workload `
  --query properties.outputs -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded 'Reading the workload deployment'
$webAppName = $workload.webAppName.value
$webAppUrl = $workload.webAppUrl.value
$queueUrl = "https://management.azure.com$($workload.storageAccountId.value)/queueServices/default/queues/order-events?api-version=2023-05-01"

switch ($Scenario) {
  'NetworkCut' {
    if ($Restore) {
      Write-Step 'Reconnecting the web app to the VNet (redeploying the workload template)'
      $template = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra/healthmodel-tutorial/workload.bicep'
      $location = az group show -n $ResourceGroup --query location -o tsv
      az deployment group create -g $ResourceGroup -n healthmodel-tutorial-workload `
        --template-file $template --parameters location=$location -o none
    } else {
      Write-Step 'Removing the VNet integration (storage only accepts private traffic)'
      az webapp vnet-integration remove -g $ResourceGroup -n $webAppName -o none
    }
    Assert-NativeCommandSucceeded 'Changing the VNet integration'
  }
  'BaristaQueue' {
    if ($Restore) {
      Write-Step 'Recreating the order-events queue'
      az rest --method put --url $queueUrl --body '{}' -o none
    } else {
      Write-Step 'Deleting the order-events queue (the barista display goes dark)'
      az rest --method delete --url $queueUrl -o none
    }
    Assert-NativeCommandSucceeded 'Changing the order-events queue'
  }
  'BadRelease' {
    $percent = if ($Restore) { 0 } else { 100 }
    Write-Step "Order failure rate -> $percent%"
    az webapp config appsettings set -g $ResourceGroup -n $webAppName --settings "CHAOS_ORDER_FAILURE_PERCENT=$percent" -o none
    Assert-NativeCommandSucceeded 'Updating the app setting'
    # A settings change doesn't always recycle the running process right away.
    az webapp restart -g $ResourceGroup -n $webAppName -o none
    Assert-NativeCommandSucceeded 'Restarting the web app'
    $expected = if ($Restore) { 201 } else { 500 }
    $deadline = (Get-Date).AddMinutes(3)
    do {
      Start-Sleep -Seconds 10
      $status = (Invoke-WebRequest -Method Post -Uri "$webAppUrl/api/orders" -Body '{"item":"espresso"}' `
          -ContentType 'application/json' -TimeoutSec 30 -SkipHttpErrorCheck).StatusCode
      Write-Info "Order answered $status"
    } while ($status -ne $expected -and (Get-Date) -lt $deadline)
  }
}

Write-Step 'A few customers drop by'
$results = foreach ($i in 1..10) {
  foreach ($call in @(
      @{ Method = 'Get'; Uri = "$webAppUrl/api/menu" }
      @{ Method = 'Post'; Uri = "$webAppUrl/api/orders"; Body = '{"item":"espresso"}'; ContentType = 'application/json' }
    )) {
    try {
      Invoke-WebRequest @call -TimeoutSec 30 -SkipHttpErrorCheck | ForEach-Object { "$($call.Method) $($_.StatusCode)" }
    } catch {
      "$($call.Method) error"
    }
  }
}
$results | Group-Object | ForEach-Object { Write-Info "$($_.Name): $($_.Count)x" }

# Longest signal window that sees the failure: the synthetic customers look back 15 minutes.
$recoveryMinutes = @{ BaristaQueue = 5; BadRelease = 15; NetworkCut = 15 }[$Scenario]
$hint = if ($Restore) { "Green again within about $recoveryMinutes minutes, once old failures leave the signal windows." } else { 'Failures show within about 5 minutes.' }
$verb = if ($Restore) { 'restored' } else { 'broken' }
Write-Host "`n$Scenario $verb. $hint Check with:" -ForegroundColor Green
Write-Host "   az monitor health-models entity list -g $ResourceGroup --health-model-name hm-lab-cafe -o table"
