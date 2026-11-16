$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
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
  GroupName = ''; GroupError = ''; GroupResponse = ''
  RequestFailure = ''; Polls = 0; Sleeps = 0; NotFoundRemaining = 0
  RelationshipsRegistered = $false
  Now = [datetime]'2026-01-01T00:00:00Z'
  Responses = [Collections.Generic.Queue[string]]::new()
  Calls = 0; Writes = [Collections.Generic.List[object]]::new()
}
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '.azure-target.json')
$resolver = Join-Path $directory 'resolve-service-group-id.ps1'

function Start-Sleep {
  param([int] $Seconds)
  $fixture.Sleeps++
  $fixture.Now = $fixture.Now.AddSeconds($Seconds)
  if ($fixture.Sleeps -gt 60) { throw 'Polling exceeded the provisioning deadline.' }
}

function Get-Date { return $fixture.Now }

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
    'provider show' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -eq 'Microsoft.Relationships' -and -not $fixture.RelationshipsRegistered) {
        return 'NotRegistered'
      }
      return 'Registered'
    }
    'provider register' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne 'Microsoft.Relationships') { throw 'Unexpected provider registration.' }
      $fixture.RelationshipsRegistered = $true
    }
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
      $resource = if ($url -like '*/Microsoft.Relationships/serviceGroupMember/*') { 'member' } else { 'group' }
      if ($args[2] -eq 'put') {
        $bodyFile = $args[[Array]::IndexOf($args, '--body') + 1]
        $fixture.Writes.Add(@{ Url = $url; BodyFile = $bodyFile.Substring(1); Body = (Get-Content -Raw -LiteralPath $bodyFile.Substring(1) | ConvertFrom-Json) })
        if ($fixture.RequestFailure -eq "$resource-put") {
          $shell = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
          & $shell -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('ERROR: (InvalidTargetScope) Original Azure request diagnostic.'); exit 1"
          $global:LASTEXITCODE = $LASTEXITCODE
        }
        return
      }
      if ($args[2] -eq 'get') {
        if ($url -like '*/Microsoft.Management/serviceGroups/*' -and $fixture.Writes.Count -eq 0) {
          if ($fixture.GroupError) { $global:LASTEXITCODE = 1; return $fixture.GroupError }
          if ($fixture.GroupResponse) { return $fixture.GroupResponse }
          if (-not $fixture.GroupName) { $global:LASTEXITCODE = 1; return 'ERROR: (ResourceNotFound) Service Group does not exist.' }
          return @{ properties = @{ displayName = $fixture.GroupName; provisioningState = 'Succeeded' } } | ConvertTo-Json
        }
        $fixture.Polls++
        if ($fixture.Responses.Count) {
          $response = $fixture.Responses.Dequeue()
          if ($response.StartsWith('ERROR:')) { $global:LASTEXITCODE = 1 }
          return $response
        }
        if ($fixture.RequestFailure -eq "$resource-get") {
          $global:LASTEXITCODE = 1
          return 'ERROR: (AuthorizationFailed) Original Azure polling diagnostic.'
        }
        if ($fixture.RequestFailure -eq "$resource-disguised-notfound") {
          $global:LASTEXITCODE = 1
          return 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"NotFound is not the error code.","details":[{"code":"ResourceNotFound"}]}})'
        }
        if ($fixture.RequestFailure -eq "$resource-notfound" -and $fixture.NotFoundRemaining -gt 0) {
          $fixture.NotFoundRemaining--
          $global:LASTEXITCODE = 1
          return 'ERROR: Not Found({"error":{"code":"NotFound","message":""}})'
        }
        if ($fixture.RequestFailure -eq "$resource-json") { return 'not json' }
        return '{"properties":{"provisioningState":"Succeeded"}}'
      }
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
    if (-not $fixture.RelationshipsRegistered -or $fixture.Writes.Count -ne 2 -or
        $fixture.Writes[0].Url -notlike "*/serviceGroups/$expected`?*" -or
        $fixture.Writes[1].Body.properties.targetId -ne "/providers/Microsoft.Management/serviceGroups/$expected" -or
        $fixture.Writes[0].Body.properties.displayName -ne "AMLAB - $rg") {
      throw 'Setup must use the same per-lab ID for the Service Group and membership.'
    }
  }
  $fixture.Membership = $true
  foreach ($name in @('amlab-workload', $second, 'custom-lab-group')) {
    $fixture.Target = "/providers/Microsoft.Management/serviceGroups/$name"
    $fixture.GroupName = "Preserved name for $name"
    $fixture.Writes.Clear()
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup | Out-Null
    if ($fixture.Writes[1].Body.properties.targetId -ne "/providers/Microsoft.Management/serviceGroups/$name") {
      throw 'Redeploying a lab must not reparent its legacy, generated, or custom membership.'
    }
    if ($fixture.Writes[0].Body.properties.displayName -cne $fixture.GroupName) {
      throw 'Redeploying a lab must preserve its existing Service Group display name.'
    }
  }
  $fixture.Writes.Clear()
  & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
    -ServiceGroupId 'explicit-group' | Out-Null
  if ($fixture.Writes[0].Body.properties.displayName -cne $fixture.GroupName) {
    throw 'An explicit existing group ID must also preserve its display name without an override.'
  }
  foreach ($failure in @(
    @{ Error = 'ERROR: (AuthorizationFailed) Access denied.'; Response = '' },
    @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"NotFound is not the error code.","details":[{"code":"ResourceNotFound"}]}})'; Response = '' },
    @{ Error = 'ERROR: (TooManyRequests) Retry later.'; Response = '' },
    @{ Error = ''; Response = 'not json' },
    @{ Error = ''; Response = '{"properties":{}}' }
  )) {
    $fixture.GroupError = $failure.Error; $fixture.GroupResponse = $failure.Response
    $fixture.Writes.Clear()
    $caught = ''
    try {
      & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup | Out-Null
    } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $fixture.Writes.Count -ne 0) { throw 'Failed or invalid group reads must stop before any PUT.' }
  }
  $fixture.GroupError = ''; $fixture.GroupResponse = ''
  foreach ($notFound in @(
    'ERROR: (ResourceNotFound) Service Group does not exist.',
    'ERROR: Not Found({"error":{"code":"ResourceNotFound","message":"Service Group does not exist."}})',
    'ERROR: Not Found({"error":{"code":"ServiceGroupNameNotFound","message":"ServiceGroup name not found"}})',
    'ERROR: Not Found'
  )) {
    $fixture.GroupError = $notFound
    $fixture.Writes.Clear()
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup | Out-Null
    if ($fixture.Writes[0].Body.properties.displayName -ne "AMLAB - $($fixture.ResourceGroup)") {
      throw 'Confirmed missing groups must receive the per-RG default name.'
    }
  }
  $fixture.GroupError = ''
  $fixture.Writes.Clear()
  & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
    -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
  if ($fixture.Writes[1].Body.properties.targetId -ne '/providers/Microsoft.Management/serviceGroups/explicit-group' -or
      $fixture.Writes[0].Body.properties.displayName -ne 'Explicit display') { throw 'Explicit group IDs and display names must be honored.' }
  foreach ($case in @(
    @{ Failure = 'group-put'; Writes = 1; Polls = 0; Diagnostic = 'InvalidTargetScope' }
    @{ Failure = 'member-put'; Writes = 2; Polls = 1; Diagnostic = 'InvalidTargetScope' }
    @{ Failure = 'group-get'; Writes = 1; Polls = 1; Diagnostic = 'AuthorizationFailed' }
    @{ Failure = 'member-get'; Writes = 2; Polls = 2; Diagnostic = 'AuthorizationFailed' }
    @{ Failure = 'member-disguised-notfound'; Writes = 2; Polls = 2; Diagnostic = 'AuthorizationFailed' }
    @{ Failure = 'group-json'; Writes = 1; Polls = 1; Diagnostic = 'JSON' }
    @{ Failure = 'member-json'; Writes = 2; Polls = 2; Diagnostic = 'JSON' }
  )) {
    $fixture.RequestFailure = $case.Failure
    $fixture.Writes.Clear(); $fixture.Polls = 0; $fixture.Sleeps = 0
    $caught = ''
    try {
      & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
        -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
    } catch { $caught = $_.Exception.Message }
    if (-not $caught.Contains($case.Diagnostic) -or $fixture.Writes.Count -ne $case.Writes -or
        $fixture.Polls -ne $case.Polls -or $fixture.Sleeps -ne 0) {
      throw "Setup must fail immediately with the original diagnostic for $($case.Failure): $caught"
    }
    foreach ($resource in @('group', 'member')) {
      $fixture.RequestFailure = "$resource-notfound"; $fixture.NotFoundRemaining = 2
      $fixture.Writes.Clear(); $fixture.Polls = 0; $fixture.Sleeps = 0
      & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
        -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
      if ($fixture.Polls -ne 4 -or $fixture.Sleeps -ne 2 -or $fixture.Writes.Count -ne 2) {
        throw 'An accepted write must tolerate temporary NotFound responses without submitting another PUT.'
      }
    }
    foreach ($write in $fixture.Writes) {
      if (Test-Path -LiteralPath $write.BodyFile) { throw 'Request body temporary files must be removed after failure.' }
    }
  }
  $authorization = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Management/serviceGroups/read' over scope '/providers/Microsoft.Management/serviceGroups/explicit-group'."
  foreach ($responses in @(
    @('ERROR: (ResourceNotFound) Not visible.', $authorization, '{"properties":{"provisioningState":"Creating"}}', '{"properties":{"provisioningState":"Succeeded"}}'),
    @('ERROR: Not Found', 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"Action Microsoft.Management/serviceGroups/read is not authorized."}})', '{"properties":{"provisioningState":"Succeeded"}}')
  )) {
    $fixture.RequestFailure = ''
    $fixture.Responses.Clear()
    foreach ($response in $responses) { $fixture.Responses.Enqueue($response) }
    $fixture.Writes.Clear(); $fixture.Polls = 0; $fixture.Sleeps = 0
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
      -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
    if ($fixture.Writes.Count -ne 2 -or $fixture.Polls -ne ($responses.Count + 1) -or $fixture.Sleeps -ne ($responses.Count - 1)) {
      throw 'Service-group post-write read authorization propagation must recover without resubmitting writes.'
    }
  }
  foreach ($response in @(
    $authorization, 'ERROR: (ResourceNotFound) Still not visible.',
    'ERROR: (Forbidden) Microsoft.Management/serviceGroups/read',
    'ERROR: (AuthorizationFailed) Microsoft.Management/serviceGroups/write',
    'ERROR: (AuthorizationFailed) Microsoft.Management/serviceGroups/readOther',
    'ERROR: (InternalServerError) Unexpected service failure.',
    '{"properties":{}}', '{"properties":{"provisioningState":"Unexpected"}}', 'null',
    '[{"properties":{"provisioningState":"Succeeded"}}]', '{"properties":{"provisioningState":["Succeeded"]}}',
    '{"properties":"Succeeded"}', '{}',
    '{"properties":{"provisioningState":"Failed"}}', '{"properties":{"provisioningState":"Canceled"}}'
  )) {
    $retryable = $response -in @($authorization, 'ERROR: (ResourceNotFound) Still not visible.')
    $fixture.Responses.Clear()
    $expectedPolls = if ($retryable) { 60 } else { 1 }
    for ($i = 0; $i -lt $expectedPolls; $i++) { $fixture.Responses.Enqueue($response) }
    $fixture.Writes.Clear(); $fixture.Polls = 0; $fixture.Sleeps = 0
    $caught = ''
    try {
      & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
        -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
    } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $fixture.Writes.Count -ne 1 -or $fixture.Polls -ne $expectedPolls -or
        $fixture.Sleeps -ne $(if ($retryable) { 60 } else { 0 })) {
      throw "Polling must fail closed with bounded retries: $response; $caught"
    }
    if ($retryable -and ($caught -notlike '*within 300 seconds*' -or -not $caught.Contains($response))) {
      throw 'Exhaustion must retain the final Azure diagnostic and timeout, not report success.'
    }
  }
  $fixture.Responses.Enqueue('{"properties":{"provisioningState":"Succeeded"}}')
  $fixture.Responses.Enqueue($authorization)
  $fixture.Writes.Clear(); $fixture.Polls = 0; $fixture.Sleeps = 0
  $caught = ''
  try {
    & (Join-Path $directory 'setup-health-model.ps1') -ResourceGroup $fixture.ResourceGroup `
      -ServiceGroupId 'explicit-group' -ServiceGroupDisplayName 'Explicit display' | Out-Null
  } catch { $caught = $_.Exception.Message }
  if (-not $caught.Contains('AuthorizationFailed') -or $fixture.Polls -ne 2 -or $fixture.Sleeps -ne 0) {
    throw 'Member polling must not retry authorization errors, even when they mention service-group read.'
  }
  Write-Output 'PASS: per-RG/subscription IDs are distinct, stable, case-insensitive, and consistent across group/member setup. No Azure calls.'
  Write-Output 'PASS: legacy/custom memberships and explicit IDs are preserved; discovery errors and malformed targets fail closed. No Azure calls.'
  Write-Output 'PASS: existing display names are preserved unless explicitly overridden; failed group reads cannot cause writes. No Azure calls.'
  Write-Output 'PASS: canonical membership targets and failed PUT/GET/JSON responses stop immediately with diagnostics and clean up request files. No Azure calls.'
  Write-Output 'PASS: accepted service-group writes recover from read-authorization propagation and NotFound; exhaustion fails with diagnostics. Other authorization/errors/invalid/failed states fail immediately. No Azure calls.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
  $global:LASTEXITCODE = $previousExitCode
}
