$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$setup = Join-Path $source 'scripts/setup-fabric-tenant.ps1'
$tenantId = '11111111-1111-1111-1111-111111111111'
$groupId = '22222222-2222-2222-2222-222222222222'
$fixture = @{}
function Reset-Fixture {
  $fixture.Settings = @([pscustomobject]@{
    settingName = 'ExampleMonitoringSetting'; title = 'Workspace monitoring'
    enabled = $false; canSpecifySecurityGroups = $true
    enabledSecurityGroups = @(@{ graphId = '33333333-3333-3333-3333-333333333333'; name = 'Existing group' })
    excludedSecurityGroups = @(@{ graphId = '44444444-4444-4444-4444-444444444444'; name = 'Excluded group' })
    properties = @(@{ name = 'ExistingProperty'; value = 'true'; type = 'Boolean' })
    delegateToCapacity = $false; delegateToWorkspace = $true
  })
  $fixture.Posts = 0
  $fixture.Body = $null
  $fixture.TokenTenant = $tenantId
  $fixture.Forbidden = $false
  $fixture.SaveFailure = $false
  $fixture.Continuation = $null
  $fixture.SecondPage = @()
}
function az {
  if (($args[0..1] -join ' ') -ne 'account get-access-token' -or
      $args -notcontains '--tenant' -or $args -notcontains $tenantId) { throw 'Only an explicitly tenant-scoped token request is permitted.' }
  $global:LASTEXITCODE = 0
  @{ tenant = $fixture.TokenTenant; accessToken = 'offline-test-token' } | ConvertTo-Json
}
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body)
  if ($fixture.Forbidden) { throw 'HTTP 403 Forbidden: Fabric administrator required.' }
  if ($Headers.Authorization -ne 'Bearer offline-test-token') { throw 'Unexpected authorization header.' }
  if ($Method -eq 'Get' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/admin/tenantsettings') {
    return @{ value = $fixture.Settings; continuationUri = $fixture.Continuation }
  }
  if ($Method -eq 'Get' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/admin/tenantsettings?page=2') {
    return @{ value = $fixture.SecondPage }
  }
  if ($Method -eq 'Post' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/admin/tenantsettings/ExampleMonitoringSetting/update') {
    $fixture.Posts++
    $fixture.Body = $Body | ConvertFrom-Json
    if (-not $fixture.SaveFailure) {
      $fixture.Settings[0].enabled = $true
      $fixture.Settings[0].enabledSecurityGroups = $fixture.Body.enabledSecurityGroups
    }
    return @{}
  }
  throw "Unexpected API request: $Method $Uri"
}
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}
function Test-Apply {
  & $setup -TenantId $tenantId -SettingName ExampleMonitoringSetting -SecurityGroupId $groupId -SecurityGroupName 'Lab group' -Apply -Confirm:$false
}

Reset-Fixture
$discovered = @(& $setup -TenantId $tenantId)
if ($discovered.Count -ne 1 -or $fixture.Posts) { throw 'Default discovery must be read-only.' }
& $setup -TenantId $tenantId -SettingName ExampleMonitoringSetting -SecurityGroupId $groupId -SecurityGroupName 'Lab group' -Apply -WhatIf | Out-Null
if ($fixture.Posts) { throw 'WhatIf must not submit any setting updates.' }
Test-Apply | Out-Null
if ($fixture.Posts -ne 1 -or $fixture.Body.enabled -ne $true -or
    $fixture.Body.enabledSecurityGroups.Count -ne 2 -or
    $fixture.Body.enabledSecurityGroups.graphId -notcontains $groupId -or
    $fixture.Body.excludedSecurityGroups[0].graphId -ne '44444444-4444-4444-4444-444444444444' -or
    $fixture.Body.properties[0].name -ne 'ExistingProperty' -or
    $fixture.Body.delegateToCapacity -ne $false -or $fixture.Body.delegateToWorkspace -ne $true) {
  throw 'Scoped updates must retain existing groups, exclusions, properties and delegation.'
}
Test-Apply | Out-Null
if ($fixture.Posts -ne 1) { throw 'Already enabled lab groups must not be updated again.' }
Reset-Fixture
$fixture.Settings[0].enabled = $true
$fixture.Settings[0].enabledSecurityGroups = @()
Test-Apply | Out-Null
if ($fixture.Posts) { throw 'Existing global enablement must be preserved without a write.' }
Write-Output 'PASS: tenant discovery, WhatIf, scoped enable/readback, preserved governance fields and idempotency.'

Reset-Fixture
$fixture.Settings[0].canSpecifySecurityGroups = $false
Assert-Failure { Test-Apply } '*cannot be security-group scoped*'
Reset-Fixture
$fixture.Settings[0].excludedSecurityGroups += @{ graphId = $groupId; name = 'Lab group' }
Assert-Failure { Test-Apply } '*group is excluded*'
Reset-Fixture
Assert-Failure { & $setup -TenantId $tenantId -SettingName ExampleMonitoringSetting, Unknown -SecurityGroupId $groupId -SecurityGroupName 'Lab group' -Apply -Confirm:$false } '*not uniquely discovered*'
if ($fixture.Posts) { throw 'All selected settings must validate before any writes.' }
Assert-Failure { & $setup -TenantId $tenantId -SettingName Unknown } '*not uniquely discovered*'
Assert-Failure { & $setup -TenantId $tenantId -Apply -Confirm:$false } '*requires exact discovered*'
Reset-Fixture
$fixture.TokenTenant = $groupId
Assert-Failure { Test-Apply } '*explicit tenant*'
Reset-Fixture
$fixture.Forbidden = $true
Assert-Failure { Test-Apply } '*403*'
Reset-Fixture
$fixture.SaveFailure = $true
Assert-Failure { Test-Apply } '*saved group scope is not verified*'
if ($fixture.Posts -ne 1) { throw 'Unverified dispatch must never be automatically retried.' }
Reset-Fixture
$fixture.Continuation = 'https://untrusted.example/tenantsettings'
Assert-Failure { Test-Apply } '*Unexpected Fabric continuation URL*'
if ($fixture.Posts) { throw 'Failed discovery must not change tenant settings.' }
Reset-Fixture
$fixture.Continuation = 'https://api.fabric.microsoft.com/v1/admin/tenantsettings?page=2'
$fixture.SecondPage = @([pscustomobject]@{ settingName = 'AnotherMonitoringSetting'; title = 'Monitoring'; enabled = $true })
if (@(& $setup -TenantId $tenantId).Count -ne 2) { throw 'Discovery must include all tenant setting pages.' }
Write-Output 'PASS: tenant/group guards, unsupported global changes, exclusions, authorization failures, saved-state failures and no automatic retries. No live calls.'
