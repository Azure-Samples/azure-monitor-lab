$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$directory = Join-Path ([IO.Path]::GetTempPath()) ('sre-setup-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $directory 'scripts')
$subscription = '11111111-1111-1111-1111-111111111111'
$scope = "/subscriptions/$subscription/resourceGroups/rg-test"
$customerName = 'app-test-abcde-customer'
$customerId = "$scope/providers/Microsoft.Web/sites/$customerName"
$fixture = @{
  CustomerNames = @($customerName)
  RollbackPresent = $false
  SlotFailure = $false
  SlotName = 'broken'
  SlotReads = 0
  RollbackChecks = 0
}
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' { return }
    'account show' { return @{ id = $subscription; name = 'Offline fixture' } | ConvertTo-Json }
    'group show' { return @{ name = 'rg-test' } | ConvertTo-Json }
    'resource list' {
      return @(
        @{ type = 'Microsoft.App/agents'; name = 'sre-test'; id = "$scope/providers/Microsoft.App/agents/sre-test" }
        @{ type = 'Microsoft.Web/sites'; name = 'app-test-abcde'; id = "$scope/providers/Microsoft.Web/sites/app-test-abcde" }
        @{ type = 'Microsoft.Web/sites'; name = 'func-test-orders'; id = "$scope/providers/Microsoft.Web/sites/func-test-orders" }
        foreach ($name in $fixture.CustomerNames) {
          @{ type = 'Microsoft.Web/sites'; name = $name; id = "$scope/providers/Microsoft.Web/sites/$name" }
        }
      ) | ConvertTo-Json -Depth 10
    }
    'resource show' {
      return @{
        id = "$scope/providers/Microsoft.App/agents/sre-test"; name = 'sre-test'; location = 'swedencentral'
        identity = @{ principalId = 'connector-principal' }
        properties = @{ incidentManagementConfiguration = @{ type = 'AzMonitor' } }
      } | ConvertTo-Json -Depth 10
    }
    'rest --method' {
      return @('app-insights', 'log-analytics', 'azure-monitor') | ForEach-Object { @{ name = $_ } } | ConvertTo-Json
    }
    'webapp deployment' {
      if ($args[[Array]::IndexOf($args, '--name') + 1] -cne $customerName) { throw 'Slot validation selected the wrong Web App.' }
      $fixture.SlotReads++
      if ($fixture.SlotFailure) { $global:LASTEXITCODE = 1; return '[]' }
      return @(@{ name = $fixture.SlotName }) | ConvertTo-Json -AsArray
    }
    'role assignment' {
      if ($args[2] -ne 'list') { throw 'Offline validation must never grant roles.' }
      $roleScope = $args[[Array]::IndexOf($args, '--scope') + 1]
      if ($roleScope -eq $customerId) {
        if ($args[[Array]::IndexOf($args, '--assignee-object-id') + 1] -ne 'action-principal') {
          throw 'Rollback role must be checked on the action identity.'
        }
        $fixture.RollbackChecks++
      }
      return @(
        foreach ($role in @('Reader', 'Log Analytics Reader', 'Monitoring Reader', 'Monitoring Contributor')) {
          @{ roleDefinitionName = $role }
        }
        if ($fixture.RollbackPresent -and $roleScope -eq $customerId) {
          @{ roleDefinitionName = 'Lab SRE Slot Rollback fixture' }
        }
      ) | ConvertTo-Json
    }
    default { throw "Unexpected Azure command: $($args -join ' ')" }
  }
}
function Invoke-Fixture([switch] $Grant) {
  & (Join-Path $directory 'scripts/setup-sre-agent.ps1') -SubscriptionId $subscription -ResourceGroup 'rg-test' `
    -AgentPrincipalId 'action-principal' -GrantMissingRoles:$Grant -Yes 6>&1 | Out-String
}
function Assert-Failure([scriptblock] $Run, [string] $Pattern) {
  $message = ''
  try { & $Run | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Pattern) { throw "Expected '$Pattern', received '$message'." }
}
try {
  foreach ($name in @('setup-sre-agent.ps1', 'lab-config.ps1')) {
    Copy-Item -LiteralPath (Join-Path $source "scripts/$name") -Destination (Join-Path $directory 'scripts')
  }
  $output = Invoke-Fixture
  if ($fixture.RollbackChecks -ne 1 -or $output -notmatch '\[WARN\].*Lab SRE Slot Rollback' -or
      $output -match 'All documented SRE Agent roles are present') {
    throw 'Multiple Web Apps must not hide a missing customer rollback role.'
  }
  Assert-Failure { Invoke-Fixture -Grant } '*slot rollback role assignment is missing*'
  $fixture.RollbackPresent = $true
  $fixture.SlotName = "$customerName/broken"
  $output = Invoke-Fixture
  if ($output -notmatch 'All documented SRE Agent roles are present') { throw 'A correctly scoped rollback assignment was not accepted.' }
  $fixture.SlotFailure = $true
  Assert-Failure { Invoke-Fixture } '*Could not inspect App Service slots*'
  $fixture.SlotFailure = $false
  $fixture.CustomerNames = @($customerName, 'app-other-abcde-customer')
  Assert-Failure { Invoke-Fixture } '*Multiple customer Web Apps*'
  $fixture.CustomerNames = @()
  $reads = $fixture.SlotReads
  $output = Invoke-Fixture
  if ($fixture.SlotReads -ne $reads -or $output -notmatch 'Customer slot scenario is not deployed') {
    throw 'Without a customer app, validation must explicitly skip rollback checks and never inspect the console slots.'
  }
  Write-Output 'PASS: SRE customer selection, exact rollback scope, missing-role reporting, ambiguity, slot API failures and disabled-scenario handling. No Azure calls or grants.'
} finally {
  Remove-Item -LiteralPath $directory -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
