$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('fabric-workspace-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
foreach ($name in @('setup-fabric.ps1', 'setup-fabric-cloud-shell.ps1', 'lab-config.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination $directory
}
foreach ($name in @('fabric-observability.ps1', 'fabric-connections.ps1', 'fabric-mirrored-dashboard.ps1', 'fabric-monitoring.ps1')) {
  Set-Content -LiteralPath (Join-Path $directory $name) -Value ''
}
$configPath = Join-Path $root 'lab.config.json'
$fixture = @{
  Subscription = '11111111-1111-1111-1111-111111111111'; ResourceGroup = 'rg-lab-one'
  Workspaces = @(); Capacities = @(@{ id = 'lab-capacity'; displayName = 'fabtest' })
  Selected = ''; Created = 0; Deleted = 0; DetailCapacity = 'other-capacity'; LookupFailure = $false
}
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' { }
    'account show' { return @{ id = $fixture.Subscription; tenantId = 'tenant'; userName = 'lab-user'; userType = 'user' } | ConvertTo-Json }
    'account get-access-token' { return 'offline-token' }
    'resource list' {
      if ($args -contains 'Microsoft.Fabric/capacities') { return '{"id":"arm-capacity","name":"fabtest","location":"swedencentral","sku":"F2"}' }
      if ($args -contains 'Microsoft.EventHub/namespaces') { return '' }
      if ($args -contains 'Microsoft.OperationalInsights/workspaces') { return '[]' }
      throw 'Unexpected resource discovery.'
    }
    'resource show' { return '{"state":"Active","administrators":["lab-user"]}' }
    default { throw "Unexpected Azure call: $args" }
  }
}
function Get-FabricApiCollection {
  param($Path)
  if ($fixture.LookupFailure) { throw 'Fabric lookup denied.' }
  if ($Path -eq 'capacities') { return $fixture.Capacities }
  if ($Path -eq 'workspaces') { return $fixture.Workspaces }
  if ($Path -like 'workspaces/*/eventhouses') { throw 'WORKSPACE VERIFIED' }
  throw "Unexpected Fabric collection: $Path"
}
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body, $ResponseHeadersVariable, $StatusCodeVariable)
  if ($Method -eq 'Get' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces/existing') {
    return @{ id = 'existing'; capacityId = $fixture.DetailCapacity }
  }
  if ($Method -eq 'Post' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces') {
    $item = $Body | ConvertFrom-Json
    if ($item.capacityId -ne 'lab-capacity') { throw 'Wrong creation capacity.' }
    $fixture.Selected = $item.displayName
    $fixture.Created++
    Set-Variable -Name $StatusCodeVariable -Value 201 -Scope 1
    return @{ id = 'created'; capacityId = $item.capacityId }
  }
  if ($Method -eq 'Delete' -and $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces/existing') {
    $fixture.Deleted++
    return
  }
  throw "Unexpected Fabric mutation/request: $Method $Uri"
}
function Invoke-Setup {
  param([hashtable] $Options = @{}, [string] $Expected = 'WORKSPACE VERIFIED')
  $fixture.Created = 0; $fixture.Deleted = 0; $fixture.Selected = ''
  $failure = ''
  try {
    & (Join-Path $directory 'setup-fabric.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup @Options | Out-Null
  } catch { $failure = $_.Exception.Message }
  if ($failure -notlike "*$Expected*" -or (-not $Expected -and $failure)) {
    throw "Expected '$Expected', got '$failure'."
  }
}
try {
  Invoke-Setup
  $scopedName = $fixture.Selected
  if ($scopedName -cne 'Azure Monitor Demo Lab - fe90e19d9198' -or $fixture.Created -ne 1) {
    throw 'An unconfigured lab must create one scope-specific workspace.'
  }
  $fixture.ResourceGroup = 'RG-LAB-ONE'
  Invoke-Setup
  if ($fixture.Selected -cne $scopedName) { throw 'Scope casing must not change workspace selection.' }
  $fixture.ResourceGroup = 'rg-lab-two'
  Invoke-Setup
  if ($fixture.Selected -eq $scopedName) { throw 'Different labs must have distinct default workspace names.' }
  $fixture.ResourceGroup = 'rg-lab-one'
  $fixture.Subscription = '33333333-3333-3333-3333-333333333333'
  Invoke-Setup
  if ($fixture.Selected -eq $scopedName) { throw 'The same RG name in different subscriptions must be isolated.' }
  $fixture.Subscription = '11111111-1111-1111-1111-111111111111'

  foreach ($configuration in @(
    @{ fabricAutomation = @{ workspaceName = 'configured-workspace' } },
    @{ advancedConfiguration = @{ fabric = @{ fabricAutomation = @{ workspaceName = 'configured-workspace' } } } }
  )) {
    $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
    Invoke-Setup
    if ($fixture.Selected -ne 'configured-workspace') { throw 'Flat and grouped config must select the configured workspace.' }
    Invoke-Setup -Options @{ WorkspaceName = 'explicit-workspace' }
    if ($fixture.Selected -ne 'explicit-workspace') { throw 'Explicit workspace must take precedence over config.' }
    Invoke-Setup -Options @{ WorkspaceName = '' }
    if ($fixture.Selected -ne $scopedName) { throw 'Explicit blank must restore the scoped default, not the configured name.' }
  }
  @{ fabricAutomation = @{ workspaceName = '' } } | ConvertTo-Json | Set-Content -LiteralPath $configPath
  Invoke-Setup
  if ($fixture.Selected -ne $scopedName) { throw 'Blank example config must retain lab isolation.' }
  Remove-Item -LiteralPath $configPath

  $fixture.Workspaces = @(@{ id = 'existing'; displayName = 'Azure Monitor Demo Lab'; capacityId = 'other-capacity' })
  Invoke-Setup
  if ($fixture.Selected -ne $scopedName -or $fixture.Deleted) { throw 'An unrelated legacy workspace must be left alone.' }
  Invoke-Setup -Options @{ Teardown = $true } -Expected ''
  if ($fixture.Created -or $fixture.Deleted) { throw 'Teardown must not touch the unrelated legacy workspace.' }

  foreach ($name in @('Azure Monitor Demo Lab', $scopedName, 'explicit-workspace')) {
    foreach ($capacity in @('other-capacity', '', 'lab-capacity')) {
      $fixture.Workspaces = @(@{ id = 'existing'; displayName = $name; capacityId = $capacity })
      $fixture.DetailCapacity = if ($capacity) { $capacity } else { 'other-capacity' }
      foreach ($teardown in @($false, $true)) {
        $options = @{ WorkspaceName = $name; Teardown = $teardown }
        $expected = if ($capacity -ne 'lab-capacity') { '*refusing to reuse, move, modify or delete*' } elseif ($teardown) { '' } else { 'WORKSPACE VERIFIED' }
        Invoke-Setup -Options $options -Expected $expected
        if ($fixture.Created -or $fixture.Deleted -ne $(if ($teardown -and $capacity -eq 'lab-capacity') { 1 } else { 0 })) {
          throw 'Ownership must be verified before setup mutations or teardown deletes.'
        }
      }
    }
  }
  $fixture.Workspaces = @(@{ id = 'existing'; displayName = 'Azure Monitor Demo Lab'; capacityId = 'lab-capacity' })
  Invoke-Setup
  if ($fixture.Created) { throw 'An owned legacy workspace must be reused without creating a replacement.' }
  Invoke-Setup -Options @{ Teardown = $true } -Expected ''
  if ($fixture.Deleted -ne 1) { throw 'Implicit teardown must select the same owned legacy workspace.' }
  $fixture.Workspaces[0].capacityId = ''
  $fixture.DetailCapacity = 'lab-capacity'
  Invoke-Setup
  if ($fixture.Created) { throw 'Owned legacy reuse must work when capacity ownership requires a detail GET.' }
  $fixture.Workspaces[0].capacityId = 'lab-capacity'
  $fixture.Workspaces += @{ id = 'scoped'; displayName = $scopedName; capacityId = 'other-capacity' }
  Invoke-Setup -Expected '*refusing to reuse, move, modify or delete*'
  if ($fixture.Created -or $fixture.Deleted) { throw 'An existing scoped conflict must fail, not fall back to legacy.' }
  $fixture.Workspaces = @(
    @{ id = 'first'; displayName = $scopedName; capacityId = 'lab-capacity' },
    @{ id = 'second'; displayName = $scopedName; capacityId = 'lab-capacity' }
  )
  Invoke-Setup -Expected '*ambiguous match*'
  $fixture.LookupFailure = $true
  Invoke-Setup -Expected 'Fabric lookup denied.'
  $fixture.LookupFailure = $false
  $fixture.Capacities += @{ id = 'duplicate'; displayName = 'fabtest' }
  Invoke-Setup -Expected '*unambiguous capacity*'

  Set-Content -LiteralPath (Join-Path $directory 'setup-fabric.ps1') -Value @'
[CmdletBinding()]
param($SubscriptionId, $ResourceGroup, $NamePrefix, $WorkspaceName, $MaxOperationMinutes)
$fixture.Forwarded = $PSBoundParameters
'@
  & (Join-Path $directory 'setup-fabric-cloud-shell.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup
  if ($fixture.Forwarded.ContainsKey('WorkspaceName') -or $fixture.Forwarded.ContainsKey('NamePrefix')) {
    throw 'Cloud Shell wrapper defaults must not override configuration.'
  }
  & (Join-Path $directory 'setup-fabric-cloud-shell.ps1') -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup `
    -WorkspaceName 'explicit-workspace' -NamePrefix 'custom'
  if ($fixture.Forwarded.WorkspaceName -ne 'explicit-workspace' -or $fixture.Forwarded.NamePrefix -ne 'custom') {
    throw 'Cloud Shell explicit overrides must reach setup.'
  }
  foreach ($caller in @('deploy.ps1', 'post-cloud-shell-deploy.ps1', 'teardown.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $source $caller) -Raw
    if ($text -notmatch '\[string\]\s*\$FabricWorkspaceName' -or
        $text -notmatch "ContainsKey\('FabricWorkspaceName'\)" -or
        $text -notmatch '\$fabricParameters.WorkspaceName = \$FabricWorkspaceName' -or
        $text -notmatch '@fabricParameters') {
      throw "$caller must hand off only an explicitly supplied Fabric workspace override."
    }
  }
  Write-Output 'PASS: explicit > flat/grouped config > stable per-lab default; Cloud Shell preserves config and explicit overrides. No cloud calls.'
  Write-Output 'PASS: setup/teardown protect unrelated/unassigned/ambiguous workspaces and lookup failures; owned legacy workspaces remain compatible. No cloud calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
