<#
.SYNOPSIS
  Complete an enabled customer backend after storefront publication.
.DESCRIPTION
  Resolves the exact deployment context, requests approval, then bootstraps SQL
  through a temporary private tunnel and publishes/verifies the orders worker.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][guid] $SubscriptionId,
  [Parameter(Mandatory)][guid] $TenantId,
  [Parameter(Mandatory)][string] $ResourceGroup,
  [Parameter(Mandatory)][string] $CustomerWebAppName,
  [string] $DeploymentName,
  [switch] $ApproveCustomerDependencies
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$enabled = az webapp config appsettings list --subscription $SubscriptionId --resource-group $ResourceGroup --name $CustomerWebAppName `
  --query "[?name=='CustomerDependencies__Enabled'].value | [0]" --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve customer dependency configuration after publication.' }
if ($enabled -eq 'false') { return }
if ($enabled -ne 'true') { throw 'CustomerDependencies__Enabled must explicitly be true or false on the customer app.' }
if (-not $DeploymentName) {
  $deployments = @(az deployment group list --subscription $SubscriptionId --resource-group $ResourceGroup `
    --query "[?properties.provisioningState=='Succeeded'].{name:name,customerApp:properties.outputs.customerWebAppName.value,timestamp:properties.timestamp}" `
    --output json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not discover the customer infrastructure deployment. Specify CustomerDependencyDeploymentName.' }
  $latest = @($deployments | Where-Object { $_.customerApp -ceq $CustomerWebAppName } | Sort-Object timestamp -Descending | Select-Object -First 1)
  if ($latest.Count -ne 1 -or -not $latest[0].name) { throw 'No successful deployment matches the exact customer app. Specify CustomerDependencyDeploymentName.' }
  $DeploymentName = $latest[0].name
}
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
if ($context.CustomerWebAppName -cne $CustomerWebAppName) { throw 'The customer deployment output does not match the published storefront.' }
Write-Host "Customer backend completion: SQL schema, three seed products and object-scoped managed-identity users in '$($context.sqlDatabaseId)'; worker ZIP publication to '$($context.workerId)'; read-only readiness."
Write-Host 'SQL public access and firewall rules remain unchanged. No order is submitted. Run as the configured SQL Entra administrator; .NET 8 SDK, Python and paramiko are required.'
if (-not $ApproveCustomerDependencies -and
    (Read-Host 'Approve this customer SQL initialization and worker publication? Type yes to continue') -ine 'yes') {
  throw 'Customer backend completion was not approved. Infrastructure exists, but deployment readiness is incomplete.'
}
& (Join-Path $PSScriptRoot 'deploy-customer-dependencies.ps1') `
  -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName `
  -ConfirmTarget $context.workerId -StartCustomerPrivateTunnel -Confirm:$false
