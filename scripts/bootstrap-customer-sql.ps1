<#
.SYNOPSIS
  Explicit operator-only, idempotent customer SQL schema and least-privilege users.
.DESCRIPTION
  Requires the already-selected SQL Entra admin account; direct connections also
  require the SqlServer PowerShell module. Tokens stay in memory. Optional firewall access is one approved IPv4
  address and is always deleted in finally. Private-network operators need no rule.
  CREATE USER WITH SID, TYPE=E avoids Graph lookup and Directory Readers grants.
  When public SQL access is disabled, UseCustomerPrivateTunnel uses an existing
  authenticated Azure CLI customer App Service SSH tunnel on SshPort. Requires
  .NET 8 SDK and Python paramiko, not Invoke-Sqlcmd. Tokens use encrypted stdin.
  PythonExecutable selects the interpreter provisioned by deployment completion.
  CheckOnly verifies login with SELECT 1 without changing schema, data or users.
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
  [ValidateNotNullOrEmpty()][string] $PythonExecutable = 'python',
  [switch] $CheckOnly,
  [ValidateRange(1, 65535)][int] $SshPort = 22446
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'customer-dependency-helpers.ps1')
$context = Get-CustomerDependencyContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName
if ($ConfirmTarget -ine $context.sqlDatabaseId) { throw 'ConfirmTarget must equal the exact deployed customer SQL database resource ID.' }
if ($UseCustomerPrivateTunnel -and ($ApproveTemporaryFirewall -or $OperatorIpv4)) {
  throw 'Private tunnel bootstrap cannot be combined with public firewall access.'
}
if (-not $UseCustomerPrivateTunnel -and $PSBoundParameters.ContainsKey('SshPort')) {
  throw 'SshPort requires -UseCustomerPrivateTunnel.'
}
if (-not $UseCustomerPrivateTunnel -and $PSBoundParameters.ContainsKey('PythonExecutable')) {
  throw 'PythonExecutable requires -UseCustomerPrivateTunnel.'
}
if ($UseCustomerPrivateTunnel) {
  foreach ($tool in @('dotnet', $PythonExecutable)) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Private tunnel bootstrap requires $tool." }
  }
  & $PythonExecutable -c "import paramiko"
  if ($LASTEXITCODE -ne 0) { throw 'Private tunnel bootstrap requires Python paramiko. In this shell, run: python -m pip install paramiko; then verify: python -c "import paramiko". If Python is externally managed, activate a virtual environment first (see scripts/README.md). Retry bootstrap after verification; no SQL changes were started.' }
} elseif (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
  throw 'Install/import the SqlServer PowerShell module before bootstrap. No Azure changes were made.'
}
if ($ApproveTemporaryFirewall) {
  $ip = $null
  if (-not [Net.IPAddress]::TryParse($OperatorIpv4, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $OperatorIpv4 -in @('0.0.0.0','255.255.255.255') -or $ip.Equals([Net.IPAddress]::Loopback)) {
    throw 'Temporary firewall approval requires one explicit routable OperatorIpv4 address; blanket Azure-services rules are prohibited.'
  }
} elseif ($OperatorIpv4) { throw 'OperatorIpv4 requires -ApproveTemporaryFirewall.' }
$query = if ($CheckOnly) { 'SELECT 1;' } else { Get-CustomerSqlBootstrap -CustomerClientId $context.customerIdentityClientId -WorkerClientId $context.workerIdentityClientId }
$operation = if ($CheckOnly) { 'Check SQL login with SELECT 1; optionally add one temporary operator firewall rule' } else { 'Bootstrap schema/users with SQL Entra administrator token; optionally add one temporary operator firewall rule' }
if (-not $PSCmdlet.ShouldProcess($context.sqlDatabaseId, $operation)) { return }
$firewallName = 'customer-bootstrap-' + [guid]::NewGuid().ToString('N')
$firewallCreated = $false
$accessToken = $null
$privateArtifact = $null
$privatePayload = $null
try {
  $accessToken = az account get-access-token --subscription $SubscriptionId --resource 'https://database.windows.net/' --query accessToken --output tsv --only-show-errors
  if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Unable to acquire operator Azure SQL token.' }
  if ($UseCustomerPrivateTunnel) {
    $privateArtifact = Join-Path $PSScriptRoot ('..\.artifacts\customer-sql-bootstrap-' + [guid]::NewGuid().ToString('N'))
    $publish = Join-Path $privateArtifact 'publish'
    dotnet publish (Join-Path $PSScriptRoot 'customer-sql-bootstrap\CustomerSqlBootstrap.csproj') `
      --configuration Release --output $publish --nologo --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'Private SQL bootstrap tool publication failed.' }
    $privatePayload = @{ AccessToken = $accessToken; Query = $query; SqlServerName = $context.sqlServerName } | ConvertTo-Json -Compress
    $privateArguments = @((Join-Path $PSScriptRoot 'customer-sql-bootstrap\bootstrap-over-ssh.py'), '--publish', $publish, '--port', $SshPort)
    if ($CheckOnly) { $privateArguments += '--check-only' }
    $privatePayload | & $PythonExecutable @privateArguments
    if ($LASTEXITCODE -ne 0) { throw 'Private SQL operation failed. See the SQL login, initialization or verification error above; check private connectivity and the configured SQL Entra administrator.' }
    return
  }
  if ($ApproveTemporaryFirewall) {
    az sql server firewall-rule create --subscription $SubscriptionId --resource-group $ResourceGroup --server $context.sqlServerName `
      --name $firewallName --start-ip-address $OperatorIpv4 --end-ip-address $OperatorIpv4 --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the approved temporary operator firewall rule.' }
    $firewallCreated = $true
  }
  $connection = "Server=tcp:$($context.sqlServerName).database.windows.net,1433;Database=$($context.sqlDatabaseName);Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  Invoke-Sqlcmd -ConnectionString $connection -AccessToken $accessToken -Query $query -QueryTimeout 60 -AbortOnError | Out-Null
  if ($CheckOnly) {
    Write-Host 'Customer SQL connection check passed. No schema or data was changed.'
  } else {
    Write-Host 'Customer SQL schema, seed products and object-scoped users are ready. No Graph directory grant was required.'
  }
} finally {
  $accessToken = $null
  $privatePayload = $null
  if ($privateArtifact -and (Test-Path -LiteralPath $privateArtifact)) {
    Remove-Item -LiteralPath $privateArtifact -Recurse -Force
  }
  if ($firewallCreated) {
    az sql server firewall-rule delete --subscription $SubscriptionId --resource-group $ResourceGroup --server $context.sqlServerName `
      --name $firewallName --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Temporary firewall cleanup failed: remove ONLY rule '$firewallName' on '$($context.sqlServerName)' before continuing." }
  }
}
