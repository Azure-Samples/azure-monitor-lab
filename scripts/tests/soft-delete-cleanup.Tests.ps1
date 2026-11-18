$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'remove-lab-soft-deleted-resources.ps1'
$subscription = '11111111-1111-1111-1111-111111111111'
$tenant = '22222222-2222-2222-2222-222222222222'
$group = 'rg-purge-test'
$scope = "/subscriptions/$subscription/resourceGroups/$group"
$state = @{
  Items = @(); Changes = [Collections.Generic.List[string]]::new()
  Error = ''; BadTenant = $false; GroupExists = $true; Sleeps = 0
  Delay = 0; Stuck = $false; WrongLiveId = $false; Page = $false; ListReads = 0
  BadOriginalId = $false; BadNextLink = $false; BadInventory = ''
}
$arguments = @{ SubscriptionId = $subscription; TenantId = $tenant; ResourceGroups = @($group); VerificationTimeoutSeconds = 30 }

function New-TestResource {
  param([string] $Type, [string] $Name, [string] $Status = 'Live', [string] $Prefix = $scope)
  @{
    id = "$Prefix/providers/$Type/$Name"; type = $Type; name = $Name
    location = 'swedencentral'; properties = @{ replication = @{ enabled = $true } }
    Status = $Status; Remaining = 0
  }
}
function Start-Sleep {
  param($Seconds)
  if ($Seconds -ne 10) { throw 'Unexpected polling interval.' }
  $state.Sleeps++
}
function az {
  $global:LASTEXITCODE = 0
  if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $subscription) { throw 'Lost explicit subscription.' }
  $command = $args[0..1] -join ' '
  if ($state.Error -and $command -eq $state.Error) {
    $global:LASTEXITCODE = 1
    return 'ERROR: (AuthorizationFailed) Test permission denied.'
  }
  if ($command -eq 'account show') {
    return @{ id = $subscription; tenantId = $(if ($state.BadTenant) { 'other' } else { $tenant }) } | ConvertTo-Json
  }
  if ($command -eq 'resource list') {
    if ($args[[Array]::IndexOf($args, '-g') + 1] -ne $group) { throw 'Unexpected live inventory group.' }
    if ($state.BadInventory -eq 'live') { return '{}' }
    return ConvertTo-Json -InputObject @($state.Items | Where-Object { $_.Status -eq 'Live' -and $_.id.StartsWith("$scope/") }) -Depth 8
  }
  if ($command -eq 'resource show') {
    $id = $args[[Array]::IndexOf($args, '--ids') + 1]
    $item = $state.Items | Where-Object { $_.id -ieq $id -and $_.Status -eq 'Live' } | Select-Object -First 1
    if (-not $item) { $global:LASTEXITCODE = 3; return "ERROR: (ResourceNotFound) '$id' is absent." }
    if ($state.WrongLiveId) { return @{ id = "$id-other" } | ConvertTo-Json }
    return $item | ConvertTo-Json -Depth 8
  }
  if ($command -eq 'rest --method') {
    if ($args[[Array]::IndexOf($args, '--method') + 1] -ne 'get') { throw 'Only read-only REST is expected.' }
    $uri = [uri]$args[[Array]::IndexOf($args, '--url') + 1]
    $type = switch -Regex ($uri.AbsolutePath) {
      '/Microsoft.KeyVault/deletedVaults$' { 'Microsoft.KeyVault/vaults' }
      '/Microsoft.CognitiveServices/deletedAccounts$' { 'Microsoft.CognitiveServices/accounts' }
      '/Microsoft.OperationalInsights/deletedWorkspaces$' { 'Microsoft.OperationalInsights/workspaces' }
      default { throw 'Unexpected deleted-resource inventory.' }
    }
    $state.ListReads++
    $items = @($state.Items | Where-Object { $_.type -eq $type })
    foreach ($item in $items) {
      if ($item.Status -in @('Deleting', 'Purging') -and -not $state.Stuck) {
        if ($item.Remaining -gt 0) { $item.Remaining-- } else {
          $item.Status = if ($item.Status -eq 'Deleting') { 'Deleted' } else { 'Absent' }
        }
      }
    }
    $deleted = @($items | Where-Object { $_.Status -in @('Deleted', 'Purging') } | ForEach-Object {
      if ($type -eq 'Microsoft.KeyVault/vaults') {
        @{ id = "/subscriptions/$subscription/providers/Microsoft.KeyVault/locations/$($_.location)/deletedVaults/$($_.name)"
          name = $_.name; properties = @{ vaultId = $_.id; location = $_.location; purgeProtectionEnabled = $_.properties.enablePurgeProtection } }
      } else { $_ }
    })
    $result = @{ value = $deleted }
    if ($state.BadInventory -eq 'deleted') { $result.value = $null }
    if ($state.BadOriginalId -and $type -eq 'Microsoft.KeyVault/vaults') {
      $result.value = @(@{ name = 'unknown'; properties = @{ location = 'swedencentral' } })
    }
    if ($state.Page -and $uri.Query -notmatch 'page=2') {
      $result.value = @()
      $result.nextLink = "$($uri.AbsoluteUri)&page=2"
    }
    if ($state.BadNextLink) { $result.nextLink = 'https://other.invalid/subscriptions/other' }
    return $result | ConvertTo-Json -Depth 8
  }
  if ($command -eq 'group exists') { return $state.GroupExists.ToString().ToLowerInvariant() }
  if ($command -eq 'group create') {
    if ($args[[Array]::IndexOf($args, '-n') + 1] -ne $group) { throw 'Recovery escaped original group.' }
    $state.Changes.Add('group:create')
    $state.GroupExists = $true
    return
  }
  if ($command -eq 'resource delete' -or $command -eq 'keyvault purge' -or $command -eq 'cognitiveservices account' -or $command -eq 'monitor log-analytics') {
    $operation = if ($command -eq 'monitor log-analytics') { $args[3] } elseif ($command -eq 'cognitiveservices account') { $args[2] } else { $args[1] }
    $item = if ($args -contains '--ids') {
      $id = $args[[Array]::IndexOf($args, '--ids') + 1]
      $state.Items | Where-Object { $_.id -eq $id } | Select-Object -First 1
    } else {
      $flag = if ($args -contains '--name') { '--name' } else { '-n' }
      $name = $args[[Array]::IndexOf($args, $flag) + 1]
      $state.Items | Where-Object { $_.name -eq $name } | Select-Object -First 1
    }
    if (-not $item -or -not $item.id.StartsWith("$scope/")) { throw 'Mutation escaped the approved plan.' }
    if ($command -in @('keyvault purge', 'cognitiveservices account') -and
        $args[[Array]::IndexOf($args, '--location') + 1] -ne $item.location) { throw 'Purge used wrong location.' }
    if ($command -eq 'cognitiveservices account' -and
        $args[[Array]::IndexOf($args, '-g') + 1] -ne $group) { throw 'Foundry purge lost original group.' }
    $state.Changes.Add("$operation`:$($item.name)")
    switch ($operation) {
      'recover' {
        if (-not $state.GroupExists) { throw 'Missing workspace group during recovery.' }
        $item.Status = 'Live'
      }
      'update' { $item.properties.replication.enabled = $false }
      'delete' {
        if ($command -eq 'monitor log-analytics') {
          if ($args -notcontains '--force' -or $args -notcontains '--yes' -or $item.properties.replication.enabled) { throw 'Workspace deletion must bypass soft delete after replication is disabled.' }
          $item.Status = 'Absent'
        } else { $item.Status = 'Deleting'; $item.Remaining = $state.Delay }
      }
      'purge' { $item.Status = 'Purging'; $item.Remaining = $state.Delay }
      default { throw 'Unexpected mutation.' }
    }
    return
  }
  throw "Unexpected Azure command: $($args -join ' ')"
}
function Assert-Failure {
  param([scriptblock] $Action, [string] $Expected)
  $failure = ''
  try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike $Expected) { throw "Expected '$Expected', got '$failure'." }
}

$types = @('Microsoft.KeyVault/vaults', 'Microsoft.CognitiveServices/accounts', 'Microsoft.OperationalInsights/workspaces')
foreach ($status in @('Live', 'Deleted')) {
  $state.Items = @(
    New-TestResource $types[0] 'kv-test' $status
    New-TestResource $types[1] 'ai-test' $status
    New-TestResource $types[2] 'law-test' $status
    New-TestResource $types[0] 'kv-other' 'Deleted' "${scope}-other"
    New-TestResource $types[1] 'ai-other' 'Deleted' ($scope.Replace($subscription, $tenant))
    New-TestResource $types[2] 'law-other' 'Deleted' "${scope}-other"
  )
  $state.Page = $true; $state.Changes.Clear()
  $plan = @(& $script @arguments -ExistingResourceGroups @($group) -PlanOnly)
  if ($plan.Count -ne 3 -or $state.Changes.Count -or @($plan | Where-Object { $_.ResourceGroup -ne $group }).Count) { throw 'Plan must include only exact original resource IDs without changes, across all pages.' }
  & $script @arguments -Resources $plan -WhatIf | Out-Null
  if ($state.Changes.Count) { throw 'WhatIf must not change anything.' }
  $state.Page = $false; $state.GroupExists = $status -eq 'Live'; $state.Delay = 1; $state.Sleeps = 0
  & $script @arguments -Resources $plan -Confirm:$false | Out-Null
  if (@($state.Items | Where-Object { $_.id.StartsWith("$scope/") -and $_.Status -ne 'Absent' }).Count -or $state.Sleeps -lt 2) { throw 'All selected resources must be verified permanently absent after delayed deletion and purge.' }
  if ($status -eq 'Deleted' -and ($state.Changes -notcontains 'group:create' -or $state.Changes -notcontains 'recover:law-test')) { throw 'Deleted workspace recovery must recreate only its original group.' }
  $before = $state.Changes.Count
  & $script @arguments -Resources $plan -Confirm:$false | Out-Null
  if ($state.Changes.Count -ne $before) { throw 'An already purged resource must be idempotent.' }
}
$state.Items = @()
$empty = @(& $script @arguments -ExistingResourceGroups @($group) -PlanOnly)
if ($empty.Count) { throw 'Empty inventories must produce an empty plan.' }
$state.Changes.Clear()
$state.BadInventory = 'live'
Assert-Failure { & $script @arguments -ExistingResourceGroups @($group) -PlanOnly } '*Invalid resource inventory*'
$state.BadInventory = 'deleted'
Assert-Failure { & $script @arguments -PlanOnly } '*Invalid deleted-resource inventory*'
$state.BadInventory = ''
if ($state.Changes.Count) { throw 'Invalid inventory must fail without changes, not be treated as an empty result.' }
$state.Items = @(New-TestResource $types[0] 'kv-test')
$state.Changes.Clear()
$plan = @(& $script @arguments -ExistingResourceGroups @($group) -PlanOnly)
$state.BadTenant = $true
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*subscription or tenant mismatch*'
$state.BadTenant = $false
$invalid = $plan[0].PSObject.Copy()
$invalid.ResourceGroup = 'rg-other'
Assert-Failure { & $script @arguments -Resources @($invalid) -Confirm:$false } '*out-of-scope*'
$state.WrongLiveId = $true
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*Unexpected resource returned*'
$state.WrongLiveId = $false
$state.Items[0].location = 'eastus'
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*Live resource location changed*'
$state.Items[0].location = 'swedencentral'
$state.BadOriginalId = $true
Assert-Failure { & $script @arguments -PlanOnly } '*Invalid original resource ID*No scope was assumed*'
$state.BadOriginalId = $false
$state.BadNextLink = $true
Assert-Failure { & $script @arguments -PlanOnly } '*Invalid or repeated*URL*'
$state.BadNextLink = $false
$state.Items[0].properties.enablePurgeProtection = $true
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*purge protection*'
if ($state.Changes.Count) { throw 'Guard failures must precede all changes.' }
$protectedPlan = @(& $script @arguments -ExistingResourceGroups @($group) -PlanOnly)
if (-not $protectedPlan[0].PurgeProtected) { throw 'Live purge protection must be included in the plan.' }
$state.Items[0].Status = 'Deleted'
$protectedPlan = @(& $script @arguments -PlanOnly)
if (-not $protectedPlan[0].PurgeProtected) { throw 'Deleted purge protection must be included in the plan.' }
$state.Items[0].properties.enablePurgeProtection = $false
$state.Error = 'keyvault purge'
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*AuthorizationFailed*Test permission denied*'
$state.Error = 'rest --method'
Assert-Failure { & $script @arguments -PlanOnly } '*AuthorizationFailed*Test permission denied*'
$state.Error = 'resource show'
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*No absence was assumed*AuthorizationFailed*'
$state.Error = ''
$state.Items[0].Status = 'Live'; $state.Stuck = $true; $state.Sleeps = 0
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*not verified*visible in soft-deleted inventory*30s*'
if ($state.Sleeps -ne 2) { throw 'Visibility polling must be bounded.' }
$state.Items[0].Status = 'Deleted'; $state.Sleeps = 0
Assert-Failure { & $script @arguments -Resources $plan -Confirm:$false } '*not verified*absent from both*30s*'
if ($state.Sleeps -ne 2) { throw 'Purge completion polling must be bounded.' }
Write-Output 'PASS: exact RG/subscription scope, pagination, locations, read-only plans, WhatIf, live/deleted purge, workspace recovery/replication, retries, inventory shapes, guards, protection, diagnostics and bounded verification. No Azure calls.'
