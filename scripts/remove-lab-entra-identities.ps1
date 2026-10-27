<#
.SYNOPSIS
  Plan or remove Entra identities explicitly owned by one lab resource group.
.DESCRIPTION
  Uses ownership tags written at creation, not display-name matching. Untagged
  registrations and shared identities are preserved. Run PlanOnly before passing
  the returned identities back for removal. Requires existing Entra permissions.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Plan')]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [guid] $TenantId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9_.()-]+$')] [string] $ResourceGroup,
  [Parameter(Mandatory, ParameterSetName = 'Plan')] [switch] $PlanOnly,
  [Parameter(Mandatory, ParameterSetName = 'Remove')] [AllowEmptyCollection()] [object[]] $Identities
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup".ToLowerInvariant()
$ownerTag = "azure-monitor-lab:resource-group:$resourceGroupId"
$tenantTag = "azure-monitor-lab:tenant:$($TenantId.ToString().ToLowerInvariant())"
$marker = 'azure-monitor-lab:managed:v1'
$appSelect = 'id,appId,displayName,tags,signInAudience,web,spa,publicClient,identifierUris,requiredResourceAccess'
$principalSelect = 'id,appId,displayName,tags,servicePrincipalType,appOwnerOrganizationId,replyUrls'

az account set --subscription $SubscriptionId --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not select the Entra cleanup subscription.' }
$account = az account show --query '{id:id,tenantId:tenantId,user:user}' -o json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $SubscriptionId.ToString() -or $account.tenantId -ne $TenantId.ToString()) {
  throw 'Entra cleanup subscription or tenant mismatch. No identities were deleted.'
}
$graphToken = az account get-access-token --subscription $SubscriptionId --resource https://graph.microsoft.com/ --query accessToken -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($graphToken)) { throw 'Could not acquire a Microsoft Graph token for Entra cleanup.' }

function Invoke-IdentityRequest {
  param([string] $Method, [string] $Uri, [switch] $AllowNotFound)
  $parsed = [uri]$Uri
  if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or -not $parsed.AbsolutePath.StartsWith('/v1.0/') -or $parsed.UserInfo -or $parsed.Port -ne 443) {
    throw 'Unexpected Entra cleanup endpoint.'
  }
  try {
    Invoke-RestMethod -Method $Method -Uri $Uri -Headers @{ Authorization = "Bearer $graphToken"; ConsistencyLevel = 'eventual' } `
      -TimeoutSec 90 -ErrorAction Stop -Verbose:$false -Debug:$false
  } catch {
    $status = [int]$_.Exception.Response.StatusCode
    if ($AllowNotFound -and $status -eq 404) { return $null }
    throw "Entra cleanup failed: $Method $($parsed.AbsolutePath) (HTTP $status). No permissions were changed. Resolve directory access or use -KeepEntraApplications to preserve identities."
  }
}

function Get-IdentityCollection {
  param([string] $Uri)
  $visited = [Collections.Generic.HashSet[string]]::new()
  while ($Uri) {
    if (-not $visited.Add($Uri) -or $visited.Count -gt 1000) { throw 'Entra cleanup pagination did not complete.' }
    $page = Invoke-IdentityRequest GET $Uri
    if ($null -eq $page.value) { throw 'Entra cleanup received an incomplete collection.' }
    $page.value
    $Uri = $page.'@odata.nextLink'
  }
}

function Test-IdentityOwnership {
  param($Identity)
  $owners = @($Identity.tags | Where-Object { $_ -like 'azure-monitor-lab:resource-group:*' })
  $tenants = @($Identity.tags | Where-Object { $_ -like 'azure-monitor-lab:tenant:*' })
  $kinds = @($Identity.tags | Where-Object { $_ -like 'azure-monitor-lab:kind:*' })
  return @($Identity.tags) -contains $marker -and $owners.Count -eq 1 -and $owners[0] -eq $ownerTag -and
    $tenants.Count -eq 1 -and $tenants[0] -eq $tenantTag -and $kinds.Count -eq 1 -and
    $kinds[0] -in @('azure-monitor-lab:kind:console', 'azure-monitor-lab:kind:rbac-workspace', 'azure-monitor-lab:kind:rbac-table', 'azure-monitor-lab:kind:rbac-row')
}

function Get-VerifiedIdentity {
  param([guid] $AppId)
  $filter = [uri]::EscapeDataString("appId eq '$AppId'")
  $apps = @(Get-IdentityCollection "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=$appSelect")
  $principals = @(Get-IdentityCollection "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=$principalSelect")
  if ($apps.Count -gt 1 -or $principals.Count -gt 1) { throw "Ambiguous Entra identity for client ID '$AppId'." }
  if (-not $apps.Count -and -not $principals.Count) { return $null }
  foreach ($identity in @($apps) + @($principals)) {
    $objectId = [guid]::Empty
    if (-not [guid]::TryParse([string]$identity.id, [ref]$objectId) -or $objectId -eq [guid]::Empty -or $identity.appId -ne $AppId.ToString()) {
      throw "Invalid Entra identity response for client ID '$AppId'."
    }
    if (-not (Test-IdentityOwnership $identity)) {
      Write-Warning "Preserving client ID '$AppId': missing, changed, or shared lab ownership."
      return $null
    }
  }
  if ($account.user.type -eq 'servicePrincipal' -and $account.user.name -eq $AppId.ToString()) {
    Write-Warning "Preserving client ID '$AppId': it is the current deployment identity."
    return $null
  }
  $registration = $apps | Select-Object -First 1
  $principal = $principals | Select-Object -First 1
  if ($registration -and ($registration.signInAudience -ne 'AzureADMyOrg' -or @($registration.identifierUris).Count -gt 0 -or @($registration.requiredResourceAccess).Count -gt 0)) {
    Write-Warning "Preserving client ID '$AppId': its application audience or API configuration has been extended."
    return $null
  }
  if ($principal -and ($principal.servicePrincipalType -ne 'Application' -or $principal.appOwnerOrganizationId -ne $TenantId.ToString())) {
    Write-Warning "Preserving client ID '$AppId': not an application principal owned by this tenant."
    return $null
  }
  $tagSource = if ($registration) { $registration } else { $principal }
  $redirects = @($registration.web.redirectUris) + @($registration.spa.redirectUris) + @($registration.publicClient.redirectUris) + @($principal.replyUrls)
  $redirects = @($redirects | Where-Object { $_ })
  if (@($tagSource.tags) -contains 'azure-monitor-lab:kind:console') {
    $webTags = @($tagSource.tags | Where-Object { $_ -like 'azure-monitor-lab:web-app:*' })
    if ($webTags.Count -ne 1) { Write-Warning "Preserving client ID '$AppId': no unique Web App ownership record."; return $null }
    $webName = $webTags[0].Substring('azure-monitor-lab:web-app:'.Length)
    $callback = "https://$webName.azurewebsites.net/.auth/login/aad/callback"
    if ($webName -notmatch '^[a-zA-Z0-9-]+$' -or @($redirects | Where-Object { $_ -cne $callback }).Count) {
      Write-Warning "Preserving client ID '$AppId': sign-in is configured for another callback."
      return $null
    }
  } elseif ($redirects.Count) {
    Write-Warning "Preserving client ID '$AppId': the RBAC identity has additional sign-in configuration."
    return $null
  }
  if ($principal) {
    foreach ($relationship in @('appRoleAssignments', 'oauth2PermissionGrants', 'memberOf', 'ownedObjects')) {
      if (@(Get-IdentityCollection "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/${relationship}?`$select=id").Count) {
        Write-Warning "Preserving client ID '$AppId': it has additional directory relationships ($relationship)."
        return $null
      }
    }
    foreach ($subscription in $tenantSubscriptions) {
      $assignments = @(az role assignment list --subscription $subscription.id --assignee $principal.id --all `
        --fill-principal-name false --fill-role-definition-name false --output json --only-show-errors | ConvertFrom-Json)
      if ($LASTEXITCODE -ne 0) { throw "Could not verify role scopes for service principal '$($principal.id)'. No identity deletion is safe." }
      if (@($assignments | Where-Object { $_.scope -ine $resourceGroupId -and -not ([string]$_.scope).StartsWith("$resourceGroupId/", [StringComparison]::OrdinalIgnoreCase) }).Count) {
        Write-Warning "Preserving client ID '$AppId': it has Azure roles outside the target lab."
        return $null
      }
    }
  }
  [pscustomobject]@{
    AppId = $AppId.ToString()
    ApplicationObjectId = [string]$registration.id
    ServicePrincipalObjectId = [string]$principal.id
    DisplayName = [string]$tagSource.displayName
    ResourceGroupId = $resourceGroupId
    TenantId = $TenantId.ToString()
  }
}

try {
  $tenantSubscriptions = @(az account list --all --query '[].{id:id,tenantId:tenantId,state:state}' -o json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate subscriptions for shared-identity checks.' }
  $tenantSubscriptions = @($tenantSubscriptions | Where-Object { $_.tenantId -eq $TenantId.ToString() })
  if (-not @($tenantSubscriptions | Where-Object { $_.id -eq $SubscriptionId.ToString() }).Count) { throw 'The verified subscription was missing from account discovery.' }
  if ($PlanOnly) {
    $filter = [uri]::EscapeDataString("tags/any(tag:tag eq '$ownerTag')")
    $ownedObjects = @(Get-IdentityCollection "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,tags&`$count=true") +
      @(Get-IdentityCollection "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$filter&`$select=id,appId,tags&`$count=true")
    foreach ($appId in @($ownedObjects | Select-Object -ExpandProperty appId -Unique)) {
      $identity = Get-VerifiedIdentity -AppId $appId
      if ($identity) { $identity }
    }
    Write-Warning 'Entra cleanup preserves untagged registrations from older setup versions. Those require a separate ownership review; they are never deleted by display name.'
    return
  }

  $verified = @()
  foreach ($planned in $Identities) {
    if ($planned.ResourceGroupId -ine $resourceGroupId -or $planned.TenantId -ne $TenantId.ToString()) { throw 'The identity cleanup plan belongs to another lab or tenant.' }
    $current = Get-VerifiedIdentity -AppId $planned.AppId
    if (-not $current) { continue }
    if (($current.ApplicationObjectId -and $current.ApplicationObjectId -ne $planned.ApplicationObjectId) -or
        ($current.ServicePrincipalObjectId -and $current.ServicePrincipalObjectId -ne $planned.ServicePrincipalObjectId)) {
      throw "Identity object IDs changed since confirmation for '$($planned.AppId)'. Refusing deletion."
    }
    $verified += $current
  }
  foreach ($identity in $verified) {
    if (-not $PSCmdlet.ShouldProcess("$($identity.DisplayName) (client ID $($identity.AppId))", 'Delete the lab-owned Entra service principal and app registration')) { continue }
    if ($identity.ServicePrincipalObjectId) {
      $null = Invoke-IdentityRequest DELETE "https://graph.microsoft.com/v1.0/servicePrincipals/$($identity.ServicePrincipalObjectId)" -AllowNotFound
    }
    if ($identity.ApplicationObjectId) {
      $null = Invoke-IdentityRequest DELETE "https://graph.microsoft.com/v1.0/applications/$($identity.ApplicationObjectId)" -AllowNotFound
    }
    Write-Host "Removed lab-owned Entra identity: $($identity.DisplayName) ($($identity.AppId))"
  }
} finally { $graphToken = $null }