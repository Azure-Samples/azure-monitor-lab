<#
.SYNOPSIS
  Create the Azure Service Group + RG-member relationship that complements the
  Health Model deployed by main.bicep (scenario 45).

.DESCRIPTION
  The Health Model resource + entities + relationships + signals are now created
  by `infra/modules/health-model.bicep` as part of the regular `deploy.ps1`
  run. This helper only handles the two preview, tenant-scoped resources that
  can't sit inside the RG-scoped Bicep deployment:

    1. Microsoft.Management/serviceGroups/<groupId>          (tenant scope)
    2. Microsoft.Relationships/serviceGroupMember/<sgmId>    (RG extension)

  The service group is what the Health Model's "discovery rule" can later
  point at if you want the portal to auto-add additional members. The lab
  itself doesn't depend on it -- the Bicep-deployed model is fully populated
  on its own. Run this if you want the optional service-group surface.

.PARAMETER ResourceGroup
  Lab RG attached as the (single) member of the service group.

.PARAMETER ServiceGroupId
  ARM resource id segment. Alphanumeric + - _ ( ) . ~ ; max 250 chars; globally
  unique within the tenant. Defaults to the existing RG membership target, or
  amlab-workload-<scope-hash> for a new lab. The hash includes subscription and RG.

.PARAMETER ServiceGroupDisplayName
  Explicit display-name override. Otherwise preserve the existing group's name,
  or use AMLAB - <resource-group> when creating a new group.

.PARAMETER Teardown
  Remove the member relationship and the service group. Idempotent (DELETE).

.NOTES
  Permissions required:
    * Tenant root: any signed-in user can create a service group; creator becomes
      Service Group Administrator.
    * On the RG: Microsoft.Relationship/write (Contributor on the RG is enough).

  API versions:
    * Microsoft.Management/serviceGroups         : 2024-02-01-preview
    * Microsoft.Relationships/serviceGroupMember : 2023-09-01-preview
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup           = 'rg-azure-monitor-lab',
  [string] $ServiceGroupId,
  [string] $ServiceGroupDisplayName,
  [string] $RelationshipId          = 'sgm-amlab-rg',
  [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- Subscription guardrail ----------------------------------------------------
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription ($($target.expectedSubscriptionId)). Aborting."
  }
  Write-Info "Subscription guardrail OK ($($active.id))."
} else {
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
}

$subId    = $active.id
$tenantId = $active.tenantId
$ServiceGroupId = & (Join-Path $PSScriptRoot 'resolve-service-group-id.ps1') `
  -SubscriptionId $subId -ResourceGroup $ResourceGroup -ServiceGroupId $ServiceGroupId -RelationshipId $RelationshipId
Write-Info "Tenant   : $tenantId"
Write-Info "Sub      : $subId"
Write-Info "RG       : $ResourceGroup"
Write-Info "Group ID : $ServiceGroupId"

# --- Resource provider registration -------------------------------------------
function Register-Provider {
  param([string] $Namespace)
  $state = az provider show -n $Namespace --query registrationState -o tsv 2>$null
  if ($state -eq 'Registered') { Write-Info "$Namespace : already Registered"; return }
  if (-not $state) {
    Write-Warn "$Namespace : not visible on this subscription, skipping."
    return
  }
  Write-Info "$Namespace : current state = $state, registering..."
  az provider register -n $Namespace --only-show-errors | Out-Null
  while ((az provider show -n $Namespace --query registrationState -o tsv) -eq 'Registering') {
    Write-Info "$Namespace : still Registering..."
    Start-Sleep -Seconds 10
  }
  $final = az provider show -n $Namespace --query registrationState -o tsv
  Write-Info "$Namespace : $final"
  if ($final -ne 'Registered') {
    throw "$Namespace failed to register (final state: $final)."
  }
}

if (-not $Teardown) {
  Write-Step "Ensuring required resource providers are registered"
  Register-Provider -Namespace 'Microsoft.Management'
}

# --- API endpoints -------------------------------------------------------------
$sgApi   = '2024-02-01-preview'
$sgmApi  = '2023-09-01-preview'
$sgUrl   = "https://management.azure.com/providers/Microsoft.Management/serviceGroups/$ServiceGroupId" + "?api-version=$sgApi"
$rgScope = "/subscriptions/$subId/resourceGroups/$ResourceGroup"
$sgmUrl  = "https://management.azure.com$rgScope/providers/Microsoft.Relationships/serviceGroupMember/$RelationshipId" + "?api-version=$sgmApi"

# --- Helper: poll provisioningState until terminal ----------------------------
function Wait-ForProvisioning {
  param(
    [string] $Url,
    [string] $What,
    [int]    $TimeoutSeconds = 300
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = az rest --method get --url $Url --only-show-errors 2>$null | ConvertFrom-Json
    } catch {
      Write-Info "$What : GET returned non-JSON, retrying..."
      Start-Sleep -Seconds 5
      continue
    }
    $state = $resp.properties.provisioningState
    if (-not $state) { $state = '(none)' }
    Write-Info "$What : provisioningState = $state"
    if ($state -eq 'Succeeded') { return $resp }
    if ($state -in 'Failed','Canceled') {
      throw "$What ended in state '$state'. Response: $($resp | ConvertTo-Json -Depth 6)"
    }
    Start-Sleep -Seconds 5
  }
  throw "$What did not reach terminal state within $TimeoutSeconds seconds."
}

# ===============================================================================
# TEARDOWN
# ===============================================================================
if ($Teardown) {
  Write-Step "Teardown: removing service group member + service group"

  $submitted = & (Join-Path $PSScriptRoot 'remove-arm-resource.ps1') -SubscriptionId $subId `
    -ResourceId "$rgScope/providers/Microsoft.Relationships/serviceGroupMember/$RelationshipId" -ApiVersion $sgmApi
  if ($submitted) {
    Write-Info 'Delete submitted: member relationship'
    Start-Sleep -Seconds 10
  } else { Write-Info 'Already absent: member relationship' }

  $submitted = & (Join-Path $PSScriptRoot 'remove-arm-resource.ps1') -SubscriptionId $subId `
    -ResourceId "/providers/Microsoft.Management/serviceGroups/$ServiceGroupId" -ApiVersion $sgApi
  if ($submitted) { Write-Info 'Delete submitted: service group' }
  else { Write-Info 'Already absent: service group' }

  Write-Host "`nService Group cleanup finished: deletes submitted or resources already absent." -ForegroundColor Green
  Write-Host "The Health Model itself is torn down with the RG via 'azd down' or 'az group delete'." -ForegroundColor DarkGray
  return
}

# ===============================================================================
# CREATE
# ===============================================================================

# --- 1. Service Group (tenant scope) ------------------------------------------
if ([string]::IsNullOrWhiteSpace($ServiceGroupDisplayName)) {
  $PSNativeCommandUseErrorActionPreference = $false
  $groupOutput = az rest --method get --url $sgUrl --only-show-errors -o json 2>&1 | Out-String
  $groupExitCode = $LASTEXITCODE
  if ($groupExitCode -eq 0) {
    $existingGroup = $groupOutput | ConvertFrom-Json
    $ServiceGroupDisplayName = $existingGroup.properties.displayName
    if ([string]::IsNullOrWhiteSpace($ServiceGroupDisplayName)) {
      throw "Service Group '$ServiceGroupId' has no display name; refusing to overwrite it."
    }
    Write-Info "Preserving existing Service Group display name: $ServiceGroupDisplayName"
  } else {
    $errorCode = ''
    if ($groupOutput -match '(?ms)^\s*ERROR:\s*[^\{\r\n]*(?<body>\{.*\})\)\s*$') {
      $errorCode = ($Matches.body | ConvertFrom-Json).error.code
    } elseif ($groupOutput -match '(?m)^\s*ERROR:\s*\((?<code>[A-Za-z0-9]+)\)') {
      $errorCode = $Matches.code
    } elseif ($groupOutput -match '(?m)^\s*ERROR:\s*Not Found\s*$') {
      $errorCode = 'NotFound'
    }
    if ($errorCode -notin @('ResourceNotFound', 'ServiceGroupNameNotFound', 'NotFound')) {
      throw "Could not read Service Group '$ServiceGroupId' (Azure CLI exit code $groupExitCode). Details:`n$groupOutput"
    }
    $ServiceGroupDisplayName = "AMLAB - $ResourceGroup"
  }
}
Write-Step "Creating service group '$ServiceGroupId' under tenant root"

$sgBody = @{
  properties = @{
    displayName = $ServiceGroupDisplayName
    parent      = @{
      resourceId = "/providers/Microsoft.Management/serviceGroups/$tenantId"
    }
  }
} | ConvertTo-Json -Depth 6 -Compress

$sgBodyFile = New-TemporaryFile
Set-Content -Path $sgBodyFile -Value $sgBody -Encoding UTF8

try {
  az rest --method put --url $sgUrl --body "@$sgBodyFile" --only-show-errors 2>$null | Out-Null
} catch {
  Remove-Item $sgBodyFile -Force -ErrorAction SilentlyContinue
  throw "Failed to PUT service group. Hint: ensure 'Microsoft.Management' is registered and that you have permissions at the tenant root. Inner: $($_.Exception.Message)"
}
Remove-Item $sgBodyFile -Force -ErrorAction SilentlyContinue

Wait-ForProvisioning -Url $sgUrl -What "Service group" -TimeoutSeconds 300 | Out-Null
Write-Info "Service group created."

# --- 2. Service Group Member: lab RG -------------------------------------------
Write-Step "Attaching $ResourceGroup as a member of $ServiceGroupId"

$sgmBody = @{
  properties = @{
    targetId = "providers/Microsoft.Management/serviceGroups/$ServiceGroupId"
  }
} | ConvertTo-Json -Depth 6 -Compress

$sgmBodyFile = New-TemporaryFile
Set-Content -Path $sgmBodyFile -Value $sgmBody -Encoding UTF8

try {
  az rest --method put --url $sgmUrl --body "@$sgmBodyFile" --only-show-errors 2>$null | Out-Null
} catch {
  Remove-Item $sgmBodyFile -Force -ErrorAction SilentlyContinue
  throw "Failed to PUT service group member relationship. Inner: $($_.Exception.Message)"
}
Remove-Item $sgmBodyFile -Force -ErrorAction SilentlyContinue

Wait-ForProvisioning -Url $sgmUrl -What "Member relationship" -TimeoutSeconds 300 | Out-Null
Write-Info "Member attached."

# --- 3. Follow-up: open the designer ------------------------------------------
Write-Step "Service group + member ready"

$portalSgUrl = "https://portal.azure.com/#@$tenantId/resource/providers/Microsoft.Management/serviceGroups/$ServiceGroupId/overview"
$portalHmUrl = "https://portal.azure.com/#@$tenantId/resource$rgScope/providers/Microsoft.CloudHealth/healthmodels/hm-amlab-workload/overview"

Write-Host @"

   Portal links
   ------------
   * Health Model overview  : $portalHmUrl
   * Service group overview : $portalSgUrl

   What's deployed where
   ---------------------
   * Health Model + entities + signals + relationships
       -> infra/modules/health-model.bicep  (deployed by deploy.ps1)
   * Service group + RG member relationship
       -> this script (preview tenant-scoped resources only).

   The lab Health Model is fully populated by Bicep; the service group is only
   needed if you want to demo the portal Designer's 'Add from service group'
   discovery flow on top of the existing model.

   To remove
   ---------
   ./scripts/setup-health-model.ps1 -ResourceGroup '$ResourceGroup' -ServiceGroupId '$ServiceGroupId' -Teardown

"@ -ForegroundColor Green
