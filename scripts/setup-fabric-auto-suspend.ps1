<#
.SYNOPSIS
  Configure opt-in daily UTC suspension of the lab Fabric F2 capacity.
.DESCRIPTION
  Uses an Azure Logic App with read/suspend permissions on this capacity only.
  Disabled by default; disabling stops an existing schedule without resuming F2.
  No capacity is suspended or resumed while this script configures the schedule.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [bool] $Enabled = $false,
  [ValidateRange(0, 23)] [int] $HourUtc = 20,
  [ValidateRange(0, 59)] [int] $MinuteUtc = 0
)

$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not select the suspension schedule subscription.' }
$activeId = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or $activeId -ne $SubscriptionId) { throw 'Suspension schedule subscription guardrail failed.' }
$capacities = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
  --resource-type Microsoft.Fabric/capacities --output json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $capacities.Count -ne 1 -or $capacities[0].sku.name -ne 'F2') {
  throw 'Daily suspension requires exactly one F2 capacity in the explicit lab resource group.'
}
$capacity = $capacities[0]
$workflowName = "$($capacity.name)-auto-suspend"
$workflowId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$workflowName"
if (-not $Enabled) {
  $workflows = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
    --resource-type Microsoft.Logic/workflows --output json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Fabric suspension schedules.' }
  if (@($workflows | Where-Object { $_.id -ieq $workflowId }).Count) {
    az resource update --subscription $SubscriptionId --ids $workflowId --api-version 2019-05-01 `
      --set properties.state=Disabled --output none
    if ($LASTEXITCODE -ne 0) { throw 'Could not disable the existing Fabric suspension schedule.' }
  }
  Write-Host 'Fabric auto-suspension: disabled. The capacity state was not changed.'
  return
}

$now = [DateTime]::UtcNow
$firstRun = $now.Date.AddHours($HourUtc).AddMinutes($MinuteUtc)
# Leave time for deployment and RBAC propagation; never run the trigger immediately.
if ($firstRun -le $now.AddMinutes(15)) { $firstRun = $firstRun.AddDays(1) }
$template = Join-Path $PSScriptRoot '..' 'infra' 'modules' 'fabric-auto-suspend.json'
az deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
  --name fabric-auto-suspend --template-file $template `
  --parameters capacityName=$($capacity.name) location=$($capacity.location) hourUtc=$HourUtc minuteUtc=$MinuteUtc `
    firstRunUtc=$($firstRun.ToString("yyyy-MM-ddTHH:mm:ssZ")) --output none
if ($LASTEXITCODE -ne 0) { throw 'Fabric suspension schedule deployment failed. Custom role and role-assignment write permissions are required.' }
Write-Host ("Fabric auto-suspension: daily at {0:00}:{1:00} UTC; first run {2:u}. Queries and ingestion will stop." -f $HourUtc, $MinuteUtc, $firstRun)
Write-Host "Workflow run history: $workflowId"
