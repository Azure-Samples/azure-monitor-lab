<#
.SYNOPSIS
  Exact-target, opt-in dependency faults and recovery; never stops global resources.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)][guid] $SubscriptionId,
  [Parameter(Mandatory)][guid] $TenantId,
  [Parameter(Mandatory)][string] $ResourceGroup,
  [Parameter(Mandatory)][string] $DeploymentName,
  [Parameter(Mandatory)][ValidateSet('SqlDelay','WorkerFailure','Recover')][string] $Fault,
  [ValidateRange(0,5)][int] $SqlDelaySeconds = 3,
  [Parameter(Mandatory)][string] $ConfirmTarget
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
$customerId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$($context.CustomerWebAppName)"
$target = if ($Fault -eq 'WorkerFailure') { $context.workerId } else { $customerId }
if ($ConfirmTarget -ine $target) { throw "ConfirmTarget must equal '$target'. Recovery confirms the customer site and resets both exact dependency targets." }
if (-not $PSCmdlet.ShouldProcess($target, "Apply $Fault to only this lab's customer dependencies")) { return }
if ($Fault -in @('SqlDelay','Recover')) {
  $delay = if ($Fault -eq 'Recover') { 0 } else { $SqlDelaySeconds }
  az webapp config appsettings set --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.CustomerWebAppName `
    --settings "CustomerDependencies__SqlDelaySeconds=$delay" --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Customer SQL-delay setting update failed.' }
  if ($Fault -eq 'Recover') {
    az webapp config appsettings set --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.CustomerWebAppName `
      --slot broken --settings CustomerDependencies__SqlDelaySeconds=0 --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Customer broken-slot SQL-delay reset failed.' }
  }
}
if ($Fault -in @('WorkerFailure','Recover')) {
  $fail = if ($Fault -eq 'Recover') { 'false' } else { 'true' }
  az functionapp config appsettings set --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName `
    --settings "CustomerDependencies__FailProcessing=$fail" --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Orders processor fail-processing setting update failed.' }
}
Write-Host 'Fault settings applied. Recovery restores SQL delay=0 and worker fail-processing=false; dead-lettered messages are not silently replayed.'
