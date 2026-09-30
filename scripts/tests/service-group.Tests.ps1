$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('service-group-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
foreach ($name in @('setup-health-model.ps1', 'resolve-service-group-id.ps1')) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination $directory
}
$fixture = @{
  Subscription = '11111111-1111-1111-1111-111111111111'
  Tenant = '22222222-2222-2222-2222-222222222222'
  ResourceGroup = 'rg-lab-one'; Relationship = 'sgm-amlab-rg'
  Exists = 'true'; Membership = $false; Target = ''; Failure = ''
  Calls = 0; Writes = [Collections.Generic.List[object]]::new()
}
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')
$resolver = Join-Path $directory 'resolve-service-group-id.ps1'

function az {
  $fixture.Calls++
  $global:LASTEXITCODE = 0
  $operation = $args[0..1] -join ' '
  if ($operation -in @('group exists', 'resource list', 'resource show')) {
    if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription) { throw 'Wrong resolution subscription.' }
    if ($fixture.Failure -eq $operation) { $global:LASTEXITCODE = 1; return 'null' }
  }
  switch ($operation) {
    'account set' { }
    'account show' { return @{ id = $fixture.Subscription; tenantId = $fixture.Tenant } | ConvertTo-Json }
    'provider show' { return 'Registered' }
    'group exists' { return $fixture.Exists }
    'resource list' {
      if ($args[[Array]::IndexOf($args, '-g') + 1] -ine $fixture.ResourceGroup) { throw 'Wrong resolution resource group.' }
      if (-not $fixture.Membership) { return '[]' }
      return ConvertTo-Json -InputObject @(@{
        id = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($fixture.ResourceGroup)/providers/Microsoft.Relationships/serviceGroupMember/$($fixture.Relationship)"
      })
    }
    'resource show' {
      $expected = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($fixture.ResourceGroup)/providers/Microsoft.Relationships/serviceGroupMember/$($fixture.Relationship)"
      if ($args[[Array]::IndexOf($args, '--ids') + 1] -ine $expected) { throw 'Wrong membership ID.' }
      return @{ properties = @{ targetId = $fixture.Target } } | ConvertTo-Json
    }
    'rest --method' {
      $url = $args[[Array]::IndexOf($args, '--url') + 1]
      if ($args[2] -eq 'put') {
        $bodyFile = $args[[Array]::IndexOf($args, '--body') + 1]
        $fixture.Writes.Add(@{ Url = $url; Body = (Get-Content -Raw -LiteralPath $bodyFile.Substring(1) | ConvertFrom-Json) })
        return
      }
      if ($args[2] -eq 'get') { return '{"properties":{"provisioningState":"Succeeded"}}' }
      throw 'Unexpected write in Service Group regression.'
    }
    default { throw "Unexpected Azure call: $operation" }
  }
}

function Resolve-TestGroup {
  & $resolver -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup
}

try {
  $first = Resolve-TestGroup
  if ($first -notmatch '^amlab-workload-[0-9a-f]{12}$' -or $first -cne (Resolve-TestGroup)) {
    throw 'Default ID must have a stable scope suffix.'
  }
  $fixture.ResourceGroup = 'RG-LAB-ONE'
  if ($first -cne (Resolve-TestGroup)) { throw 'ARM scope casing must not change the ID.' }
  $fixture.ResourceGroup = 'rg-lab-two'
  $second = Resolve-TestGroup
  if ($first -eq $second) { throw 'Two resource groups in the same subscription must have distinct IDs.' }
  $fixture.ResourceGroup = 'rg-lab-one'
  $fixture.Subscription = '33333333-3333-3333-3333-333333333333'
  if ($first -eq (Resolve-TestGroup)) { throw 'Identically named resource groups in different subscriptions must have distinct IDs.' }
  $fixture.Subscription = '11111111-1111-1111-1111-111111111111'
  $fixture.Exists = 'false'
  if ($first -cne (Resolve-TestGroup)) { throw 'Missing resource groups must resolve deterministically for repeat cleanup.' }
  $fixture.Exists = 'true'

  foreach ($name in @('amlab-workload', $first, 'custom-lab-group')) {
    $fixture.Membership = $true
    foreach ($prefix in @('', '/')) {
      $fixture.Target = "${prefix}providers/Microsoft.Management/serviceGroups/$name"
      if ($name -cne (Resolve-TestGroup)) { throw 'Existing legacy, generated, and custom targets must be preserved.' }
    }
  }
  $fixture.Relationship = 'custom-membership'
  $custom = & $resolver -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup -RelationshipId $fixture.Relationship
  if ($custom -ne 'custom-lab-group') { throw 'Custom membership IDs must be honored.' }
  $fixture.Relationship = 'sgm-amlab-rg'
  $calls = $fixture.Calls
  $explicit = & $resolver -SubscriptionId $fixture.Subscription -ResourceGroup $fixture.ResourceGroup -ServiceGroupId 'explicit-group'
  if ($explicit -ne 'explicit-group' -or $fixture.Calls -ne $calls) { throw 'Explicit IDs must not be replaced or require discovery.' }

  foreach ($failure in @('group exists', 'resource list', 'resource show', 'malformed-target')) {
    $fixture.Failure = $failure
    $fixture.Target = if ($failure -eq 'malformed-target') { '/subscriptions/wrong-scope' } else { '/providers/Microsoft.Management/serviceGroups/amlab-workload' }
    $caught = ''
    try { $null = Resolve-TestGroup } catch { $caught = $_.Exception.Message }
    if (-not $caught) { throw "Resolution must fail closed on $failure." }
  }
  $fixture.Failure = ''; $fixture.Membership = $false
  foreach ($rg in @('rg-lab-one', 'rg-lab-two')) {
    $fixture.ResourceGroup = $rg
    $fixture.Writes.Clear()
    $expected = Resolve-TestGroup
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $rg | Out-Null
    if ($fixture.Writes.Count -ne 2 -or
        $fixture.Writes[0].Url -notlike "*/serviceGroups/$expected`?*" -or
        $fixture.Writes[1].Body.properties.targetId -ne "providers/Microsoft.Management/serviceGroups/$expected" -or
        $fixture.Writes[0].Body.properties.displayName -ne "AMLAB - $rg") {
      throw 'Setup must use the same per-lab ID for the Service Group and membership.'
    }
  }
  $fixture.Membership = $true
  foreach ($name in @('amlab-workload', $second, 'custom-lab-group')) {
    $fixture.Target = "/providers/Microsoft.Management/serviceGroups/$name"
    $fixture.Writes.Clear()
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup | Out-Null
    if ($fixture.Writes[1].Body.properties.targetId -ne "providers/Microsoft.Management/serviceGroups/$name") {
      throw 'Redeploying a lab must not reparent its legacy, generated, or custom membership.'
    }
  }
  $fixture.Writes.Clear()
  & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
    -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
  if ($fixture.Writes[1].Body.properties.targetId -ne 'providers/Microsoft.Management/serviceGroups/explicit-group' -or
      $fixture.Writes[0].Body.properties.displayName -ne 'Explicit display') { throw 'Explicit group IDs and display names must be honored.' }
  Write-Output 'PASS: per-RG/subscription IDs are distinct, stable, case-insensitive, and consistent across group/member setup. No Azure calls.'
  Write-Output 'PASS: legacy/custom memberships and explicit IDs are preserved; discovery errors and malformed targets fail closed. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
