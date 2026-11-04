$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path $source ('.artifacts\customer-completion-test-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $root 'scripts'
$sub = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$tenant = [guid]'11111111-aaaa-bbbb-cccc-dddddddddddd'
$base = "/subscriptions/$sub/resourceGroups/test-rg/providers"
$context = @{
  enabled = $true; sqlServerName = 'sql-test'; sqlServerId = "$base/Microsoft.Sql/servers/sql-test"
  sqlDatabaseName = 'customer-orders'; sqlDatabaseId = "$base/Microsoft.Sql/servers/sql-test/databases/customer-orders"
  workerName = 'func-test-orders'; workerId = "$base/Microsoft.Web/sites/func-test-orders"
  serviceBusNamespace = 'sb-test.servicebus.windows.net'; serviceBusNamespaceId = "$base/Microsoft.ServiceBus/namespaces/sb-test"
  queueName = 'orders'; customerIdentityClientId = '11111111-2222-3333-4444-555555555555'
  workerIdentityClientId = '66666666-7777-8888-9999-aaaaaaaaaaaa'
}
$common = @{ SubscriptionId = $sub; TenantId = $tenant; ResourceGroup = 'test-rg' }
$fixture = @{}
function Reset-Fixture {
  $fixture.Clear()
  $fixture.Enabled = 'true'
  $fixture.Reply = 'yes'
  $fixture.Failure = ''
  $fixture.Events = [Collections.Generic.List[string]]::new()
  $fixture.Calls = [Collections.Generic.List[string]]::new()
  $fixture.Prompts = 0
  $fixture.Polls = 0
}
function Assert-True([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action, [string] $Message) {
  $caught = $null
  try { & $Action | Out-Null } catch { $caught = $_ }
  Assert-True ($null -ne $caught -and $caught.Exception.Message -like "*$Message*") "Expected failure containing '$Message'; got '$($caught.Exception.Message)'."
}
function Read-Host { $fixture.Prompts++; return $fixture.Reply }
function Start-Sleep { }
function python {
  Assert-True (($args -join ' ') -eq '-c import paramiko') 'Prerequisite check must not request or print tokens.'
  $global:LASTEXITCODE = if ($fixture.Failure -eq 'python') { 1 } else { 0 }
}
function Start-Job {
  param($ScriptBlock, $ArgumentList)
  Assert-True ($ArgumentList[0] -eq $sub.ToString() -and $ArgumentList[1] -eq 'test-rg' -and
    $ArgumentList[2] -eq 'app-test-customer' -and $ArgumentList[3] -gt 0) 'Tunnel must target only the verified customer app and an allocated port.'
  $fixture.Events.Add('tunnel-start')
  return [pscustomobject]@{ State = $(if ($fixture.Failure -eq 'tunnel-exit') { 'Failed' } else { 'Running' }) }
}
function Stop-Job { param($Job) $fixture.Events.Add('tunnel-stop') }
function Remove-Job { param($Job) $fixture.Events.Add('tunnel-remove') }
function Receive-Job { param($Job) return 'simulated tunnel exit' }
function dotnet {
  $fixture.Events.Add('publish')
  Assert-True ($args[0] -eq 'publish' -and $args[1] -like '*customer-processor*CustomerProcessor.csproj') 'Only the isolated orders worker may be published.'
  $out = $args[[array]::IndexOf($args, '--output') + 1]
  '{}' | Set-Content (Join-Path $out 'host.json')
  '[]' | Set-Content (Join-Path $out 'functions.metadata')
  $global:LASTEXITCODE = if ($fixture.Failure -eq 'publish') { 1 } else { 0 }
}
function Invoke-RestMethod {
  param($Uri, $TimeoutSec)
  $fixture.Events.Add('products')
  Assert-True ($Uri -eq 'https://app-test-customer.azurewebsites.net/api/customer/products' -and $TimeoutSec -eq 20) 'Readiness must be bounded and read-only.'
  if ($fixture.Failure -eq 'products') { return @() }
  return @('monitoring-starter', 'agent-operations', 'sre-command') | ForEach-Object { @{ id = $_ } }
}
function az {
  $command = $args -join ' '
  $fixture.Calls.Add($command)
  $global:LASTEXITCODE = 0
  switch -Wildcard ($command) {
    'account show*' {
      return @{ id = $sub; tenantId = $(if ($fixture.Failure -eq 'account') { [guid]::NewGuid() } else { $tenant }) } | ConvertTo-Json
    }
    'webapp config appsettings list*' {
      if ($fixture.Failure -eq 'settings') { $global:LASTEXITCODE = 1 }
      return $fixture.Enabled
    }
    'deployment group list*' {
      if ($fixture.Failure -eq 'discovery') { $global:LASTEXITCODE = 1; return '[]' }
      if ($fixture.Failure -eq 'no-match') { return '[]' }
      return @(
        @{ name = 'older'; customerApp = 'app-test-customer'; timestamp = '2026-10-26T10:00:00Z' },
        @{ name = 'latest'; customerApp = 'app-test-customer'; timestamp = '2026-10-27T10:00:00Z' },
        @{ name = 'unrelated'; customerApp = 'app-other-customer'; timestamp = '2026-10-27T11:00:00Z' }
      ) | ConvertTo-Json
    }
    'deployment group show*' {
      $name = $args[[array]::IndexOf($args, '--name') + 1]
      Assert-True ($name -in @('latest', 'explicit')) 'Only the latest exact customer deployment or explicit target may authorize setup.'
      return @{
        parameters = @{ enableCustomerDependencies = @{ value = ($fixture.Failure -ne 'disabled-deployment') } }
        outputs = @{
          customerDependencies = @{ value = $context }
          customerWebAppName = @{ value = $(if ($fixture.Failure -eq 'mismatch') { 'app-other-customer' } else { 'app-test-customer' }) }
          webAppName = @{ value = $(if ($fixture.Failure -eq 'mismatch') { 'app-other' } else { 'app-test' }) }
        }
      } | ConvertTo-Json -Depth 8
    }
    'functionapp deployment source config-zip*' {
      $fixture.Events.Add('upload')
      if ($fixture.Failure -eq 'upload') { $global:LASTEXITCODE = 1 }
      return
    }
    'functionapp function list*' {
      $fixture.Events.Add('functions')
      if ($fixture.Failure -eq 'functions') { return '[]' }
      return '[{"name":"ProcessCustomerOrder"}]'
    }
    'webapp show*' { return '{"host":"app-test-customer.azurewebsites.net","state":"Running"}' }
    'servicebus queue show*' { return '{"status":"Active","maxDeliveryCount":5,"requiresDuplicateDetection":true}' }
    default { throw "Unexpected Azure command (writes/auth changes are prohibited): $command" }
  }
}
try {
  $null = New-Item -ItemType Directory -Path $scripts -Force
  foreach ($name in @('complete-customer-dependencies.ps1', 'deploy-customer-dependencies.ps1', 'customer-dependency-helpers.ps1', 'test-customer-dependencies.ps1')) {
    Copy-Item -LiteralPath (Join-Path $source "scripts\$name") -Destination $scripts
  }
  @'
function Test-CustomerSqlTunnel {
  param($Port)
  $fixture.Polls++
  return $fixture.Failure -ne 'tunnel-timeout'
}
'@ | Add-Content (Join-Path $scripts 'customer-dependency-helpers.ps1')
  @'
param($SubscriptionId,$TenantId,$ResourceGroup,$DeploymentName,$ConfirmTarget,$ApproveTemporaryFirewall,$OperatorIpv4,
  [switch]$UseCustomerPrivateTunnel,$SshPort,[switch]$Confirm)
if ($ConfirmTarget -ne $context.sqlDatabaseId -or -not $UseCustomerPrivateTunnel -or $SshPort -le 0 -or
    $ApproveTemporaryFirewall -or $OperatorIpv4 -or $Confirm) { throw 'Bootstrap must use the exact SQL target and private tunnel without public firewall approval.' }
$fixture.Events.Add('bootstrap')
if ($fixture.Failure -eq 'sql') { throw 'simulated SQL failure' }
'@ | Set-Content (Join-Path $scripts 'bootstrap-customer-sql.ps1')
  $complete = Join-Path $scripts 'complete-customer-dependencies.ps1'
  $lifecycle = Join-Path $scripts 'deploy-customer-dependencies.ps1'
  Reset-Fixture
  $fixture.Enabled = 'false'
  & $complete @common -CustomerWebAppName app-test-customer
  Assert-True ($fixture.Events.Count -eq 0 -and $fixture.Calls.Count -eq 1 -and $fixture.Prompts -eq 0) 'Disabled backends must not prompt, discover deployments, or write.'

  foreach ($case in @(
    @{ Failure = 'settings'; Message = 'configuration after publication' },
    @{ Failure = 'discovery'; Message = 'discover' },
    @{ Failure = 'no-match'; Message = 'No successful deployment' },
    @{ Failure = 'disabled-deployment'; Message = 'disabled in the specified deployment' },
    @{ Failure = 'mismatch'; Message = 'does not match' },
    @{ Failure = 'account'; Message = 'already-selected expected subscription and tenant' }
  )) {
    Reset-Fixture
    $fixture.Failure = $case.Failure
    Assert-Throws { & $complete @common -CustomerWebAppName app-test-customer -ApproveCustomerDependencies } $case.Message
    Assert-True ($fixture.Events.Count -eq 0 -and $fixture.Prompts -eq 0) 'Invalid context must fail before approval, tunnel creation or writes.'
  }
  Reset-Fixture
  $fixture.Enabled = ''
  Assert-Throws { & $complete @common -CustomerWebAppName app-test-customer } 'explicitly be true or false'
  Reset-Fixture
  $fixture.Reply = 'no'
  Assert-Throws { & $complete @common -CustomerWebAppName app-test-customer } 'not approved'
  Assert-True ($fixture.Prompts -eq 1 -and $fixture.Events.Count -eq 0) 'Declined approval must stop before any tunnel, token, SQL or publication.'

  foreach ($approved in @($false, $true)) {
    Reset-Fixture
    & $complete @common -CustomerWebAppName app-test-customer -ApproveCustomerDependencies:$approved
    Assert-True ($fixture.Prompts -eq [int](-not $approved)) 'Only explicitly preapproved completion may skip the prompt.'
    Assert-True (($fixture.Events -join ',') -eq 'tunnel-start,bootstrap,tunnel-stop,tunnel-remove,publish,upload,functions,products,functions') 'SQL-first publication, early tunnel cleanup and readiness ordering changed.'
    Assert-True (-not (Test-Path (Join-Path $root '.artifacts\customer-processor-*'))) 'Successful completion must remove its own publication files.'
  }
  Reset-Fixture
  & $complete @common -CustomerWebAppName app-test-customer -DeploymentName explicit -ApproveCustomerDependencies
  Assert-True (@($fixture.Calls | Where-Object { $_ -like 'deployment group list*' }).Count -eq 0) 'An explicit deployment must not be replaced by discovery.'

  foreach ($case in @(
    @{ Failure = 'python'; Message = 'requires Python paramiko'; Started = $false },
    @{ Failure = 'tunnel-exit'; Message = 'tunnel stopped'; Started = $true },
    @{ Failure = 'tunnel-timeout'; Message = 'SSH banner'; Started = $true },
    @{ Failure = 'sql'; Message = 'simulated SQL failure'; Started = $true },
    @{ Failure = 'publish'; Message = 'isolated publication'; Started = $true },
    @{ Failure = 'upload'; Message = 'ZIP deployment failed'; Started = $true },
    @{ Failure = 'functions'; Message = 'not discoverable within 120 seconds'; Started = $true },
    @{ Failure = 'products'; Message = 'did not return seed'; Started = $true }
  )) {
    Reset-Fixture
    $fixture.Failure = $case.Failure
    Assert-Throws { & $complete @common -CustomerWebAppName app-test-customer -ApproveCustomerDependencies } $case.Message
    Assert-True (@($fixture.Events | Where-Object { $_ -eq 'tunnel-stop' }).Count -eq [int]$case.Started -and
      @($fixture.Events | Where-Object { $_ -eq 'tunnel-remove' }).Count -eq [int]$case.Started) 'Every owned tunnel must be stopped and removed exactly once, including failures.'
    if ($case.Failure -in @('python','tunnel-exit','tunnel-timeout','sql')) {
      Assert-True ($fixture.Events -notcontains 'publish') 'Failed prerequisites or SQL must block worker publication.'
    }
    Assert-True (@(Get-ChildItem (Join-Path $root '.artifacts') -Filter 'customer-processor-*' -ErrorAction SilentlyContinue).Count -eq 0) 'Failure must clean its exact publication artifact directory.'
  }
  Reset-Fixture
  & $lifecycle @common -DeploymentName explicit -ConfirmTarget $context.workerId -StartCustomerPrivateTunnel -WhatIf
  Assert-True ($fixture.Events.Count -eq 0) 'WhatIf must not start a tunnel, acquire tokens or publish.'
  Assert-Throws { & $lifecycle @common -DeploymentName explicit -ConfirmTarget $context.workerId -StartCustomerPrivateTunnel -ApproveTemporaryFirewall -Confirm:$false } 'cannot be combined'
  Assert-True ($fixture.Events.Count -eq 0) 'Conflicting private/public options must fail without writes.'
  Write-Output 'PASS: customer completion approval, exact/latest deployment guards, disabled behavior, SQL-first publication, bounded readiness, WhatIf, and private tunnel cleanup on success/failure (mocked; no Azure calls).'
} finally {
  if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
