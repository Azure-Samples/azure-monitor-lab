<#
.SYNOPSIS
  Exact-target, opt-in dependency faults and recovery; never stops global resources.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Deployment')]
param(
  [Parameter(Mandatory)][guid] $SubscriptionId,
  [Parameter(Mandatory)][guid] $TenantId,
  [Parameter(Mandatory)][string] $ResourceGroup,
  [Parameter(Mandatory, ParameterSetName = 'Deployment')][string] $DeploymentName,
  [Parameter(Mandatory, ParameterSetName = 'Runner')][ValidatePattern('^[a-zA-Z0-9-]{2,60}$')][string] $CustomerWebAppName,
  [Parameter(Mandatory, ParameterSetName = 'Runner')][ValidatePattern('^[a-zA-Z0-9-]{2,60}$')][string] $WorkerName,
  [Parameter(Mandatory)][ValidateSet('SqlDelay','WorkerFailure','Recover')][string] $Fault,
  [ValidateRange(0,5)][int] $SqlDelaySeconds = 3,
  [Parameter(Mandatory)][string] $ConfirmTarget
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
if ($PSCmdlet.ParameterSetName -eq 'Runner') {
  if ($env:LAB_RUNNER_MODE -cne 'ContainerAppsJob' -or $env:LAB_CUSTOMER_WEB_APP_NAME -cne $CustomerWebAppName -or
      $env:LAB_CUSTOMER_WORKER_NAME -cne $WorkerName -or $env:LAB_WEB_APP_NAME -ceq $CustomerWebAppName -or
      $CustomerWebAppName -cne "$($env:LAB_WEB_APP_NAME)-customer") {
    throw 'Dependency fault targets must match the approved independent runner environment.'
  }
  $account = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
    throw 'Dependency fault subscription or tenant mismatch.'
  }
  foreach ($site in @($CustomerWebAppName, $WorkerName)) {
    $enabled = @(az webapp config appsettings list --subscription $SubscriptionId --resource-group $ResourceGroup --name $site `
      --query "[?name=='CustomerDependencies__Enabled'].value" --output json --only-show-errors | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or @($enabled).Count -ne 1 -or $enabled[0] -ine 'true') {
      throw "Real customer dependencies are not enabled on the exact target '$site'."
    }
  }
  $context = [pscustomobject]@{
    CustomerWebAppName = $CustomerWebAppName
    workerName = $WorkerName
    workerId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$WorkerName"
  }
} else {
  $context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
}
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
  az webapp restart --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.CustomerWebAppName --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Customer app restart failed after SQL-delay change; settings may already have changed.' }
  if ($Fault -eq 'Recover') {
    az webapp restart --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.CustomerWebAppName --slot broken --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Broken-slot restart failed after reset; settings may already have changed.' }
  }
}
if ($Fault -in @('WorkerFailure','Recover')) {
  $fail = if ($Fault -eq 'Recover') { 'false' } else { 'true' }
  az functionapp config appsettings set --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName `
    --settings "CustomerDependencies__FailProcessing=$fail" --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Orders processor fail-processing setting update failed.' }
  az functionapp restart --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Processor restart failed after failure-setting change; settings may already have changed.' }
}
Write-Host 'Fault settings applied. Recovery restores SQL delay=0 and worker fail-processing=false; dead-lettered messages are not silently replayed.'
