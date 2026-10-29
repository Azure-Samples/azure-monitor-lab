<#
.SYNOPSIS
  Resume the lab's Microsoft Fabric F2 capacity.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'
az account set --subscription $SubscriptionId | Out-Null
$activeSubscriptionId = az account show --query id -o tsv
if ($activeSubscriptionId -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$activeSubscriptionId'."
}

$capacity = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Fabric/capacities `
  --query '[0].{id:id,name:name,sku:sku.name}' `
  -o json | ConvertFrom-Json
if (-not $capacity) { throw "No Microsoft Fabric capacity was found in '$ResourceGroup'." }
if ($capacity.sku -ne 'F2') { throw "Refusing to resume unexpected SKU '$($capacity.sku)'." }

if ($PSCmdlet.ShouldProcess($capacity.id, 'Resume Microsoft Fabric F2 capacity')) {
  az rest `
    --method post `
    --url "https://management.azure.com$($capacity.id)/resume?api-version=2023-11-01" `
    --subscription $SubscriptionId `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "Failed to resume Fabric capacity '$($capacity.name)'." }
  Write-Host "Fabric capacity '$($capacity.name)' is active." -ForegroundColor Green
  Write-Host 'Cost warning: F2 compute billing resumes while the capacity is active.' -ForegroundColor Yellow
}