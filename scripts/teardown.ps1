<#
.SYNOPSIS
  Tear the lab down: remove subscription routing, monitoring dependencies, and the lab's related resource groups.

.NOTES
  Opt-in customer SQL/Service Bus/Functions/storage, private networking and UAMIs
  all belong to this exact lab resource group and are removed by group deletion.
  ARM incremental redeployment with the toggle false does NOT delete their data.

.PARAMETER ResourceGroup
  Lab resource group to remove. Also includes name-matched auxiliary groups and
  verifies automatic cleanup of managed groups owned by Azure Monitor workspaces
  in this exact resource group. Specify it with -ResourceGroup.

.PARAMETER DeleteNetworkWatcherRG
  Explicit yes/no opt-in to delete the entire shared NetworkWatcherRG in the
  verified subscription, including watchers and monitoring for unrelated workloads.
  Defaults to no. Also accepts --delete-networkwatcherrg yes.

.PARAMETER KeepServiceGroup
  Preserve tenant-scoped Service Group and SLI resources even when the selected
  resource group has the lab's Service Group membership. Teardown automatically
  skips these shared resources when that membership is absent.

.PARAMETER KeepEntraApplications
  Preserve Entra app registrations and service principals. Otherwise, remove only
  identities explicitly tagged as owned by this lab after directory preflight.

.PARAMETER PurgeSoftDeletedResources
  Opt into permanent cleanup of Key Vaults, Foundry/Cognitive Services accounts,
  and Log Analytics workspaces in the approved lab groups. This destroys their
  secrets and data after confirmation. Default teardown preserves normal Azure
  soft-delete recovery. Purge protection cannot be bypassed.

.PARAMETER Yes
  Approve the displayed cleanup plan without interactive confirmation. Nested
  deletions never prompt again after this approval or the initial DELETE prompt.
  This switch does not enable permanent cleanup; that requires
  -PurgeSoftDeletedResources as well.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [string] $ResourceGroup = 'rg-azure-monitor-lab',
  [Alias('delete-networkwatcherrg')]
  [ValidateSet('yes', 'no')]
  [string] $DeleteNetworkWatcherRG = 'no',
  [switch] $KeepServiceGroup,
  [switch] $KeepEntraApplications,
  [switch] $PurgeSoftDeletedResources,
  [switch] $Yes,
  [Parameter(ValueFromRemainingArguments)]
  [string[]] $RemainingArguments
)
$ErrorActionPreference = 'Stop'

if ($RemainingArguments.Count) {
  if ($RemainingArguments.Count -ne 2 -or $RemainingArguments[0] -cne '--delete-networkwatcherrg' -or
      $RemainingArguments[1] -notin @('yes', 'no') -or $PSBoundParameters.ContainsKey('DeleteNetworkWatcherRG')) {
    throw 'Use named parameters and at most one --delete-networkwatcherrg yes|no option (default: no).'
  }
  $DeleteNetworkWatcherRG = $RemainingArguments[1]
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  throw 'ResourceGroup cannot be empty.'
}
if ($ResourceGroup -ieq 'NetworkWatcherRG' -and $DeleteNetworkWatcherRG -ne 'yes') {
  throw 'Deleting NetworkWatcherRG requires explicit --delete-networkwatcherrg yes (or -DeleteNetworkWatcherRG yes).'
}

$teardownAzureCli = Get-Command az -ErrorAction Stop
$teardownAzureCliPython = $null
if ($IsWindows -and $teardownAzureCli.CommandType -eq 'Application' -and
    [IO.Path]::GetFileName($teardownAzureCli.Source) -ieq 'az.cmd') {
  $pythonPath = Join-Path (Split-Path $teardownAzureCli.Source -Parent) '..\python.exe'
  if (Test-Path -LiteralPath $pythonPath -PathType Leaf) { $teardownAzureCliPython = $pythonPath }
}
$teardownAzureCliBootstrap = @'
import runpy, sys, warnings
warnings.filterwarnings(
    'ignore',
    message=r'^"\\s" is an invalid escape sequence\.',
    category=SyntaxWarning,
    module=r'^.*[\\/]azext_amcs[\\/]aaz[\\/]latest[\\/]monitor[\\/]data_collection[\\/]rule[\\/]_create$',
)
sys.argv[0] = 'az'
runpy.run_module('azure.cli', run_name='__main__')
'@
if ($teardownAzureCliPython) {
  function az {
    # Match the MSI launcher's isolation and installer flag, adding only the warning filter.
    $previousInstaller = $env:AZ_INSTALLER
    try {
      $env:AZ_INSTALLER = 'MSI'
      & $teardownAzureCliPython -IB -c $teardownAzureCliBootstrap @args
    } finally {
      $env:AZ_INSTALLER = $previousInstaller
    }
  }
}

function Remove-MatchingResourceGroups {
  param([string[]] $Names)

  $PSNativeCommandUseErrorActionPreference = $false
  if ($purgeResources.Count) {
    & $softDeleteCleanup -SubscriptionId $active.id -TenantId $active.tenantId `
      -ResourceGroups $purgeResourceGroups -Resources $purgeResources -Confirm:$false
  }
  $submittedDeletes = 0
  foreach ($name in $Names) {
    if ($name -in $monitorManagedResourceGroupNames) {
      $deadline = [DateTime]::UtcNow.AddSeconds(600)
      for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $groupOutput = az group show --subscription $active.id -n $name --query '{id:id,managedBy:managedBy}' `
          -o json --only-show-errors 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          if ($groupOutput -match '(?m)^\s*ERROR:\s*\(ResourceGroupNotFound\)') {
            Write-Host "Managed resource group absence verified (ResourceGroupNotFound): $name" -ForegroundColor Green
            break
          }
          throw "Could not verify Azure-managed cleanup of resource group '$name'. No absence was assumed. Azure details:`n$groupOutput"
        }
        $group = $groupOutput | ConvertFrom-Json
        if ($group.id -ine "/subscriptions/$($active.id)/resourceGroups/$name" -or $group.managedBy -notmatch $monitorOwnerPattern) {
          throw "Managed resource group '$name' is no longer owned by an Azure Monitor workspace in '$ResourceGroup', or returned an unexpected ID. Refusing further cleanup."
        }
        if ($attempt -eq 0) {
          Write-Host "Waiting for Azure to remove managed resource group '$name' through its owning workspace '$($group.managedBy)'. No direct group deletion will be attempted." -ForegroundColor Yellow
        }
        if ($attempt -eq 59 -or [DateTime]::UtcNow.AddSeconds(10) -ge $deadline) {
          throw "Azure has not removed Monitor-managed resource group '$name' within 600s. Owner: '$($group.managedBy)'. Lab/auxiliary deletion requests may already be running. No direct managed-group deletion was attempted. Check the owning workspace's deletion; if Azure cleanup remains stuck, contact Azure Support."
        }
        Start-Sleep -Seconds 10
      }
      continue
    }
    Write-Host "Deleting $name ..." -ForegroundColor Yellow
    $deleteOutput = az group delete --subscription $active.id -n $name --yes --no-wait 2>&1 | Out-String
    $deleteExitCode = $LASTEXITCODE
    if ($deleteExitCode -ne 0) {
      throw "Azure CLI failed to submit deletion for resource group '$name'. Details:`n$deleteOutput"
    }
    $submittedDeletes++
  }

  if ($submittedDeletes) { Write-Host "Delete requests accepted (running in background)." -ForegroundColor Green }
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
  $allResourceGroups | Where-Object { $_.name -ine 'NetworkWatcherRG' -and $_.managedBy -match $monitorOwnerPattern } | Select-Object -ExpandProperty name
)
$resourceGroupsToDelete = @(
  @(
    $allResourceGroupNames |
      Where-Object { $_ -ine 'NetworkWatcherRG' -and $_.IndexOf($ResourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and ($_ -ieq $ResourceGroup -or $_ -notlike 'MA_*') }
    $monitorManagedResourceGroupNames
    if ($DeleteNetworkWatcherRG -eq 'yes') {
      $allResourceGroupNames | Where-Object { $_ -ieq 'NetworkWatcherRG' }
    }
  ) | Sort-Object -Unique { if ($_ -ieq $ResourceGroup) { 0 } elseif ($_ -in $monitorManagedResourceGroupNames) { 3 } elseif ($_ -ieq 'NetworkWatcherRG') { 2 } else { 1 } }, { $_ }
)
$primaryResourceGroupExists = @($allResourceGroupNames | Where-Object { $_ -ieq $ResourceGroup }).Count -gt 0
$resourceGroupId = "/subscriptions/$($active.id)/resourceGroups/$ResourceGroup"
$softDeleteCleanup = Join-Path $PSScriptRoot 'remove-lab-soft-deleted-resources.ps1'
$purgeResources = @()
$purgeResourceGroups = @()
if ($PurgeSoftDeletedResources) {
  $purgeResourceGroups = @(@($ResourceGroup) + @($resourceGroupsToDelete | Where-Object { $_ -notin $monitorManagedResourceGroupNames }) | Sort-Object -Unique)
  $purgeResources = @(& $softDeleteCleanup -SubscriptionId $active.id -TenantId $active.tenantId `
    -ResourceGroups $purgeResourceGroups -ExistingResourceGroups @($purgeResourceGroups | Where-Object { $_ -in $allResourceGroupNames }) -PlanOnly)
  $protectedVaults = @($purgeResources | Where-Object PurgeProtected)
  if ($protectedVaults.Count) {
    throw "Purge protection prevents permanent cleanup of: $($protectedVaults.Id -join ', '). It cannot be bypassed. Wait for retention expiry or rerun teardown without -PurgeSoftDeletedResources."
  }
  $recoveryGroups = @($purgeResources | Where-Object {
    $_.Deleted -and $_.Type -eq 'Microsoft.OperationalInsights/workspaces' -and $_.ResourceGroup -notin $allResourceGroupNames
  } | Select-Object -ExpandProperty ResourceGroup -Unique)
  $resourceGroupsToDelete = @(@($resourceGroupsToDelete) + $recoveryGroups | Sort-Object -Unique {
    if ($_ -ieq $ResourceGroup) { 0 } elseif ($_ -in $monitorManagedResourceGroupNames) { 3 } elseif ($_ -ieq 'NetworkWatcherRG') { 2 } else { 1 }
  }, { $_ })
}
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

if ($resourceGroupsToDelete.Count -eq 0 -and $entraIdentities.Count -eq 0 -and -not $ownsActivityDiagnostic -and $purgeResources.Count -eq 0) {
  Write-Host "No matching resource groups or verified lab-owned Entra identities found for '$ResourceGroup'. Nothing to delete." -ForegroundColor Yellow
  return
}

if ($DeleteNetworkWatcherRG -eq 'yes') {
  if ($resourceGroupsToDelete -icontains 'NetworkWatcherRG') {
    Write-Warning "Explicit opt-in: the ENTIRE shared NetworkWatcherRG in subscription '$($active.id)' will be deleted, including all regional watchers, connection monitors, flow logs, and unrelated resources. This can disrupt monitoring for other workloads."
  } else {
    Write-Host 'NetworkWatcherRG is not present in the verified subscription; no Network Watcher group deletion is needed.' -ForegroundColor Yellow
  }
}

if ($purgeResources.Count) {
  Write-Warning 'Permanent cleanup destroys the listed secrets, AI account data and logs without recovery. Log Analytics recovery may temporarily recreate an original resource group; that group is included in deletion.'
  $purgeResources | ForEach-Object {
    Write-Host "  - PERMANENT: $($_.Id) [$($_.Location)]" -ForegroundColor Yellow
  }
} elseif (-not $PurgeSoftDeletedResources) {
  Write-Host 'Preserving normal Azure soft-delete recovery. Reserved names may block same-name redeployment; permanent cleanup requires -PurgeSoftDeletedResources.' -ForegroundColor Yellow
}

if (-not $Yes) {
  Write-Host "The following resource groups match or are managed by workspaces in '$ResourceGroup' and will be cleaned up:" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object {
    $suffix = if ($_ -in $monitorManagedResourceGroupNames) { ' (Azure-managed cleanup; no direct deletion)' } else { '' }
    Write-Host "  - $_$suffix" -ForegroundColor Yellow
  }
  if ($ownsActivityDiagnostic) { Write-Host "  - Subscription diagnostic setting: $activityDiagnosticName" -ForegroundColor Yellow }
  $entraIdentities | ForEach-Object { Write-Host "  - Entra: $($_.DisplayName), app $($_.ApplicationObjectId), principal $($_.ServicePrincipalObjectId)" -ForegroundColor Yellow }
  $confirmation = 'Type DELETE to confirm deletion of the listed resource groups and lab-owned Entra identities'
  if ($purgeResources.Count) { $confirmation += ', including the listed permanent resource/data cleanup' }
  $confirm = Read-Host $confirmation
  if ($confirm -ne 'DELETE') { Write-Host "Aborted." -ForegroundColor Yellow; return }
} else {
  Write-Host "Cleaning up resource groups matching or managed by workspaces in '$ResourceGroup':" -ForegroundColor Yellow
  $resourceGroupsToDelete | ForEach-Object {
    $suffix = if ($_ -in $monitorManagedResourceGroupNames) { ' (Azure-managed cleanup; no direct deletion)' } else { '' }
    Write-Host "  - $_$suffix" -ForegroundColor Yellow
  }
  if ($ownsActivityDiagnostic) { Write-Host "  - Subscription diagnostic setting: $activityDiagnosticName" -ForegroundColor Yellow }
  $entraIdentities | ForEach-Object { Write-Host "  - Entra: $($_.DisplayName), app $($_.ApplicationObjectId), principal $($_.ServicePrincipalObjectId)" -ForegroundColor Yellow }
}

if ($KeepEntraApplications) {
  Write-Host 'Preserving Entra app registrations and service principals.' -ForegroundColor Yellow
} elseif ($entraIdentities.Count) {
  & $entraCleanup -SubscriptionId $active.id -TenantId $active.tenantId -ResourceGroup $ResourceGroup -Identities $entraIdentities -Confirm:$false
}

if ($ownsActivityDiagnostic) {
  Write-Host "Deleting subscription diagnostic setting $activityDiagnosticName ..." -ForegroundColor Yellow
  az monitor diagnostic-settings subscription delete --subscription $active.id --name $activityDiagnosticName --yes --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw "Failed to delete subscription diagnostic setting '$activityDiagnosticName'." }
}

if (-not $primaryResourceGroupExists) {
  Write-Host "The original resource group no longer exists; deleting matched auxiliary groups and verifying Azure-managed Monitor cleanup." -ForegroundColor Yellow
  if ($resourceGroupsToDelete.Count -or $purgeResources.Count) { Remove-MatchingResourceGroups -Names $resourceGroupsToDelete }
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
  $monitoredResourcesOutput = az rest --subscription $active.id --method get `
    --url "https://management.azure.com$($observabilityAgent.id)/monitoredResources?api-version=2026-05-01-preview" `
    --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect monitored resources for '$($observabilityAgent.name)':`n$($monitoredResourcesOutput -join "`n")"
  }
  $monitoredResponse = ($monitoredResourcesOutput -join "`n") | ConvertFrom-Json
  $monitoredResources = @($monitoredResponse.value | Where-Object {
    $_.properties.enabled -and $_.properties.resourceId -match '/providers/Microsoft\.Insights/components/'
  })
  if ($monitoredResources.Count -ne 1) {
    throw "Expected one enabled Application Insights resource for '$($observabilityAgent.name)'; found $($monitoredResources.Count)."
  }
  $appInsightsId = [string]$monitoredResources[0].properties.resourceId
  $componentAssignmentsOutput = az role assignment list --subscription $active.id --assignee-object-id $principalId `
    --scope $appInsightsId -o json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect Application Insights RBAC for '$($observabilityAgent.name)':`n$($componentAssignmentsOutput -join "`n")"
  }
  $componentAssignments = @($componentAssignmentsOutput | ConvertFrom-Json | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.scope) -and
    -not [string]::IsNullOrWhiteSpace($_.roleDefinitionId) -and
    $_.scope.TrimEnd('/') -ieq $appInsightsId.TrimEnd('/') -and
    $_.roleDefinitionId.TrimEnd('/').Split('/')[-1] -ieq $monitoringReaderRoleId
  })
  foreach ($assignment in $componentAssignments) {
    Write-Host "Removing Observability Agent Application Insights Monitoring Reader assignment $($assignment.id) ..." -ForegroundColor DarkGray
    az role assignment delete --subscription $active.id --ids $assignment.id
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove Observability Agent Application Insights RBAC '$($assignment.id)'." }
  }
  Write-Host "Deleting Observability Agent $($observabilityAgent.name) before resource-group cleanup ..." -ForegroundColor Yellow
  az resource delete --subscription $active.id --ids $observabilityAgent.id --api-version 2026-05-01-preview
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to delete Observability Agent '$($observabilityAgent.name)'. Stop before deleting the resource group and verify the agent manually to avoid continued agent operations."
  }
}

# Delete billable SRE Agent resources explicitly before the asynchronous RG delete.
$sreAgents = @(az resource list --subscription $active.id -g $ResourceGroup --resource-type Microsoft.App/agents -o json --only-show-errors | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect SRE Agents in '$ResourceGroup'. Stop before resource-group cleanup." }
foreach ($sreAgent in $sreAgents) {
  $agentPrefix = "$resourceGroupId/providers/Microsoft.App/agents/"
  if (-not $sreAgent.id -or -not $sreAgent.id.StartsWith($agentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
      $sreAgent.id.Substring($agentPrefix.Length).Contains('/')) {
    throw 'SRE Agent discovery returned an unexpected resource scope. No agent deletion was submitted.'
  }
  Write-Host "Stopping and deleting SRE Agent $($sreAgent.name) before resource-group cleanup ..." -ForegroundColor Yellow
  & (Join-Path $PSScriptRoot 'remove-sre-agent.ps1') -SubscriptionId $active.id -TenantId $active.tenantId `
    -ResourceId $sreAgent.id -Confirm:$false | Out-Null
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

$fabricCapacity = @($allResources | Where-Object { $_.type -ieq 'Microsoft.Fabric/capacities' }) | Select-Object -First 1
if ($fabricCapacity) {
  Write-Host "Removing tenant-scoped Fabric workspace and items ..." -ForegroundColor Yellow
  $setupFabric = Join-Path $PSScriptRoot 'setup-fabric.ps1'
  if (Test-Path $setupFabric) {
    try {
      & $setupFabric -SubscriptionId $active.id -ResourceGroup $ResourceGroup -Teardown
    } catch {
      Write-Host "  Fabric workspace cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow
      Write-Host "  Resource-group deletion will still remove the F2 capacity. Delete the 'Azure Monitor Demo Lab' workspace manually if it remains." -ForegroundColor Yellow
    }
  }
}

if (@($allResources | Where-Object {
  $_.type -ieq 'Microsoft.CloudHealth/healthmodels' -and $_.name -in @('hm-amlab-flows', 'hm-lab-cafe')
}).Count -gt 0) {
  Write-Host 'Removing verified lab-scoped Health Model reporter roles and their assignments ...' -ForegroundColor Yellow
  & (Join-Path $PSScriptRoot 'remove-health-model-demo-roles.ps1') `
    -SubscriptionId $active.id -ResourceGroup $ResourceGroup -Confirm:$false
}

Remove-MatchingResourceGroups -Names $resourceGroupsToDelete
