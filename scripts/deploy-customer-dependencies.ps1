<#
.SYNOPSIS
  Explicit SQL bootstrap, prebuilt .NET 8 isolated worker ZIP publication, readiness.
.DESCRIPTION
  Invoke after the lab infrastructure/customer app publication. Uses the existing
  Azure CLI driver, not azd. Run as the configured SQL Entra admin.
  StartCustomerPrivateTunnel manages an authenticated App Service SSH tunnel and
  always closes it. UseCustomerPrivateTunnel reuses an operator-owned tunnel.
  Neither private mode enables SQL public access or adds firewall rules.
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
  [switch] $StartCustomerPrivateTunnel,
  [ValidateRange(1, 65535)][int] $SshPort = 22446
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
if ($ConfirmTarget -ine $context.workerId) { throw 'ConfirmTarget must equal the exact deployed orders processor resource ID.' }
if ($StartCustomerPrivateTunnel -and ($UseCustomerPrivateTunnel -or $ApproveTemporaryFirewall -or $OperatorIpv4)) {
  throw 'A managed private tunnel cannot be combined with an existing tunnel or public firewall access.'
}
if (-not ($UseCustomerPrivateTunnel -or $StartCustomerPrivateTunnel) -and $PSBoundParameters.ContainsKey('SshPort')) {
  throw 'SshPort requires a customer private tunnel.'
}
if (-not $PSCmdlet.ShouldProcess("$($context.sqlDatabaseId); $($context.workerId)", 'Bootstrap customer SQL, publish the isolated orders worker ZIP, verify readiness')) {
  if ($WhatIfPreference) { return }
  throw 'Customer backend completion was not approved. Infrastructure exists, but deployment readiness is incomplete.'
}
$tunnel = $null
$artifact = $null
$pythonEnvironment = $null
$pythonExecutable = 'python'
try {
  if ($StartCustomerPrivateTunnel -or $UseCustomerPrivateTunnel) {
    foreach ($tool in @('dotnet', 'python')) {
      if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Customer backend completion requires $tool." }
    }
    python -c "import paramiko" 2>$null
    if ($LASTEXITCODE -ne 0) {
      $pythonEnvironment = Join-Path $PSScriptRoot ('..\.artifacts\customer-python-' + [guid]::NewGuid().ToString('N'))
      Write-Host 'Preparing an isolated Python environment for the customer SQL tunnel; system Python packages remain unchanged.'
      python -m venv $pythonEnvironment
      if ($LASTEXITCODE -ne 0) { throw 'Could not create the customer tunnel Python environment. Install Python venv support (python3-venv on Debian/Ubuntu) and retry completion. No tunnel or SQL changes were started.' }
      $pythonExecutable = Join-Path $pythonEnvironment $(if ($IsWindows) { 'Scripts\python.exe' } else { 'bin/python' })
      & $pythonExecutable -m pip install --disable-pip-version-check --no-input paramiko | Out-Host
      if ($LASTEXITCODE -ne 0) { throw 'Could not install paramiko in the isolated customer tunnel environment. Check pip output and package-index connectivity, then retry completion. No tunnel or SQL changes were started.' }
      & $pythonExecutable -c "import paramiko"
      if ($LASTEXITCODE -ne 0) { throw 'Customer tunnel paramiko verification failed after installation. No tunnel or SQL changes were started.' }
    }
  }
  if ($StartCustomerPrivateTunnel) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $(if ($PSBoundParameters.ContainsKey('SshPort')) { $SshPort } else { 0 }))
    try {
      $listener.Start()
      $SshPort = $listener.LocalEndpoint.Port
    } finally { $listener.Stop() }
    $tunnel = Start-Job -ScriptBlock {
      param($SubscriptionId, $ResourceGroup, $Name, $Port)
      az webapp create-remote-connection --subscription $SubscriptionId --resource-group $ResourceGroup --name $Name --port $Port --timeout 1200 2>&1
      if ($LASTEXITCODE -ne 0) { throw 'The authenticated customer App Service tunnel failed.' }
    } -ArgumentList $SubscriptionId.ToString(), $ResourceGroup, $context.CustomerWebAppName, $SshPort
    $tunnelReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
      if ($tunnel.State -notin @('Running', 'NotStarted')) {
        $details = Receive-Job -Job $tunnel | Out-String
        throw "Customer private tunnel stopped before SSH was ready. $details"
      }
      if (Test-CustomerSqlTunnel -Port $SshPort) { $tunnelReady = $true; break }
      Start-Sleep -Seconds 2
    }
    if (-not $tunnelReady) { throw 'Customer private tunnel did not respond with an SSH banner within the bounded startup window.' }
  }
  $bootstrap = @{
    SubscriptionId = $SubscriptionId; TenantId = $TenantId; ResourceGroup = $ResourceGroup; DeploymentName = $DeploymentName
    ConfirmTarget = $context.sqlDatabaseId; ApproveTemporaryFirewall = $ApproveTemporaryFirewall; OperatorIpv4 = $OperatorIpv4
    Confirm = $false
  }
  if ($UseCustomerPrivateTunnel -or $StartCustomerPrivateTunnel) {
    $bootstrap.UseCustomerPrivateTunnel = $true
    $bootstrap.SshPort = $SshPort
    $bootstrap.PythonExecutable = $pythonExecutable
  }
  & (Join-Path $PSScriptRoot 'bootstrap-customer-sql.ps1') @bootstrap
  if ($tunnel) {
    Stop-Job -Job $tunnel
    Remove-Job -Job $tunnel
    $tunnel = $null
  }
  $artifact = Join-Path $PSScriptRoot ('..\.artifacts\customer-processor-' + [guid]::NewGuid().ToString('N'))
  $publish = Join-Path $artifact 'publish'
  $zip = Join-Path $artifact 'processor.zip'
  New-Item -ItemType Directory -Path $publish -Force | Out-Null
  $project = Join-Path $PSScriptRoot '..\workloads\customer-processor\CustomerProcessor.csproj'
  dotnet publish $project --configuration Release --output $publish --nologo --verbosity quiet
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $publish 'host.json')) -or -not (Test-Path (Join-Path $publish 'functions.metadata'))) {
    throw 'CustomerProcessor .NET 8 isolated publication did not produce host.json and functions.metadata.'
  }
  # Compress-Archive omits hidden directories, including .azurefunctions on Linux.
  [IO.Compression.ZipFile]::CreateFromDirectory($publish, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
  $package = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $entries = @($package.Entries.FullName)
    if ($entries -cnotcontains 'host.json' -or $entries -cnotcontains 'functions.metadata' -or
        @($entries | Where-Object { $_.StartsWith('.azurefunctions/', [StringComparison]::Ordinal) -and -not $_.EndsWith('/') }).Count -eq 0) {
      throw 'Orders processor ZIP is incomplete: host.json, functions.metadata and .azurefunctions files must be at the archive root. Check the .NET isolated publish output; no ZIP was uploaded.'
    }
  } finally { $package.Dispose() }
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
  if ($tunnel) {
    Stop-Job -Job $tunnel
    Remove-Job -Job $tunnel
  }
  if ($artifact -and (Test-Path $artifact)) { Remove-Item -LiteralPath $artifact -Recurse -Force }
  if ($pythonEnvironment -and (Test-Path -LiteralPath $pythonEnvironment)) { Remove-Item -LiteralPath $pythonEnvironment -Recurse -Force }
}
