<#
.SYNOPSIS
  Resolve a lab's Service Group ID after the caller's subscription guardrail.
.DESCRIPTION
  Preserve explicit IDs and existing membership targets. Otherwise derive a
  stable tenant-level name from the full subscription/resource-group scope.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ResourceGroup,
  [string] $ServiceGroupId,
  [ValidateNotNullOrEmpty()] [string] $RelationshipId = 'sgm-amlab-rg'
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($ServiceGroupId)) { return $ServiceGroupId }

$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$exists = az group exists --subscription $SubscriptionId -n $ResourceGroup --only-show-errors -o tsv
if ($LASTEXITCODE -ne 0 -or $exists -notin @('true', 'false')) {
  throw "Could not check resource group '$ResourceGroup' when resolving its Service Group."
}
if ($exists -eq 'true') {
  $memberships = @(az resource list --subscription $SubscriptionId -g $ResourceGroup `
    --resource-type Microsoft.Relationships/serviceGroupMember --only-show-errors -o json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect Service Group memberships in '$ResourceGroup'." }
  $membershipId = "$rgScope/providers/Microsoft.Relationships/serviceGroupMember/$RelationshipId"
  $membership = @($memberships | Where-Object { $_.id -ieq $membershipId })
  if ($membership.Count -gt 0) {
    $resource = az resource show --subscription $SubscriptionId --ids $membershipId `
      --api-version 2023-09-01-preview --only-show-errors -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not read Service Group membership '$membershipId'." }
    $targetId = [string]$resource.properties.targetId
    if ($targetId -notmatch '^/?providers/Microsoft\.Management/serviceGroups/([a-zA-Z0-9_().~;-]{1,250})$') {
      throw "Service Group membership '$membershipId' has an invalid targetId; refusing to guess a group."
    }
    return $Matches[1]
  }
}

$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
  [Text.Encoding]::UTF8.GetBytes($rgScope.ToLowerInvariant()))).Substring(0, 12).ToLowerInvariant()
return "amlab-workload-$hash"
