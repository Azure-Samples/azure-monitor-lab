$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$helper = Join-Path $source 'scripts/remove-sre-agent.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$tenant = '22222222-2222-2222-2222-222222222222'
$id = "/subscriptions/$subscription/resourceGroups/rg-test/providers/Microsoft.App/agents/sre-test"
$fixture = @{}

function Reset-Fixture {
  $fixture.Tenant = $tenant
  $fixture.Power = 'Running'
  $fixture.Phase = 'Initial'
  $fixture.Provisioning = 'Succeeded'
  $fixture.Absent = $false
  $fixture.Stops = 0
  $fixture.Deletes = 0
  $fixture.StopReads = 0
  $fixture.DeleteReads = 0
  $fixture.PendingStopReads = 0
  $fixture.PendingDeleteReads = 0
  $fixture.StopError = ''
  $fixture.DeleteError = ''
  $fixture.ReadError = ''
  $fixture.ActivityError = $false
  $fixture.AbsentAfterError = $false
  $fixture.UseRunningState = $false
  $fixture.ReturnedId = $id
  $fixture.Delays = [Collections.Generic.List[int]]::new()
}
function az {
  $global:LASTEXITCODE = 0
  if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $subscription) { throw 'Cleanup lost the explicit subscription.' }
  switch ($args[0..1] -join ' ') {
    'account show' { return @{ id = $subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'resource show' {
      if ($args[[Array]::IndexOf($args, '--ids') + 1] -ne $id -or $args -notcontains '2025-05-01-preview') { throw 'Unexpected metadata lookup.' }
      if ($fixture.ReadError) { $global:LASTEXITCODE = 1; return $fixture.ReadError }
      if ($fixture.Phase -eq 'Stopping') {
        $fixture.StopReads++
        if ($fixture.StopReads -gt $fixture.PendingStopReads) { $fixture.Power = 'Stopped' }
      }
      if ($fixture.Phase -eq 'Deleting') {
        $fixture.DeleteReads++
        if ($fixture.DeleteReads -gt $fixture.PendingDeleteReads) { $fixture.Absent = $true }
      }
      if ($fixture.Absent) { $global:LASTEXITCODE = 1; return 'ERROR: (ResourceNotFound) Agent is absent.' }
      return @{
        id = $fixture.ReturnedId; provisioningState = $fixture.Provisioning
        powerState = $(if (-not $fixture.UseRunningState) { $fixture.Power })
        runningState = $fixture.Power
      } | ConvertTo-Json
    }
    'rest --subscription' {
      if ($args -notcontains 'post' -or
          $args -notcontains "https://management.azure.com$id/stop?api-version=2025-05-01-preview") { throw 'Unexpected action: only stop is permitted.' }
      $fixture.Stops++
      if ($fixture.StopError) {
        $global:LASTEXITCODE = 1
        if ($fixture.AbsentAfterError) { $fixture.Absent = $true }
        return $fixture.StopError
      }
      $fixture.Phase = 'Stopping'
      return
    }
    'resource delete' {
      if ($fixture.Power -ne 'Stopped' -or $args -notcontains '--no-wait' -or
          $args[[Array]::IndexOf($args, '--ids') + 1] -ne $id) { throw 'Delete requires a verified stopped agent and nonblocking submission.' }
      $fixture.Deletes++
      if ($fixture.DeleteError) {
        $global:LASTEXITCODE = 1
        if ($fixture.AbsentAfterError) { $fixture.Absent = $true }
        return $fixture.DeleteError
      }
      $fixture.Phase = 'Deleting'
      return
    }
    'monitor activity-log' {
      if ($args[[Array]::IndexOf($args, '--resource-id') + 1] -ne $id) { throw 'Diagnostics must remain agent-scoped.' }
      if ($fixture.ActivityError) { $global:LASTEXITCODE = 1; return 'ERROR: Activity Log denied.' }
      return '[{"details":"OperationFailed; support operation ID fixture-operation"}]'
    }
    default { throw "Unexpected command: $($args -join ' ')" }
  }
}
function Start-Sleep { param($Seconds); $fixture.Delays.Add($Seconds) }
function Invoke-Cleanup([int] $Timeout = 1) {
  & $helper -SubscriptionId $subscription -TenantId $tenant -ResourceId $id -VerificationTimeoutSeconds $Timeout -Confirm:$false
}
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}

foreach ($nativePreference in @($true, $false)) {
  & {
    $PSNativeCommandUseErrorActionPreference = $nativePreference
    Reset-Fixture
    $fixture.PendingStopReads = 1
    $fixture.PendingDeleteReads = 1
    if (-not (Invoke-Cleanup 30) -or $fixture.Stops -ne 1 -or $fixture.Deletes -ne 1 -or
        -not $fixture.Absent -or ($fixture.Delays -join ',') -ne '10,10') {
      throw 'Cleanup must submit each action once, wait for stopped state, then verify authoritative absence.'
    }
    if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'Cleanup leaked its native-error preference.' }
  }
}
Reset-Fixture
$fixture.Absent = $true
if ((Invoke-Cleanup) -ne $false -or $fixture.Stops -or $fixture.Deletes) { throw 'Already absent agents must not receive actions.' }
foreach ($power in @('Stopped', 'Stopping')) {
  Reset-Fixture
  $fixture.Power = $power
  if ($power -eq 'Stopping') { $fixture.Phase = 'Stopping' }
  Invoke-Cleanup | Out-Null
  if ($fixture.Stops -or $fixture.Deletes -ne 1) { throw 'Stopped/stopping agents must not receive another stop request.' }
}
Reset-Fixture
$fixture.UseRunningState = $true
Invoke-Cleanup | Out-Null
if (-not $fixture.Absent) { throw 'The preview runningState projection must remain supported.' }
Reset-Fixture
& $helper -SubscriptionId $subscription -TenantId $tenant -ResourceId $id -WhatIf | Out-Null
if ($fixture.Stops -or $fixture.Deletes) { throw 'WhatIf must not change the agent.' }
Write-Output 'PASS: stop-before-delete, bounded readback, single action submission, idempotency, state compatibility, WhatIf and native-error isolation.'

Reset-Fixture
$fixture.Provisioning = 'Failed'
$fixture.StopError = 'ERROR: Conflict("Agent is currently being processed and cannot change power state.")'
Assert-Failure { Invoke-Cleanup } '*currently being processed*'
if ($fixture.Stops -ne 1 -or $fixture.Deletes) { throw 'A service processing conflict must stop without a delete or blind stop retry.' }
Reset-Fixture
$fixture.PendingStopReads = 10
Assert-Failure { Invoke-Cleanup } '*not verified Stopped*fixture-operation*'
if ($fixture.Deletes -or $fixture.Delays.Count) { throw 'A stop timeout must be bounded and must not submit deletion.' }
Reset-Fixture
$fixture.PendingDeleteReads = 10
Assert-Failure { Invoke-Cleanup } '*not verified absent*fixture-operation*'
if ($fixture.Deletes -ne 1) { throw 'Accepted but incomplete deletion must never be resubmitted.' }
Reset-Fixture
$fixture.PendingDeleteReads = 10
$fixture.ActivityError = $true
Assert-Failure { Invoke-Cleanup } '*Activity Log lookup also failed*Activity Log denied*'
Reset-Fixture
$fixture.DeleteError = 'ERROR: (OperationFailed) Contact support with operation ID fixture-operation.'
Assert-Failure { Invoke-Cleanup } '*OperationFailed*fixture-operation*'
if ($fixture.Deletes -ne 1) { throw 'Unknown provider failure must not trigger automatic deletion retries.' }
foreach ($errorPhase in @('StopError', 'DeleteError')) {
  Reset-Fixture
  $fixture[$errorPhase] = 'ERROR: (OperationFailed) Outcome unconfirmed.'
  $fixture.AbsentAfterError = $true
  if (-not (Invoke-Cleanup)) { throw 'A failed command may only be considered complete after authoritative ResourceNotFound.' }
}
Reset-Fixture
$fixture.ReadError = 'ERROR: (AuthorizationFailed) ResourceNotFound appears only in this message.'
Assert-Failure { Invoke-Cleanup } '*No absence was assumed*AuthorizationFailed*'
if ($fixture.Stops -or $fixture.Deletes) { throw 'Authorization failures must never be interpreted as absent agents.' }
Reset-Fixture
$fixture.Tenant = $subscription
Assert-Failure { Invoke-Cleanup } '*tenant mismatch*'
Reset-Fixture
Assert-Failure { & $helper -SubscriptionId $tenant -TenantId $tenant -ResourceId $id -Confirm:$false } '*explicit subscription*'
$fixture.ReturnedId = "$id/child"
Assert-Failure { Invoke-Cleanup } '*unexpected or missing resource ID*'
Reset-Fixture
$fixture.Power = 'Unknown'
Assert-Failure { Invoke-Cleanup } '*unknown power state*'
if ($fixture.Stops -or $fixture.Deletes) { throw 'Unknown state must not authorize destructive actions.' }
Write-Output 'PASS: processing conflicts, timeouts, preserved provider/support diagnostics, absence races and scope/authentication guards. No Azure calls.'
