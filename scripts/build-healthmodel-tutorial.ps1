<#
.SYNOPSIS
  Build the Lab Café health model with the az monitor health-models CLI.

.DESCRIPTION
  Implements docs/healthmodel/cafe/plan.md as three layers:

    Lab Café (root)
    ├─ Browse the menu        user flow
    │  ├─ Café website        system component -> App Service: <app> (menu)
    │  └─ Menu catalog        system component -> Storage: <account> (menu blob)
    └─ Order coffee           user flow
       ├─ Order API           system component -> App Service: <app> (orders)
       ├─ Order store         system component -> Storage: <account> (order blobs)
       └─ Barista display     system component, limited impact -> Storage: <account> (order queue)

  Every command is a create-or-replace, so the script is safe to run again.
  Run scripts/deploy-healthmodel-tutorial.ps1 first.

.PARAMETER ResourceGroup
  Resource group that holds the café workload. The model is created there as well.

.PARAMETER HealthModelName
  Name of the health model, also the name of its root entity.

.PARAMETER Location
  Region for the health model: az provider show -n Microsoft.CloudHealth lists them.

.PARAMETER ActionGroupId
  Optional action group notified by the user flow alerts. Without it, alerts fire in
  Azure Monitor but notify nobody.

.PARAMETER SubscriptionId
  Subscription to deploy into. Defaults to .azure-target.json, then the active az subscription.
  When .azure-target.json exists, any other subscription or tenant is blocked.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-healthmodel-tutorial',
  [string] $HealthModelName = 'hm-lab-cafe',
  [string] $Location = 'swedencentral',
  [string] $ActionGroupId,
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

# --- Workload facts from the deploy step ---------------------------------------
$workload = az deployment group show -g $ResourceGroup -n healthmodel-tutorial-workload `
  --query properties.outputs -o json | ConvertFrom-Json
Assert-NativeCommandSucceeded 'Reading the workload deployment (run deploy-healthmodel-tutorial.ps1 first)'
$webAppId = $workload.webAppId.value
$webAppName = $workload.webAppName.value
$storageId = $workload.storageAccountId.value
$storageName = $workload.storageAccountName.value
$workspaceId = $workload.logAnalyticsWorkspaceId.value
$auth = 'auth-system'

# --- Model data ------------------------------------------------------------------
# Thresholds marked (assumed) in docs/healthmodel/cafe/plan.md: common starting values to tune after a week.

function New-Rules([string] $Operator, [double] $Degraded, [double] $Unhealthy) {
  @{
    'degraded-rule'  = @{ operator = $Operator; threshold = $Degraded }
    'unhealthy-rule' = @{ operator = $Operator; threshold = $Unhealthy }
  }
}

# Reusable metric signals: each is used by more than one resource entity.
$signalDefinitions = @(
  @{
    name = 'sd-app-health-check'; displayName = 'Web app health check'; dataUnit = 'Percent'
    metric = @{ 'metric-namespace' = 'Microsoft.Web/sites'; 'metric-name' = 'HealthCheckStatus'; 'aggregation-type' = 'Average'; 'time-grain' = 'PT5M' }
    rules = New-Rules 'LessThan' 100 50
  }
  @{
    name = 'sd-storage-availability'; displayName = 'Storage availability'; dataUnit = 'Percent'
    metric = @{ 'metric-namespace' = 'Microsoft.Storage/storageAccounts'; 'metric-name' = 'Availability'; 'aggregation-type' = 'Average'; 'time-grain' = 'PT5M' }
    rules = New-Rules 'LessThan' 99.9 99
  }
)

function New-LogSignal([string] $Name, [string] $DisplayName, [string] $Query, [string] $Unit, [string] $Window, $Rules) {
  @{
    name = $Name; 'display-name' = $DisplayName; 'query-text' = $Query; 'value-column-name' = 'value'
    'time-grain' = $Window; 'refresh-interval' = 'PT1M'; 'data-unit' = $Unit; 'evaluation-rules' = $Rules
  }
}

$failureRules = New-Rules 'GreaterThan' 0 2

$entities = @(
  # Layer 1: user flows (virtual, no signals of their own)
  @{
    name = 'browse-menu'; displayName = 'Browse the menu'; icon = 'UserFlow'; objective = 99.5
    alerts = @{ unhealthy = @{ severity = 'Sev2'; description = 'Customers cannot see the café menu' } }
  }
  @{
    name = 'order-coffee'; displayName = 'Order coffee'; icon = 'UserFlow'; objective = 99.9
    alerts = @{
      degraded  = @{ severity = 'Sev3'; description = 'Ordering coffee is slow or partly failing' }
      unhealthy = @{ severity = 'Sev1'; description = 'Customers cannot order coffee' }
    }
  }

  # Layer 2: system components, measuring what users experience
  @{
    name = 'cafe-website'; displayName = 'Café website'; icon = 'SystemComponent'
    logSignals = @(
      New-LogSignal 'failed-menu-requests' 'Failed menu requests' @'
AppRequests
| extend path = tostring(parse_url(Url).Path)
| where path in ("", "/", "/api/menu")  // the root URL has an empty path
| summarize value = countif(Success == false)
'@ 'Count' 'PT5M' $failureRules
      New-LogSignal 'synthetic-browse-failures' 'Synthetic customer cannot open the menu' @'
AppAvailabilityResults
| where Name == "synthetic-browse-menu"
| summarize value = countif(Success == false)
'@ 'Count' 'PT15M' $failureRules
    )
  }
  @{
    name = 'menu-catalog'; displayName = 'Menu catalog'; icon = 'SystemComponent'
    logSignals = @(
      New-LogSignal 'failed-menu-reads' 'Failed menu reads from storage' @'
AppDependencies
| where Target has "blob.core.windows.net" and Data has "/menu/"
| summarize value = countif(Success == false)
'@ 'Count' 'PT5M' $failureRules
    )
  }
  @{
    name = 'order-api'; displayName = 'Order API'; icon = 'SystemComponent'
    logSignals = @(
      New-LogSignal 'failed-order-requests' 'Failed order requests' @'
AppRequests
| where Url has "/api/orders"
| summarize value = countif(ResultCode startswith "5")  // a 404 for a mistyped order ID is not an outage
'@ 'Count' 'PT5M' $failureRules
      New-LogSignal 'slow-orders' 'Order time for most customers (p95)' @'
AppRequests
| where Url has "/api/orders"
| summarize p95 = percentile(DurationMs, 95)
| project value = coalesce(p95, 0.0)
'@ 'MilliSeconds' 'PT15M' (New-Rules 'GreaterThan' 1000 3000)
      New-LogSignal 'synthetic-order-failures' 'Synthetic customer cannot order' @'
AppAvailabilityResults
| where Name == "synthetic-order-coffee"
| summarize value = countif(Success == false)
'@ 'Count' 'PT15M' $failureRules
    )
  }
  @{
    name = 'order-store'; displayName = 'Order store'; icon = 'SystemComponent'
    logSignals = @(
      New-LogSignal 'failed-order-writes' 'Failed order storage calls' @'
AppDependencies
| where Target has "blob.core.windows.net" and Data has "/orders/"
| summarize value = countif(Success == false and ResultCode != "404")  // 404: looked-up order doesn't exist
'@ 'Count' 'PT5M' $failureRules
    )
  }
  @{
    name = 'barista-display'; displayName = 'Barista display (optional)'; icon = 'SystemComponent'; impact = 'Limited'
    logSignals = @(
      New-LogSignal 'failed-barista-notifications' 'Orders the barista display missed' @'
AppDependencies
| where Target has "queue.core.windows.net"
| summarize value = countif(Success == false)
'@ 'Count' 'PT5M' $failureRules
    )
  }

  # Layer 3: Azure resources, one copy per component so each flow keeps its own view
  @{ name = 'menu-app'; displayName = "App Service: $webAppName (menu)"; resourceId = $webAppId; definitions = @('sd-app-health-check') }
  @{ name = 'menu-storage'; displayName = "Storage: $storageName (menu blob)"; resourceId = $storageId; definitions = @('sd-storage-availability') }
  @{ name = 'order-app'; displayName = "App Service: $webAppName (orders)"; resourceId = $webAppId; definitions = @('sd-app-health-check') }
  @{ name = 'order-storage'; displayName = "Storage: $storageName (order blobs)"; resourceId = $storageId; definitions = @('sd-storage-availability') }
  @{ name = 'queue-storage'; displayName = "Storage: $storageName (order queue)"; resourceId = $storageId; definitions = @('sd-storage-availability') }
)

# Child rolls up into parent. The root entity is named like the model.
$relationships = @(
  @{ parent = $HealthModelName; child = 'browse-menu' }
  @{ parent = $HealthModelName; child = 'order-coffee' }
  @{ parent = 'browse-menu'; child = 'cafe-website' }
  @{ parent = 'browse-menu'; child = 'menu-catalog' }
  @{ parent = 'cafe-website'; child = 'menu-app' }
  @{ parent = 'menu-catalog'; child = 'menu-storage' }
  @{ parent = 'order-coffee'; child = 'order-api' }
  @{ parent = 'order-coffee'; child = 'order-store' }
  @{ parent = 'order-coffee'; child = 'barista-display' }
  @{ parent = 'order-api'; child = 'order-app' }
  @{ parent = 'order-store'; child = 'order-storage' }
  @{ parent = 'barista-display'; child = 'queue-storage' }
)

# --- Calculations: turn model data into CLI JSON ---------------------------------

function Get-SignalGroups($Entity) {
  $groups = @{}
  if ($Entity.logSignals) {
    $groups['azure-log-analytics'] = @{
      'authentication-setting' = $auth; 'log-analytics-workspace-resource-id' = $workspaceId; signals = @($Entity.logSignals)
    }
  }
  if ($Entity.resourceId) {
    $groups['azure-resource'] = @{
      'authentication-setting' = $auth; 'azure-resource-id' = $Entity.resourceId
      signals = @($Entity.definitions | ForEach-Object { @{ name = $_.Substring(3); 'signal-definition-name' = $_ } })
    }
  }
  $groups
}

function Get-Alerts($Entity) {
  $alerts = @{}
  foreach ($state in $Entity.alerts.Keys) {
    $alert = $Entity.alerts[$state].Clone()
    if ($ActionGroupId) { $alert['action-group-ids'] = @($ActionGroupId) }
    $alerts[$state] = $alert
  }
  $alerts
}

# --- Actions ---------------------------------------------------------------------
$jsonDir = Join-Path ([System.IO.Path]::GetTempPath()) "hm-lab-cafe-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $jsonDir | Out-Null
function Write-JsonFile([string] $Name, $Value) {
  $path = Join-Path $jsonDir "$Name.json"
  $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding utf8
  "@$path"
}

$common = @('-g', $ResourceGroup, '--health-model-name', $HealthModelName, '-o', 'none')

try {
  Write-Step '0. Make sure the health model resource provider is registered'
  az provider register --namespace Microsoft.CloudHealth --wait -o none
  Assert-NativeCommandSucceeded 'Registering Microsoft.CloudHealth'

  Write-Step "1. Health model $HealthModelName with a system-assigned identity"
  az monitor health-models create -g $ResourceGroup -n $HealthModelName -l $Location --mi-system-assigned -o none
  Assert-NativeCommandSucceeded 'Creating the health model'

  Write-Step '2. Let the model read metrics and logs (Monitoring Reader on the resource group)'
  $principalId = az monitor health-models show -g $ResourceGroup -n $HealthModelName --query identity.principalId -o tsv
  $rgId = az group show -n $ResourceGroup --query id -o tsv
  Assert-NativeCommandSucceeded 'Reading the model identity and resource group'
  # --assignee-object-id skips the Graph lookup, which fails while a new identity is still replicating.
  $existing = az role assignment list --assignee-object-id $principalId --scope $rgId --role 'Monitoring Reader' --query "length(@)" -o tsv
  Assert-NativeCommandSucceeded 'Listing role assignments of the model identity'
  if ($existing -eq '0') {
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
      --role 'Monitoring Reader' --scope $rgId -o none
    Assert-NativeCommandSucceeded 'Granting Monitoring Reader to the model identity'
  }
  Write-Info "Model identity: $principalId"

  Write-Step "3. Authentication setting '$auth'"
  az monitor health-models authentication-setting create @common -n $auth `
    --display-name 'System-assigned managed identity' --managed-identity managed-identity-name=SystemAssigned
  Assert-NativeCommandSucceeded 'Creating the authentication setting'

  Write-Step '4. Reusable signal definitions'
  foreach ($definition in $signalDefinitions) {
    az monitor health-models signal-definition create @common -n $definition.name `
      --display-name $definition.displayName --refresh-interval PT1M --data-unit $definition.dataUnit `
      --azure-resource-metric (Write-JsonFile $definition.name $definition.metric) `
      --evaluation-rules (Write-JsonFile "$($definition.name)-rules" $definition.rules)
    Assert-NativeCommandSucceeded "Creating signal definition $($definition.name)"
    Write-Info $definition.name
  }

  Write-Step '5. Entities: user flows, system components, Azure resources'
  foreach ($entity in $entities) {
    $entityArgs = @('-n', $entity.name, '--display-name', $entity.displayName, '--impact', ($entity.impact ?? 'Standard'))
    if ($entity.icon) { $entityArgs += @('--icon', "icon-name=$($entity.icon)") }
    if ($entity.objective) { $entityArgs += @('--health-objective', $entity.objective) }
    if ($entity.alerts) { $entityArgs += @('--alerts', (Write-JsonFile "$($entity.name)-alerts" (Get-Alerts $entity))) }
    $groups = Get-SignalGroups $entity
    if ($groups.Count) { $entityArgs += @('--signal-groups', (Write-JsonFile "$($entity.name)-signals" $groups)) }
    az monitor health-models entity create @common @entityArgs
    Assert-NativeCommandSucceeded "Creating entity $($entity.name)"
    Write-Info "$($entity.name): $($entity.displayName)"
  }

  Write-Step '6. Relationships: health flows from child to parent'
  foreach ($edge in $relationships) {
    az monitor health-models relationship create @common -n "$($edge.parent)--$($edge.child)" `
      --parent-entity-name $edge.parent --child-entity-name $edge.child
    Assert-NativeCommandSucceeded "Connecting $($edge.parent) -> $($edge.child)"
    Write-Info "$($edge.parent) -> $($edge.child)"
  }
} finally {
  Remove-Item -Recurse -Force $jsonDir -ErrorAction SilentlyContinue
}

$modelId = az monitor health-models show -g $ResourceGroup -n $HealthModelName --query id -o tsv
Write-Host "`n🩺 Health model $HealthModelName is live." -ForegroundColor Green
Write-Host "   Portal: https://portal.azure.com/#@/resource$modelId"
Write-Host '   Signals start reporting within a few minutes. Watch them with:'
Write-Host "   az monitor health-models entity list -g $ResourceGroup --health-model-name $HealthModelName -o table"
