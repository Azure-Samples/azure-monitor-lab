<#
.SYNOPSIS
  Plan or permanently remove name-reserving resources in exact approved lab groups.
.DESCRIPTION
  Called by teardown before resource-group deletion. Discovery is read-only.
  Execution requires the previously displayed plan and never expands its scope.
  Deleted Log Analytics workspaces are recovered before force deletion; missing
  groups are recreated only for that recovery and must be deleted by the caller.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [string[]] $ResourceGroups,
  [string[]] $ExistingResourceGroups = @(),
  [switch] $PlanOnly,
  [object[]] $Resources = @(),
  [ValidateRange(1, 1800)] [int] $VerificationTimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$resourceTypes = [ordered]@{
  'Microsoft.KeyVault/vaults' = @{ Api = '2024-11-01'; Deleted = 'Microsoft.KeyVault/deletedVaults' }
  'Microsoft.CognitiveServices/accounts' = @{ Api = '2024-10-01'; Deleted = 'Microsoft.CognitiveServices/deletedAccounts' }
  'Microsoft.OperationalInsights/workspaces' = @{ Api = '2025-02-01'; Deleted = 'Microsoft.OperationalInsights/deletedWorkspaces' }
}

function Invoke-CleanupAz {
  param([string[]] $Arguments)
  $output = az @Arguments --subscription $SubscriptionId --only-show-errors 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    throw "Soft-delete cleanup failed (az $($Arguments -join ' ')). Azure details:`n$output"
  }
  return $output
}

function Get-DeletedCleanupResources {
  param([string] $Type)
  $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/$($resourceTypes[$Type].Deleted)?api-version=$($resourceTypes[$Type].Api)"
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  while ($url) {
    $uri = [uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or
        $uri.AbsolutePath -ine "/subscriptions/$SubscriptionId/providers/$($resourceTypes[$Type].Deleted)" -or
        -not $seen.Add($url)) {
      throw "Invalid or repeated soft-deleted resource inventory URL: $url"
    }
    $page = Invoke-CleanupAz @('rest', '--method', 'get', '--url', $url, '-o', 'json') | ConvertFrom-Json
    if (-not $page -or $page.value -isnot [array]) { throw "Invalid deleted-resource inventory for '$Type'." }
    $page.value
    $url = $page.nextLink
  }
}

function ConvertTo-CleanupResource {
  param($Resource, [string] $Type, [switch] $Deleted)
  $id = if ($Deleted -and $Type -eq 'Microsoft.KeyVault/vaults') { $Resource.properties.vaultId } else { $Resource.id }
  $pattern = '^/subscriptions/(?<subscription>[^/]+)/resourceGroups/(?<group>[^/]+)/providers/' +
    [regex]::Escape($Type) + '/(?<name>[^/]+)$'
  if (-not $id -or $id -notmatch $pattern) {
    throw "Invalid original resource ID in cleanup inventory for '$Type': '$id'. No scope was assumed."
  }
  $originalSubscription = $Matches.subscription
  $group = $Matches.group
  $name = $Matches.name
  if ($originalSubscription -ine $SubscriptionId.ToString() -or $group -notin $ResourceGroups) {
    if (-not $Deleted) { throw "Live cleanup inventory escaped the approved groups: '$id'." }
    return
  }
  $location = if ($Deleted -and $Type -eq 'Microsoft.KeyVault/vaults') { $Resource.properties.location } else { $Resource.location }
  if ([string]::IsNullOrWhiteSpace($location)) { throw "Missing cleanup resource location: '$id'." }
  [pscustomobject]@{
    Id = $id; Type = $Type; Name = $name; ResourceGroup = $group; Location = $location
    Deleted = [bool]$Deleted
    PurgeProtected = ($Resource.properties.enablePurgeProtection -eq $true -or $Resource.properties.purgeProtectionEnabled -eq $true)
  }
}

function Get-LiveCleanupResource {
  param($Resource)
  $output = az resource show --ids $Resource.Id --api-version $resourceTypes[$Resource.Type].Api `
    --subscription $SubscriptionId -o json --only-show-errors 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    if ($output -match '(?m)^\s*ERROR:\s*\((ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound)\)') { return }
    throw "Could not verify cleanup resource '$($Resource.Id)'. No absence was assumed. Azure details:`n$output"
  }
  $live = $output | ConvertFrom-Json
  if ($live.id -ine $Resource.Id) { throw "Unexpected resource returned while checking '$($Resource.Id)'." }
  return $live
}

function Find-DeletedCleanupResource {
  param($Resource)
  foreach ($item in @(Get-DeletedCleanupResources -Type $Resource.Type)) {
    $candidate = ConvertTo-CleanupResource -Resource $item -Type $Resource.Type -Deleted
    if ($candidate -and $candidate.Id -ieq $Resource.Id) { return $candidate }
  }
}

function Wait-DeletedCleanupResource {
  param($Resource, [switch] $Absent)
  $deadline = [DateTime]::UtcNow.AddSeconds($VerificationTimeoutSeconds)
  $attempts = [Math]::Max(1, [Math]::Ceiling($VerificationTimeoutSeconds / 10))
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $deleted = Find-DeletedCleanupResource $Resource
    if ($Absent -and -not $deleted -and -not (Get-LiveCleanupResource $Resource)) { return }
    if (-not $Absent -and $deleted) { return $deleted }
    if ($attempt -eq $attempts - 1 -or [DateTime]::UtcNow.AddSeconds(10) -ge $deadline) { break }
    Start-Sleep -Seconds 10
  }
  $expected = if ($Absent) { 'absent from both live and soft-deleted inventory' } else { 'visible in soft-deleted inventory' }
  throw "Resource '$($Resource.Id)' was not verified $expected within ${VerificationTimeoutSeconds}s. Name reuse is not verified; rerun teardown after checking the Azure operation."
}

$account = Invoke-CleanupAz @('account', 'show', '-o', 'json') | ConvertFrom-Json
if ($account.id -ine $SubscriptionId.ToString() -or $account.tenantId -ine $TenantId.ToString()) {
  throw 'Soft-delete cleanup subscription or tenant mismatch. No changes were made.'
}
if ($PlanOnly) {
  $plan = @{}
  foreach ($group in $ExistingResourceGroups) {
    if ($group -notin $ResourceGroups) { throw "Unapproved cleanup inventory group: '$group'." }
    $inventory = Invoke-CleanupAz @('resource', 'list', '-g', $group, '-o', 'json') | ConvertFrom-Json -NoEnumerate
    if ($inventory -isnot [array]) { throw "Invalid resource inventory for '$group'." }
    foreach ($item in $inventory) {
      if ($item.type -notin $resourceTypes.Keys) { continue }
      $resource = ConvertTo-CleanupResource $item $item.type
      $details = Get-LiveCleanupResource $resource
      if (-not $details) { throw "Resource '$($resource.Id)' disappeared during cleanup planning; rerun teardown." }
      $plan[$resource.Id] = ConvertTo-CleanupResource $details $item.type
    }
  }
  foreach ($type in $resourceTypes.Keys) {
    foreach ($item in @(Get-DeletedCleanupResources -Type $type)) {
      $resource = ConvertTo-CleanupResource $item $type -Deleted
      if ($resource -and -not $plan.ContainsKey($resource.Id)) { $plan[$resource.Id] = $resource }
    }
  }
  $plan.Values | Sort-Object Id
  return
}

# Validate the entire supplied plan before submitting any changes.
foreach ($resource in $Resources) {
  if ($resource.Type -notin $resourceTypes.Keys -or
      $resource.Id -ine "/subscriptions/$SubscriptionId/resourceGroups/$($resource.ResourceGroup)/providers/$($resource.Type)/$($resource.Name)" -or
      $resource.ResourceGroup -notin $ResourceGroups -or
      $resource.Name -match '[/\\]' -or [string]::IsNullOrWhiteSpace($resource.Location)) {
    throw 'Invalid or out-of-scope permanent cleanup plan. No changes were made.'
  }
  if ($resource.PurgeProtected) {
    throw "Key Vault '$($resource.Id)' has purge protection. It cannot be bypassed; wait for retention expiry or run teardown without -PurgeSoftDeletedResources."
  }
}
foreach ($resource in $Resources) {
  if (-not $PSCmdlet.ShouldProcess($resource.Id, 'Permanently delete data and release the resource name (recover workspace/group if needed)')) { continue }
  $live = Get-LiveCleanupResource $resource
  $deleted = Find-DeletedCleanupResource $resource
  if (-not $live -and -not $deleted) {
    Write-Host "Permanent cleanup already verified: $($resource.Id)" -ForegroundColor DarkGray
    continue
  }
  if ($live -and $live.location -ine $resource.Location) {
    throw "Live resource location changed for '$($resource.Id)'; rerun teardown before deleting it."
  }
  if ($live.properties.enablePurgeProtection -eq $true -or $deleted.PurgeProtected) {
    throw "Key Vault '$($resource.Id)' has purge protection; no purge was submitted. Wait for retention expiry or run teardown without -PurgeSoftDeletedResources."
  }
  Write-Host "Permanently removing $($resource.Id) ..." -ForegroundColor Yellow
  if ($resource.Type -eq 'Microsoft.OperationalInsights/workspaces') {
    if (-not $live) {
      $exists = Invoke-CleanupAz @('group', 'exists', '-n', $resource.ResourceGroup, '-o', 'json') | ConvertFrom-Json
      if ($exists -isnot [bool]) { throw "Invalid group existence response for '$($resource.ResourceGroup)'." }
      if (-not $exists) {
        Invoke-CleanupAz @('group', 'create', '-n', $resource.ResourceGroup, '--location', $resource.Location, '-o', 'none') | Out-Null
      }
      Invoke-CleanupAz @('monitor', 'log-analytics', 'workspace', 'recover', '-g', $resource.ResourceGroup, '-n', $resource.Name, '-o', 'none') | Out-Null
      $live = Get-LiveCleanupResource $resource
      if (-not $live) { throw "Workspace recovery did not restore '$($resource.Id)'." }
    }
    if ($live.properties.replication.enabled -eq $true) {
      Invoke-CleanupAz @('monitor', 'log-analytics', 'workspace', 'update', '-g', $resource.ResourceGroup, '-n', $resource.Name, '--replication-enabled', 'false', '-o', 'none') | Out-Null
    }
    Invoke-CleanupAz @('monitor', 'log-analytics', 'workspace', 'delete', '--ids', $resource.Id, '--force', 'true', '--yes', '-o', 'none') | Out-Null
  } else {
    if ($live) {
      Invoke-CleanupAz @('resource', 'delete', '--ids', $resource.Id, '--api-version', $resourceTypes[$resource.Type].Api, '-o', 'none') | Out-Null
      $deleted = Wait-DeletedCleanupResource $resource
    }
    if ($deleted.PurgeProtected) { throw "Key Vault '$($resource.Id)' has purge protection; wait for retention expiry or run teardown without -PurgeSoftDeletedResources." }
    if ($deleted.Location -ine $resource.Location) { throw "Deleted resource location changed for '$($resource.Id)'; rerun teardown." }
    if ($resource.Type -eq 'Microsoft.KeyVault/vaults') {
      Invoke-CleanupAz @('keyvault', 'purge', '--name', $resource.Name, '--location', $resource.Location, '-o', 'none') | Out-Null
    } else {
      Invoke-CleanupAz @('cognitiveservices', 'account', 'purge', '--name', $resource.Name, '-g', $resource.ResourceGroup, '--location', $resource.Location, '-o', 'none') | Out-Null
    }
  }
  Wait-DeletedCleanupResource $resource -Absent
  Write-Host "Permanent cleanup verified: $($resource.Id)" -ForegroundColor Green
}
