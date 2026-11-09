<#
.SYNOPSIS
  Publish the optional Health Model Demo workload and connect its existing models.
.DESCRIPTION
  Run after stage infrastructure deployment. Does not recreate models, replace
  entities, change RBAC or run intentional failures. Safe to rerun after editing
  a model in the portal. A publication restart can temporarily affect health.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [ValidateRange(1, 1800)] [int] $VerificationTimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
function Assert-DemoCommand([string] $Operation) {
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with Azure CLI exit $LASTEXITCODE." }
}
$account = az account show --subscription $SubscriptionId --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
Assert-DemoCommand 'Verify the selected subscription'
if ($account.id -ine $SubscriptionId) { throw 'Health Model Demo subscription mismatch.' }
$guard = Join-Path $PSScriptRoot '..\.azure-target.json'
if (Test-Path -LiteralPath $guard) {
  $target = Get-Content -LiteralPath $guard -Raw | ConvertFrom-Json
  if ($target.expectedSubscriptionId -ine $account.id -or $target.expectedTenantId -ine $account.tenantId) {
    throw 'BLOCKED: Health Model Demo target differs from .azure-target.json.'
  }
}
$resources = @(az resource list --subscription $SubscriptionId -g $ResourceGroup -o json | ConvertFrom-Json)
Assert-DemoCommand 'Discover Health Model Demo resources'
$cafe = @($resources | Where-Object { $_.type -ieq 'Microsoft.Web/sites' -and $_.name -match '^app-cafe-[a-z0-9]{13}$' })
$console = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.Web/sites' -and $_.name -like "app-$NamePrefix-*" -and
  $_.name -notmatch '-customer$' -and $_.name -notin $cafe.name
})
$workspace = @($resources | Where-Object {
  $_.type -ieq 'Microsoft.OperationalInsights/workspaces' -and $_.name -like 'law-cafe-*'
})
if ($cafe.Count -ne 1 -or $console.Count -ne 1 -or $workspace.Count -ne 1) {
  throw "Expected one Café app, console app and Café workspace; found $($cafe.Count), $($console.Count), $($workspace.Count). Deploy the Health Model Demo infrastructure first."
}
foreach ($name in @('hm-amlab-flows', 'hm-lab-cafe')) {
  $models = @($resources | Where-Object { $_.type -ieq 'Microsoft.CloudHealth/healthmodels' -and $_.name -ceq $name })
  if ($models.Count -ne 1) { throw "Required model '$name' is not deployed in '$ResourceGroup'." }
  $state = az resource show --subscription $SubscriptionId --ids $models[0].id --api-version 2026-11-01 --query properties.provisioningState -o tsv
  Assert-DemoCommand "Verify model '$name'"
  if ($state -ne 'Succeeded') { throw "Model '$name' is not ready (provisioning state: '$state')." }
}
Write-Host 'Publishing the Health Model Demo Café.' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'publish-healthmodel-cafe.ps1') `
  -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -WebAppName $cafe[0].name

az webapp config appsettings set --subscription $SubscriptionId -g $ResourceGroup -n $console[0].name --settings `
  'LabConsole__HealthModels__0__Name=hm-amlab-flows' `
  "LabConsole__HealthModels__0__ResourceGroup=$ResourceGroup" `
  'LabConsole__HealthModels__0__DefaultEntity=shop-demo' `
  'LabConsole__HealthModels__0__DisplayName=Lab user flows' `
  'LabConsole__HealthModels__1__Name=hm-lab-cafe' `
  "LabConsole__HealthModels__1__ResourceGroup=$ResourceGroup" `
  'LabConsole__HealthModels__1__DefaultEntity=order-coffee' `
  'LabConsole__HealthModels__1__DisplayName=Café tutorial' -o none
Assert-DemoCommand 'Configure Control Center model targets'

$url = "https://$($cafe[0].name).azurewebsites.net"
$verificationStarted = [DateTimeOffset]::UtcNow
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
$ready = $false
do {
  try {
    $menu = Invoke-RestMethod -Uri "$url/api/menu" -TimeoutSec 30
    if ($menu.Count -lt 1 -or $menu[0].id -isnot [string] -or [string]::IsNullOrWhiteSpace($menu[0].id)) { throw 'The Café menu contains no orderable items.' }
    $ready = $true
  } catch {
    Write-Warning "Café is not ready: $($_.Exception.Message)"
    if ([DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Seconds 15 }
  }
} while (-not $ready -and [DateTimeOffset]::UtcNow -lt $deadline)
if (-not $ready) { throw "Café did not become ready at $url." }
$body = @{ item = $menu[0].id } | ConvertTo-Json
$order = Invoke-RestMethod -Method Post -Uri "$url/api/orders" -ContentType 'application/json' -Body $body -TimeoutSec 30
if (-not $order.id) { throw 'Café order response did not contain an ID.' }
$stored = Invoke-RestMethod -Uri "$url/api/orders/$($order.id)" -TimeoutSec 30
if ($stored.id -cne $order.id) { throw 'Café stored-order verification failed.' }

$customerId = az resource show --ids $workspace[0].id --api-version 2023-09-01 --query properties.customerId -o tsv
Assert-DemoCommand 'Resolve Café workspace'
$token = az account get-access-token --subscription $SubscriptionId --resource https://api.loganalytics.io -o json | ConvertFrom-Json
Assert-DemoCommand 'Acquire Café telemetry query token'
$query = @{
  query = "union withsource=Source AppRequests, AppDependencies | where TimeGenerated >= datetime($($verificationStarted.ToString('o'))) | summarize Records=count() by Source"
  timespan = 'PT15M'
} | ConvertTo-Json
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
$ingested = $false
do {
  $result = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$customerId/query" `
    -Headers @{ Authorization = "Bearer $($token.accessToken)" } -ContentType 'application/json' -Body $query -TimeoutSec 60
  if ($result.error -or @($result.tables).Count -ne 1 -or
      (@($result.tables[0].columns.name) -join ',') -cne 'Source,Records') {
    throw 'Café telemetry query returned an error or unexpected result shape.'
  }
  $sources = @($result.tables[0].rows | Where-Object { $_[1] -gt 0 } | ForEach-Object { $_[0] })
  $ingested = 'AppRequests' -in $sources -and 'AppDependencies' -in $sources
  if (-not $ingested -and [DateTimeOffset]::UtcNow -lt $deadline) {
    Write-Host 'Waiting for actual Café request and dependency telemetry.'
    Start-Sleep -Seconds 30
  }
} while (-not $ingested -and [DateTimeOffset]::UtcNow -lt $deadline)
if (-not $ingested) { throw 'Café request/dependency telemetry did not arrive; a zero-failure signal is not proof of ingestion.' }
Write-Host "Health Model Demo ready: $url (menu, stored order and telemetry verified)." -ForegroundColor Green
