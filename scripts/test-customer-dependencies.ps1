<#
.SYNOPSIS
  Read-only bounded customer dependency readiness check; does not create an order.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][guid] $SubscriptionId,
  [Parameter(Mandatory)][guid] $TenantId,
  [Parameter(Mandatory)][string] $ResourceGroup,
  [Parameter(Mandatory)][string] $DeploymentName
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
$site = az webapp show --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.CustomerWebAppName `
  --query '{host:defaultHostName,state:state}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $site.state -ne 'Running' -or -not $site.host) { throw 'Customer storefront is not running.' }
$products = Invoke-RestMethod -Uri "https://$($site.host)/api/customer/products" -TimeoutSec 20
foreach ($seed in @('monitoring-starter', 'agent-operations', 'sre-command')) {
  if (@($products | Where-Object id -eq $seed).Count -ne 1) { throw "Customer SQL products endpoint did not return seed '$seed'." }
}
$namespace = $context.serviceBusNamespace -replace '\.servicebus\.windows\.net$', ''
$queue = az servicebus queue show --subscription $SubscriptionId --resource-group $ResourceGroup --namespace-name $namespace --name orders `
  --query '{status:status,maxDeliveryCount:maxDeliveryCount,requiresDuplicateDetection:requiresDuplicateDetection}' --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $queue.status -ne 'Active' -or $queue.maxDeliveryCount -gt 5 -or -not $queue.requiresDuplicateDetection) {
  throw 'Orders queue is not ready or no longer has the approved retry/dedup bounds.'
}
$functions = az functionapp function list --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($functions).Count -eq 0) { throw 'Processor host has no discoverable functions.' }
Write-Host 'Read-only readiness passed: SQL products, bounded active orders queue and deployed processor. Submit one order explicitly to verify queue-to-worker completion; this check does not write customer data.'
