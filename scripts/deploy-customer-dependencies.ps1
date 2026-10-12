<#
.SYNOPSIS
  Explicit SQL bootstrap, prebuilt .NET 8 isolated worker ZIP publication, readiness.
.DESCRIPTION
  Invoke after the lab infrastructure/customer app publication. Uses the existing
  Azure CLI driver, not azd. Run as the configured SQL Entra admin. For public
  operators, approve one temporary firewall IP; private operators omit it.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)][guid] $SubscriptionId,
  [Parameter(Mandatory)][guid] $TenantId,
  [Parameter(Mandatory)][string] $ResourceGroup,
  [Parameter(Mandatory)][string] $DeploymentName,
  [Parameter(Mandatory)][string] $ConfirmTarget,
  [switch] $ApproveTemporaryFirewall,
  [string] $OperatorIpv4,
  [switch] $UseCustomerPrivateTunnel,
  [ValidateRange(1, 65535)][int] $SshPort = 22446
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
if ($ConfirmTarget -ine $context.workerId) { throw 'ConfirmTarget must equal the exact deployed orders processor resource ID.' }
if (-not $PSCmdlet.ShouldProcess($context.workerId, 'Bootstrap customer SQL, publish the isolated orders worker ZIP, verify readiness')) { return }
$bootstrap = @{
  SubscriptionId = $SubscriptionId; TenantId = $TenantId; ResourceGroup = $ResourceGroup; DeploymentName = $DeploymentName
  ConfirmTarget = $context.sqlDatabaseId; ApproveTemporaryFirewall = $ApproveTemporaryFirewall; OperatorIpv4 = $OperatorIpv4
  Confirm = $false
}
if ($UseCustomerPrivateTunnel) { $bootstrap.UseCustomerPrivateTunnel = $true; $bootstrap.SshPort = $SshPort }
elseif ($PSBoundParameters.ContainsKey('SshPort')) { throw 'SshPort requires -UseCustomerPrivateTunnel.' }
& (Join-Path $PSScriptRoot 'bootstrap-customer-sql.ps1') @bootstrap
$artifact = Join-Path $PSScriptRoot ('..\.artifacts\customer-processor-' + [guid]::NewGuid().ToString('N'))
$publish = Join-Path $artifact 'publish'
$zip = Join-Path $artifact 'processor.zip'
try {
  New-Item -ItemType Directory -Path $publish -Force | Out-Null
  $project = Join-Path $PSScriptRoot '..\workloads\customer-processor\CustomerProcessor.csproj'
  dotnet publish $project --configuration Release --output $publish --nologo --verbosity quiet
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $publish 'host.json')) -or -not (Test-Path (Join-Path $publish 'functions.metadata'))) {
    throw 'CustomerProcessor .NET 8 isolated publication did not produce host.json and functions.metadata.'
  }
  Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
  az functionapp deployment source config-zip --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName `
    --src $zip --build-remote false --output none --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Orders processor ZIP deployment failed.' }
  $ready = $false
  for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $functions = az functionapp function list --subscription $SubscriptionId --resource-group $ResourceGroup --name $context.workerName --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and @($functions).Count -gt 0) { $ready = $true; break }
    Start-Sleep -Seconds 10
  }
  if (-not $ready) { throw 'Processor functions were not discoverable within 120 seconds. Check RBAC propagation, Functions logs and host storage; do not enable keys as a workaround.' }
  & (Join-Path $PSScriptRoot 'test-customer-dependencies.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
} finally {
  if (Test-Path $artifact) { Remove-Item -LiteralPath $artifact -Recurse -Force }
}
