<#
.SYNOPSIS
  Tear the lab down: remove subscription routing, monitoring dependencies, and the lab's related resource groups.

.PARAMETER ResourceGroup
  Lab resource group to remove. Also includes name-matched auxiliary groups and
  managed groups owned by Azure Monitor workspaces in this exact resource group.

.PARAMETER KeepServiceGroup
  Preserve tenant-scoped Service Group and SLI resources even when the selected
  resource group has the lab's Service Group membership. Teardown automatically
  skips these shared resources when that membership is absent.

.PARAMETER KeepEntraApplications
  Preserve Entra app registrations and service principals. Otherwise, remove only
  identities explicitly tagged as owned by this lab after directory preflight.
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [switch] $KeepServiceGroup,
  [switch] $KeepEntraApplications,
  [switch] $Yes
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  throw 'ResourceGroup cannot be empty.'
}

function Remove-MatchingResourceGroups {
  param([string[]] $Names)

  foreach ($name in $Names) {
    if ($name -in $monitorManagedResourceGroupNames) {
      $groupExists = az group exists --subscription $active.id -n $name -o tsv --only-show-errors
      if ($LASTEXITCODE -ne 0 -or $groupExists -notin @('true', 'false')) { throw "Could not verify managed resource group '$name'." }
      if ($groupExists -eq 'false') {
        Write-Host "Azure already removed managed resource group '$name'." -ForegroundColor DarkGray
        continue
      }
      $managedBy = az group show --subscription $active.id -n $name --query managedBy -o tsv --only-show-errors
      if ($LASTEXITCODE -ne 0) { throw "Could not verify current ownership of managed resource group '$name'." }
      if ($managedBy -notmatch $monitorOwnerPattern) { throw "Managed resource group '$name' is no longer owned by an Azure Monitor workspace in '$ResourceGroup'. Refusing deletion." }
    }
    Write-Host "Deleting $name ..." -ForegroundColor Yellow
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
      $PSNativeCommandUseErrorActionPreference = $false
      $deleteOutput = az group delete --subscription $active.id -n $name --yes --no-wait 2>&1 | Out-String
      $deleteExitCode = $LASTEXITCODE
    } finally {
      $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
    if ($deleteExitCode -ne 0) {
      if ($name -in $monitorManagedResourceGroupNames) {
        $groupExists = az group exists --subscription $active.id -n $name -o tsv --only-show-errors
        if ($LASTEXITCODE -eq 0 -and $groupExists -eq 'false') {
          Write-Host "Azure already removed managed resource group '$name'." -ForegroundColor DarkGray
          continue
        }
      }
      throw "Azure CLI failed to submit deletion for resource group '$name'. Details:`n$deleteOutput"
    }
  }

  Write-Host "Delete requests accepted (running in background)." -ForegroundColor Green
  Write-Host "Verify completion with:" -ForegroundColor Green
  $Names | ForEach-Object { Write-Host "  az group exists --subscription '$($active.id)' -n '$_'" -ForegroundColor Green }
}

# Subscription guardrail
$targetFile = Join-Path $PSScriptRoot '..' '.azure-target.json'
if (Test-Path $targetFile) {
  $target = Get-Content -Raw $targetFile | ConvertFrom-Json
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not select the lab subscription for teardown.' }
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting teardown."
  }
} else {
  $active = az account show --query '{id:id,tenantId:tenantId}' -o json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $active.id -or -not $active.tenantId) { throw 'Could not resolve the teardown subscription and tenant.' }
}

# Include Azure-managed and auxiliary resource groups whose names contain the
# complete requested RG name, such as MC_<rg>_<aks>_<region>.
$allResourceGroups = @(az group list --subscription $active.id --query '[].{name:name,managedBy:managedBy}' -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) {
  throw 'Failed to list resource groups for teardown discovery.'
}
$allResourceGroupNames = @($allResourceGroups | Select-Object -ExpandProperty name)
$monitorOwnerPattern = '^' + [regex]::Escape("/subscriptions/$($active.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Monitor/accounts/") + '[^/]+$'
$monitorManagedResourceGroupNames = @(
  $allResourceGroups | Where-Object { $_.managedBy -match $monitorOwnerPattern } | Select-Object -ExpandProperty name
)
$resourceGroupsToDelete = @(
  @(
    $allResourceGroupNames |
      Where-Object { $_.IndexOf($ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and ($_ -ieq $ResourceGroup -or $_ -notlike 'MA_*') }
    $monitorManagedResourceGroupNames
  ) | Sort-Object -Unique { if ($_ -ieq $ResourceGroup) { 0 } elseif ($_ -in $monitorManagedResourceGroupNames) { 2 } else { 1 } }, { $_ }
)
$primaryResourceGroupExists = @($allResourceGroupNames | Where-Object { $_ -ieq $ResourceGroup }).Count -gt 0
$resourceGroupId = "/subscriptions/$($active.id)/resourceGroups/$ResourceGroup"
$activityDiagnosticName = 'amlab-activity-to-law'
$activityLogWorkspaceId = az monitor diagnostic-settings subscription list --subscription $active.id `
  --query "value[?name=='$activityDiagnosticName'].workspaceId | [0]" -o tsv --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Could not inspect subscription diagnostic setting '$activityDiagnosticName'." }
$ownsActivityDiagnostic = $activityLogWorkspaceId -and
  $activityLogWorkspaceId.StartsWith("$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/", [StringComparison]::OrdinalIgnoreCase)
$serviceGroupMembershipId = "/subscriptions/$($active.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg"
$hasServiceGroupMembership = $false
if ($primaryResourceGroupExists) {
  $serviceGroupMemberships = @(az resource list --subscription $active.id -g $ResourceGroup `
    --resource-type Microsoft.Relationships/serviceGroupMember -o json --only-show-errors | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect Service Group memberships in '$ResourceGroup'." }
  $hasServiceGroupMembership = @($serviceGroupMemberships | Where-Object { $_.id -ieq $serviceGroupMembershipId }).Count -gt 0
}

$entraIdentities = @()
$entraCleanup = Join-Path $PSScriptRoot 'remove-lab-entra-identities.ps1'
if (-not $KeepEntraApplications) {
  $entraIdentities = @(& $entraCleanup -SubscriptionId $active.id -TenantId $active.tenantId -ResourceGroup $ResourceGroup -PlanOnly)
}

if ($resourceGroupsToDelete.Count -eq 0 -and $entraIdentities.Count -eq 0 -and -not $ownsActivityDiagnostic) {
  Write-Host "No matching resource groups or verified lab-owned Entra identities found for '$ResourceGroup'. Nothing to delete." -ForegroundColor Yellow
  return
}

if (-not $Yes) {
  Write-Host "The following resource groups match or are managed by workspaces in '$ResourceGroup' and will be deleted:" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  if ($ownsActivityDiagnostic) { Write-Host "  - Subscription diagnostic setting: $activityDiagnosticName" -ForegroundColor Yellow }
  $entraIdentities | ForEach-Object { Write-Host "  - Entra: $($_.DisplayName), app $($_.ApplicationObjectId), principal $($_.ServicePrincipalObjectId)" -ForegroundColor Yellow }
  $confirm = Read-Host 'Type DELETE to confirm deletion of the listed resource groups and lab-owned Entra identities'
  if ($confirm -ne 'DELETE') { Write-Host "Aborted." -ForegroundColor Yellow; return }
} else {
  Write-Host "Deleting resource groups matching or managed by workspaces in '$ResourceGroup':" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  if ($ownsActivityDiagnostic) { Write-Host "  - Subscription diagnostic setting: $activityDiagnosticName" -ForegroundColor Yellow }
  $entraIdentities | ForEach-Object { Write-Host "  - Entra: $($_.DisplayName), app $($_.ApplicationObjectId), principal $($_.ServicePrincipalObjectId)" -ForegroundColor Yellow }
}

if ($KeepEntraApplications) {
  Write-Host 'Preserving Entra app registrations and service principals.' -ForegroundColor Yellow
} elseif ($entraIdentities.Count) {
  & $entraCleanup -SubscriptionId $active.id -TenantId $active.tenantId -ResourceGroup $ResourceGroup -Identities $entraIdentities
}

if ($ownsActivityDiagnostic) {
  Write-Host "Deleting subscription diagnostic setting $activityDiagnosticName ..." -ForegroundColor Yellow
  az monitor diagnostic-settings subscription delete --subscription $active.id --name $activityDiagnosticName --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw "Failed to delete subscription diagnostic setting '$activityDiagnosticName'." }
}

if (-not $primaryResourceGroupExists) {
  Write-Host "The original resource group no longer exists; deleting matched auxiliary resource groups directly." -ForegroundColor Yellow
  if ($resourceGroupsToDelete.Count) { Remove-MatchingResourceGroups -Names $resourceGroupsToDelete }
  return
}

# Stop autonomous Observability Agent work before the asynchronous RG delete.
$observabilityAgents = @(az resource list --subscription $active.id -g $ResourceGroup --resource-type Microsoft.Monitor/observabilityAgents -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect Observability Agents in '$ResourceGroup'." }
foreach ($observabilityAgent in $observabilityAgents) {
  $principalId = az resource show --subscription $active.id --ids $observabilityAgent.id --api-version 2026-05-01-preview --query identity.principalId -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
    throw "Could not resolve the identity for Observability Agent '$($observabilityAgent.name)'."
  }
  $monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  $assignmentIds = @(az role assignment list --subscription $active.id --assignee-object-id $principalId `
    --scope "/subscriptions/$($active.id)" `
    --query "[?roleDefinitionId=='/subscriptions/$($active.id)/providers/Microsoft.Authorization/roleDefinitions/$monitoringReaderRoleId'].id" `
    -o tsv)
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect subscription RBAC for Observability Agent '$($observabilityAgent.name)'." }
  foreach ($assignmentId in $assignmentIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    Write-Host "Removing Observability Agent Monitoring Reader assignment $assignmentId ..." -ForegroundColor DarkGray
    az role assignment delete --subscription $active.id --ids $assignmentId
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove Observability Agent subscription RBAC '$assignmentId'." }
  }
  Write-Host "Deleting Observability Agent $($observabilityAgent.name) before resource-group cleanup ..." -ForegroundColor Yellow
  az resource delete --subscription $active.id --ids $observabilityAgent.id --api-version 2026-05-01-preview
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to delete Observability Agent '$($observabilityAgent.name)'. Stop before deleting the resource group and verify the agent manually to avoid continued agent operations."
  }
}

# Delete billable SRE Agent resources explicitly before the asynchronous RG delete.
$sreAgents = @(az resource list -g $ResourceGroup --resource-type Microsoft.App/agents -o json | ConvertFrom-Json)
foreach ($sreAgent in $sreAgents) {
  Write-Host "Deleting SRE Agent $($sreAgent.name) before resource-group cleanup ..." -ForegroundColor Yellow
  az resource delete --ids $sreAgent.id --api-version 2025-05-01-preview
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to delete SRE Agent '$($sreAgent.name)'. Stop before deleting the resource group and verify the agent manually to avoid continued billing."
  }
}

# Remove dependencies that can prevent Azure from deleting the monitoring estate.
# The final RG deletion remains --no-wait.
Write-Host "Removing LAW replication, DCR associations, DCRs, and DCEs ..." -ForegroundColor Yellow

$workspaces = az resource list -g $ResourceGroup --resource-type Microsoft.OperationalInsights/workspaces -o json | ConvertFrom-Json
foreach ($workspace in @($workspaces)) {
  # az resource list returns a shallow resource projection; fetch the workspace
  # before checking replication so the nested property is not missed.
  $workspaceDetails = az resource show --ids $workspace.id --api-version 2025-02-01 -o json | ConvertFrom-Json
  if ($workspaceDetails.properties.replication.enabled -eq $true) {
    Write-Host "  Disabling replication on $($workspace.name)" -ForegroundColor DarkGray
    az monitor log-analytics workspace update -g $ResourceGroup -n $workspace.name --replication-enabled false --only-show-errors | Out-Null
  }
}

$dcrAssociations = @(az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRuleAssociations -o json | ConvertFrom-Json)

# Workspace and resource-scoped associations are child resources, so the RG-level
# resource list can omit them (notably the LAW microsoft-default association).
$allResources = az resource list -g $ResourceGroup -o json | ConvertFrom-Json
foreach ($resource in @($allResources)) {
  $resourcePath = ($resource.id.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
  $nestedErrorFile = New-TemporaryFile
  $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
  try {
    $PSNativeCommandUseErrorActionPreference = $false
    $nestedJson = az rest --method get --url "$resourcePath/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11" 2> $nestedErrorFile.FullName
    $nestedExitCode = $LASTEXITCODE
    $nestedError = Get-Content -LiteralPath $nestedErrorFile.FullName -Raw
  } finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    Remove-Item -LiteralPath $nestedErrorFile.FullName -Force
  }
  if ($nestedExitCode -ne 0) {
    $nestedErrorCode = ''
    if ($nestedError -match '(?ms)^\s*ERROR:\s*[^\{\r\n]*(?<body>\{.*\})\)\s*$') {
      try { $nestedErrorCode = ($Matches.body | ConvertFrom-Json).error.code } catch { }
    } elseif ($nestedError -match '(?m)^\s*ERROR:\s*\((?<code>[A-Za-z0-9]+)\)') {
      $nestedErrorCode = $Matches.code
    } elseif ($nestedError -match '(?m)^\s*ERROR:\s*Not Found\s*$') {
      $nestedErrorCode = 'NotFound'
    }
    if ($nestedErrorCode -in @('UnsupportedResourceType', 'UnsupportedFeature', 'ResourceNotFound', 'ParentResourceNotFound', 'NotFound')) { continue }
    throw "DCR association discovery failed for '$($resource.id)' (exit code $nestedExitCode). Details:`n$nestedError"
  }
  if (-not [string]::IsNullOrWhiteSpace($nestedJson)) {
    $nested = $nestedJson | ConvertFrom-Json
    $dcrAssociations += @($nested.value)
  }
}

$associationIds = @($dcrAssociations | Where-Object { $_.id } | Select-Object -ExpandProperty id -Unique)
foreach ($associationId in $associationIds) {
  Write-Host "  Removing DCR association $associationId" -ForegroundColor DarkGray
  az resource delete --ids $associationId --api-version 2023-03-11
}

$dcrs = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules -o json | ConvertFrom-Json
foreach ($dcr in @($dcrs)) {
  Write-Host "  Removing DCR $($dcr.name)" -ForegroundColor DarkGray
  az resource delete --ids $dcr.id --api-version 2024-03-11
}

$dces = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionEndpoints -o json | ConvertFrom-Json
foreach ($dce in @($dces)) {
  Write-Host "  Removing DCE $($dce.name)" -ForegroundColor DarkGray
  az resource delete --ids $dce.id --api-version 2023-03-11 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "    DCE is managed by Azure; it will be removed with the LAW/RG cascade." -ForegroundColor DarkGray
  }
}

# Tear down tenant-scoped artefacts FIRST (they survive RG delete otherwise and
# end up dangling against the deleted AMW). Safe + idempotent — both helper
# scripts swallow 404s.
if (-not $hasServiceGroupMembership) {
  Write-Host "No lab Service Group membership exists in '$ResourceGroup'; skipping shared Service Group and SLI cleanup." -ForegroundColor DarkGray
} elseif ($KeepServiceGroup) {
  Write-Host 'Preserving shared Service Group and SLIs; this resource group membership is removed with the RG.' -ForegroundColor Yellow
} else {
  Write-Host "Removing demo SLIs (scenario 46) ..." -ForegroundColor Yellow
  $setupSli = Join-Path $PSScriptRoot 'setup-slis.ps1'
  if (Test-Path $setupSli) {
    & $setupSli -ResourceGroup $ResourceGroup -Teardown
  }

  Write-Host "Removing service group + member relationship (scenario 45) ..." -ForegroundColor Yellow
  $setupHm = Join-Path $PSScriptRoot 'setup-health-model.ps1'
  if (Test-Path $setupHm) {
    & $setupHm -ResourceGroup $ResourceGroup -Teardown
  }
}

Remove-MatchingResourceGroups -Names $resourceGroupsToDelete
