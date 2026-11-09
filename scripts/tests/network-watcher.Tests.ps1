$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
. (Join-Path $PSScriptRoot '..\network-watcher.ps1')
$subscription = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$tenant = [guid]'11111111-aaaa-bbbb-cccc-dddddddddddd'
$expectedId = "/subscriptions/$subscription/resourceGroups/NetworkWatcherRG/providers/Microsoft.Network/networkWatchers/NetworkWatcher_northeurope"
$common = @{ SubscriptionId = $subscription; TenantId = $tenant; Location = 'northeurope'; Confirm = $false }
$fixture = @{}
function Reset-Fixture {
  $fixture.Clear()
  $fixture.Mode = ''
  $fixture.GroupExists = 'true'
  $fixture.WatcherExists = $true
  $fixture.State = 'Succeeded'
  $fixture.Reads = 0
  $fixture.Delays = 0
  $fixture.Writes = [Collections.Generic.List[string]]::new()
}
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
  $failure = $null
  try { & $Action } catch { $failure = $_ }
  Assert-True ($null -ne $failure -and $failure.Exception.Message -like "*$Message*") "Expected failure containing '$Message'; got '$($failure.Exception.Message)'."
}
function Start-Sleep { param($Seconds) Assert-True ($Seconds -eq 5) 'Polling delay must stay bounded.'; $fixture.Delays++ }
function az {
  $global:LASTEXITCODE = 0
  $command = $args[0..1] -join ' '
  if ($command -ne 'account show') {
    Assert-True ($args[[array]::IndexOf($args, '--subscription') + 1] -eq $subscription.ToString()) 'Network Watcher operations must pin the exact subscription.'
  }
  switch ($command) {
    'account show' {
      if ($fixture.Mode -eq 'account-read') { $global:LASTEXITCODE = 1; return }
      return @{ id = $(if ($fixture.Mode -eq 'subscription') { [guid]::NewGuid() } else { $subscription })
        tenantId = $(if ($fixture.Mode -eq 'tenant') { [guid]::NewGuid() } else { $tenant }) } | ConvertTo-Json
    }
    'network watcher' {
      if ($args[2] -eq 'list') {
        $fixture.Reads++
        if ($fixture.Mode -eq 'inventory-read') { $global:LASTEXITCODE = 1; return }
        if ($fixture.Mode -eq 'inventory-shape') { return '{}' }
        if ($fixture.Mode -eq 'inventory-invalid') { return '[{"location":"northeurope"}]' }
        $watchers = @(@{ id = $expectedId -replace 'northeurope$', 'westeurope'; location = 'westeurope'; provisioningState = 'Succeeded' })
        if ($fixture.WatcherExists) {
          $id = if ($fixture.Mode -eq 'custom') { $expectedId -replace 'NetworkWatcherRG', 'custom-rg' } else { $expectedId }
          $state = if ($fixture.Mode -eq 'eventual' -and $fixture.Reads -gt 1) { 'Succeeded' } else { $fixture.State }
          $watchers += @{ id = $id; location = 'northeurope'; provisioningState = $state }
          if ($fixture.Mode -eq 'duplicate') { $watchers += $watchers[-1] }
        }
        return ConvertTo-Json -InputObject $watchers
      }
      Assert-True ($args[2] -eq 'configure' -and $args -notcontains '--tags' -and
        $args[[array]::IndexOf($args, '--resource-group') + 1] -eq 'NetworkWatcherRG' -and
        $args[[array]::IndexOf($args, '--locations') + 1] -eq 'northeurope' -and
        $args[[array]::IndexOf($args, '--enabled') + 1] -eq 'true') 'Only the missing selected-region watcher may be enabled without changing tags.'
      $fixture.Writes.Add('watcher')
      if ($fixture.Mode -eq 'configure') { $global:LASTEXITCODE = 1; return }
      $fixture.WatcherExists = $fixture.Mode -ne 'never-visible'
    }
    'group exists' {
      Assert-True ($args[[array]::IndexOf($args, '--name') + 1] -eq 'NetworkWatcherRG') 'Only the shared Network Watcher group may be inspected.'
      if ($fixture.Mode -eq 'group-read') { $global:LASTEXITCODE = 1; return }
      return $fixture.GroupExists
    }
    'group create' {
      Assert-True ($fixture.GroupExists -eq 'false' -and $args -notcontains '--tags' -and
        $args[[array]::IndexOf($args, '--name') + 1] -eq 'NetworkWatcherRG' -and
        $args[[array]::IndexOf($args, '--location') + 1] -eq 'northeurope') 'Never update an existing group or create a different scope.'
      $fixture.Writes.Add('group')
      if ($fixture.Mode -eq 'group-create') { $global:LASTEXITCODE = 1; return }
      $fixture.GroupExists = 'true'
    }
    default { throw "Unexpected Azure operation: $command" }
  }
}
try {
  Reset-Fixture
  Ensure-LabNetworkWatcher @common
  Assert-True ($fixture.Writes.Count -eq 0 -and $fixture.Reads -eq 1) 'Existing shared watcher must be reused untouched.'
  foreach ($exists in @('false', 'true')) {
    Reset-Fixture
    $fixture.GroupExists = $exists
    $fixture.WatcherExists = $false
    Ensure-LabNetworkWatcher @common
    $expected = if ($exists -eq 'false') { 'group,watcher' } else { 'watcher' }
    Assert-True (($fixture.Writes -join ',') -eq $expected) 'Missing dependencies must be created in order without updating an existing group.'
    Ensure-LabNetworkWatcher @common
    Assert-True (($fixture.Writes -join ',') -eq $expected) 'Reruns must not write to the existing watcher.'
  }
  Reset-Fixture
  $fixture.WatcherExists = $false
  Ensure-LabNetworkWatcher @common -WhatIf
  Assert-True ($fixture.Writes.Count -eq 0) 'WhatIf must not create shared resources.'
  foreach ($case in @(
    @{ Mode = 'subscription'; Message = 'already-selected' },
    @{ Mode = 'tenant'; Message = 'already-selected' },
    @{ Mode = 'account-read'; Message = 'verify' },
    @{ Mode = 'inventory-read'; Message = 'inspect' },
    @{ Mode = 'inventory-shape'; Message = 'JSON array' },
    @{ Mode = 'inventory-invalid'; Message = 'incomplete' },
    @{ Mode = 'custom'; Message = 'does not match' },
    @{ Mode = 'duplicate'; Message = 'does not match' }
  )) {
    Reset-Fixture
    $fixture.Mode = $case.Mode
    Assert-Throws { Ensure-LabNetworkWatcher @common } $case.Message
    Assert-True ($fixture.Writes.Count -eq 0) 'Unreadable inventory or scope mismatch must never authorize writes.'
  }
  foreach ($case in @(
    @{ Mode = 'group-read'; Message = 'determine'; Writes = '' },
    @{ Mode = 'group-create'; Message = 'create'; Writes = 'group' },
    @{ Mode = 'configure'; Message = 'enable'; Writes = 'group,watcher' }
  )) {
    Reset-Fixture
    $fixture.WatcherExists = $false
    $fixture.GroupExists = 'false'
    $fixture.Mode = $case.Mode
    Assert-Throws { Ensure-LabNetworkWatcher @common } $case.Message
    Assert-True (($fixture.Writes -join ',') -eq $case.Writes) 'Azure failures must stop before further writes.'
  }
  Reset-Fixture
  $fixture.State = 'Updating'
  $fixture.Mode = 'eventual'
  Ensure-LabNetworkWatcher @common
  Assert-True ($fixture.Reads -eq 2 -and $fixture.Delays -eq 1 -and $fixture.Writes.Count -eq 0) 'Pending existing watcher must be polled, not recreated.'
  foreach ($state in @('Failed', 'Deleting', 'Canceled')) {
    Reset-Fixture
    $fixture.State = $state
    Assert-Throws { Ensure-LabNetworkWatcher @common } $state
    Assert-True ($fixture.Writes.Count -eq 0) 'Unhealthy existing watchers must never be overwritten.'
  }
  Reset-Fixture
  $fixture.State = 'Updating'
  Assert-Throws { Ensure-LabNetworkWatcher @common } 'bounded polling'
  Assert-True ($fixture.Reads -eq 13 -and $fixture.Delays -eq 12) 'Polling must stop after 13 reads.'
  Reset-Fixture
  $fixture.WatcherExists = $false
  $fixture.Mode = 'never-visible'
  Assert-Throws { Ensure-LabNetworkWatcher @common } 'bounded polling'
  Assert-True ($fixture.Reads -eq 14 -and $fixture.Delays -eq 12 -and ($fixture.Writes -join ',') -eq 'watcher') 'An enabled watcher must be observed ready, not assumed successful.'
  Write-Output 'PASS: regional Network Watcher restoration, shared-resource preservation, exact account/scope guards, Azure error propagation, WhatIf and bounded readiness. No Azure calls.'
} finally { $global:LASTEXITCODE = $previousExitCode }
