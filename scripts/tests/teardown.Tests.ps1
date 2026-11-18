$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('teardown-test-' + [guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'scripts'
$null = New-Item -ItemType Directory -Path $directory -Force
Copy-Item -LiteralPath (Join-Path $source 'scripts/teardown.ps1') -Destination $directory
$fixture = @{
  Subscription = [guid]::NewGuid(); Tenant = [guid]::NewGuid()
  ResourceGroup = 'rg-teardown-test'; BadTenant = $false; Confirm = 'DELETE'; ConfirmationReads = 0
  CliStderr = ''
  DiscoveryError = ''; GroupLists = 0
  Deletes = [Collections.Generic.List[string]]::new()
  TenantCleanup = [Collections.Generic.List[string]]::new()
  PrimaryGroupExists = $true; AuxiliaryGroupExists = $true; MonitorGroupExists = $true
  NetworkWatcherGroupExists = $true; NetworkWatcherDeleteError = ''
  GroupInventoryFails = $false; GroupDeleteError = ''
  MonitorOwnerChanged = $false; MonitorOwnerChangeAfterChecks = 0; MonitorWrongId = $false
  MonitorChecks = 0; MonitorSleeps = 0; MonitorCleanupAfterChecks = 2; MonitorLookupError = ''
  RealTenantCleanup = $false; TenantDeleteError = ''
  ServiceGroupMembershipExists = $true
  ObservabilityAgentExists = $false
  SreAgentExists = $false; SreDiscoveryFails = $false; SreCleanupFails = $false
  ActivityWorkspaceId = ''; ActivityDiagnosticDeletes = 0
  EntraPlan = @(); EntraCalls = [Collections.Generic.List[string]]::new(); EntraFails = ''
  PurgePlan = @(); PurgeCalls = 0; PurgePlans = 0; PurgeFails = $false
  HideMonitorGroup = $false
}
$resourceGroupId = "/subscriptions/$($fixture.Subscription)/resourceGroups/$($fixture.ResourceGroup)"
$workspaceId = "$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/law-test"
$fixture.ActivityWorkspaceId = $workspaceId
$unsupportedId = "$resourceGroupId/providers/Microsoft.OperationsManagement/solutions/ContainerInsights(law-test)"
$associationId = "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations/test-association"
$dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/dcr-test"
$dceId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionEndpoints/dce-test"
$auxiliaryGroup = "MC_$($fixture.ResourceGroup)_aks-test_northeurope"
$monitorGroup = 'MA_amw-amlab_northeurope_managed_3'
$monitorWorkspaceId = "$resourceGroupId/providers/Microsoft.Monitor/accounts/amw-amlab"
$observabilityAgentId = "$resourceGroupId/providers/Microsoft.Monitor/observabilityAgents/obs-amlab-test"
$sreAgentId = "$resourceGroupId/providers/Microsoft.App/agents/sre-test"
$observabilityPrincipalId = [guid]::NewGuid().ToString()
$observabilityRoleAssignmentId = "/subscriptions/$($fixture.Subscription)/providers/Microsoft.Authorization/roleAssignments/obs-monitoring-reader"
$appInsightsId = "$resourceGroupId/providers/Microsoft.Insights/components/appi-test"
$appInsightsRoleAssignmentId = "/subscriptions/$($fixture.Subscription)/providers/Microsoft.Authorization/roleAssignments/appi-monitoring-reader"
$serviceGroupId = '/providers/Microsoft.Management/serviceGroups/amlab-workload'
$fixture.ServiceGroupResourceId = $serviceGroupId
$tenantDeleteApis = [ordered]@{}
$tenantDeleteApis["$serviceGroupId/providers/Microsoft.Monitor/slis/sli-aks-pods-running"] = '2025-03-01-preview'
$tenantDeleteApis["$serviceGroupId/providers/Microsoft.Monitor/slis/sli-aks-pod-start-latency"] = '2025-03-01-preview'
$tenantDeleteApis["$resourceGroupId/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg"] = '2023-09-01-preview'
$tenantDeleteApis[$serviceGroupId] = '2024-02-01-preview'
$otherSubscription = [guid]::NewGuid()
$groupInventory = @(
  @{ name = 'NetworkWatcherRG'; managedBy = $null },
  @{ name = 'NetworkWatcherRG-other'; managedBy = $null },
  @{ name = 'rg-other-lab'; managedBy = $null },
  @{ name = $auxiliaryGroup; managedBy = $null },
  @{ name = $fixture.ResourceGroup; managedBy = $null },
  @{ name = $monitorGroup; managedBy = $monitorWorkspaceId.ToUpperInvariant() },
  @{ name = 'MA_amw-amlab_northeurope_managed_2'; managedBy = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_unowned'; managedBy = $null },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_subscription'; managedBy = "/subscriptions/$otherSubscription/resourceGroups/$($fixture.ResourceGroup)/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_scope'; managedBy = "${resourceGroupId}-other/providers/Microsoft.Monitor/accounts/amw-amlab" },
  @{ name = 'MA_amw-amlab_northeurope_managed_other_type'; managedBy = "$resourceGroupId/providers/Microsoft.OperationalInsights/workspaces/amw-amlab" }
  @{ name = "MA_$($fixture.ResourceGroup)_managed"; managedBy = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab" }
)
@{ expectedSubscriptionId = $fixture.Subscription; expectedTenantId = $fixture.Tenant } |
  ConvertTo-Json | Set-Content (Join-Path $root '.azure-target.json')

foreach ($helperName in @('setup-slis.ps1', 'setup-health-model.ps1')) {
  @'
param($ResourceGroup, [switch]$Teardown)
if ($ResourceGroup -ne $fixture.ResourceGroup -or -not $Teardown) { throw 'Unexpected tenant cleanup target.' }
$fixture.TenantCleanup.Add([IO.Path]::GetFileName($PSCommandPath))
'@ | Set-Content -LiteralPath (Join-Path $directory $helperName)
}

@'
[CmdletBinding(SupportsShouldProcess)]
param($SubscriptionId, $TenantId, $ResourceGroup, [switch]$PlanOnly, $Identities)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or $ResourceGroup -ne $fixture.ResourceGroup) { throw 'Entra cleanup lost the verified lab target.' }
$step = if ($PlanOnly) { 'plan' } else { 'delete' }
$fixture.EntraCalls.Add($step)
if ($fixture.EntraFails -eq $step) { throw 'Entra cleanup denied.' }
if ($PlanOnly) { $fixture.EntraPlan; return }
if (-not $PSBoundParameters.ContainsKey('Confirm') -or $PSBoundParameters.Confirm) { throw 'Confirmed teardown must suppress nested Entra approval.' }
if ($fixture.Deletes.Count -or $fixture.TenantCleanup.Count) { throw 'Entra cleanup must run before resource or shared-tenant cleanup.' }
if (($Identities | ConvertTo-Json -Depth 5 -Compress) -ne ($fixture.EntraPlan | ConvertTo-Json -Depth 5 -Compress)) { throw 'Only the confirmed Entra identity plan may be deleted.' }
'@ | Set-Content -LiteralPath (Join-Path $directory 'remove-lab-entra-identities.ps1')

@'
[CmdletBinding(SupportsShouldProcess)]
param($SubscriptionId, $TenantId, $ResourceId)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or $ResourceId -ne $sreAgentId) { throw 'SRE cleanup lost the verified target.' }
if ($fixture.SreCleanupFails) { throw 'SRE Agent stop failed: currently being processed. No delete submitted.' }
$fixture.Deletes.Add($ResourceId)
return $true
'@ | Set-Content -LiteralPath (Join-Path $directory 'remove-sre-agent.ps1')

@'
[CmdletBinding(SupportsShouldProcess)]
param($SubscriptionId, $TenantId, $ResourceGroups, $ExistingResourceGroups, [switch]$PlanOnly, $Resources)
if ($SubscriptionId -ne $fixture.Subscription -or $TenantId -ne $fixture.Tenant -or
    $ResourceGroups -notcontains $fixture.ResourceGroup -or $ResourceGroups -contains $monitorGroup -or
    $ResourceGroups -contains 'rg-other-lab') { throw 'Purge cleanup escaped the verified target.' }
if ($PlanOnly) { $fixture.PurgePlans++; $fixture.PurgePlan; return }
if (-not $PSBoundParameters.ContainsKey('Confirm') -or $PSBoundParameters.Confirm) { throw 'Nested purge approval must be suppressed.' }
if (($Resources | ConvertTo-Json -Depth 5 -Compress) -ne ($fixture.PurgePlan | ConvertTo-Json -Depth 5 -Compress)) { throw 'Purge must use only the confirmed plan.' }
if (@($fixture.Deletes | Where-Object { $_ -like 'group:*' }).Count) { throw 'Purge must precede group deletion.' }
$fixture.PurgeCalls++
if ($fixture.PurgeFails) { throw 'Purge denied: AuthorizationFailed.' }
'@ | Set-Content -LiteralPath (Join-Path $directory 'remove-lab-soft-deleted-resources.ps1')

if ($IsWindows) {
  $argumentScript = Join-Path $directory 'capture-arguments.ps1'
  'ConvertTo-Json -InputObject @($args) -Compress' | Set-Content -LiteralPath $argumentScript
  $argumentShim = Join-Path $directory 'az.cmd'
  $nativePowerShell = Join-Path $PSHOME 'pwsh.exe'
  @"
@echo off
if exist "$nativePowerShell" (
  "$nativePowerShell" -NoProfile -NonInteractive -File "$argumentScript" %*
)
"@ | Set-Content -LiteralPath $argumentShim -Encoding ascii
}

function Read-Host {
  $fixture.ConfirmationReads++
  return $fixture.Confirm
}
function Start-Sleep {
  param([int] $Seconds)
  if ($Seconds -ne 10) { throw 'Unexpected managed-group polling interval.' }
  $fixture.MonitorSleeps++
}
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Wrong teardown subscription.' }
      if ($fixture.CliStderr) {
        $errorText = $fixture.CliStderr.Replace("'", "''")
        & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$errorText'); exit 0"
        $global:LASTEXITCODE = $LASTEXITCODE
      }
    }
    'account show' {
      return @{ id = $fixture.Subscription; tenantId = $(if ($fixture.BadTenant) { [guid]::NewGuid() } else { $fixture.Tenant }) } | ConvertTo-Json
    }
    'group list' {
      $fixture.GroupLists++
      $fixture.MonitorChecks = 0; $fixture.MonitorSleeps = 0
      $fixture.ConfirmationReads = 0
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Group discovery lost the verified subscription.' }
      if ($fixture.GroupInventoryFails) { $global:LASTEXITCODE = 1; return '[]' }
      $groups = @($groupInventory | Where-Object {
        ($fixture.PrimaryGroupExists -or $_.name -ne $fixture.ResourceGroup) -and
        ($fixture.AuxiliaryGroupExists -or $_.name -ne $auxiliaryGroup) -and
        (-not $fixture.HideMonitorGroup -or $_.name -ne $monitorGroup) -and
        ($fixture.NetworkWatcherGroupExists -or $_.name -ne 'NetworkWatcherRG')
      })
      return ConvertTo-Json -InputObject $groups -Depth 4
    }
    'group exists' {
      if ($fixture.RealTenantCleanup -and $args[[Array]::IndexOf($args, '-n') + 1] -eq $fixture.ResourceGroup) {
        return $fixture.PrimaryGroupExists.ToString().ToLowerInvariant()
      }
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne $monitorGroup) { throw 'Only the linked Monitor group needs a cascade check.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Managed-group cleanup lost the verified subscription.' }
      return $fixture.MonitorGroupExists.ToString().ToLowerInvariant()
    }
    'group show' {
      if ($args[[Array]::IndexOf($args, '-n') + 1] -ne $monitorGroup -or $args -notcontains '{id:id,managedBy:managedBy}' -or
          $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Unexpected managed-group owner check.' }
      if ($fixture.PrimaryGroupExists -and $fixture.Deletes -notcontains "group:$($fixture.ResourceGroup)") {
        throw 'Monitor cascade verification must follow the owning lab deletion request.'
      }
      $fixture.MonitorChecks++
      if ($fixture.MonitorLookupError) {
        & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$($fixture.MonitorLookupError)'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
        return
      }
      if (-not $fixture.MonitorGroupExists -or
          ($fixture.MonitorCleanupAfterChecks -gt 0 -and $fixture.MonitorChecks -gt $fixture.MonitorCleanupAfterChecks)) {
        $global:LASTEXITCODE = 3
        return "ERROR: (ResourceGroupNotFound) Resource group '$monitorGroup' could not be found."
      }
      $owner = $monitorWorkspaceId
      if ($fixture.MonitorOwnerChanged -or
          ($fixture.MonitorOwnerChangeAfterChecks -gt 0 -and $fixture.MonitorChecks -ge $fixture.MonitorOwnerChangeAfterChecks)) {
        $owner = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.Monitor/accounts/amw-amlab"
      }
      $id = "/subscriptions/$($fixture.Subscription)/resourceGroups/$monitorGroup"
      if ($fixture.MonitorWrongId) { $id = "/subscriptions/$otherSubscription/resourceGroups/$monitorGroup" }
      return @{ id = $id; managedBy = $owner } | ConvertTo-Json
    }
    'group delete' {
      $name = $args[[Array]::IndexOf($args, '-n') + 1]
      if ($name -eq $monitorGroup) { throw 'DenyAssignmentAuthorizationFailed: Monitor-managed groups must never be deleted directly.' }
      if ($name -notin @($fixture.ResourceGroup, $auxiliaryGroup, 'NetworkWatcherRG') -or $args -notcontains '--no-wait' -or $args -notcontains '--yes') { throw 'Unexpected resource group deletion.' }
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'Group deletion lost the verified subscription.' }
      $fixture.Deletes.Add("group:$name")
      if ($name -eq 'NetworkWatcherRG' -and $fixture.NetworkWatcherDeleteError) {
        $global:LASTEXITCODE = 1
        return $fixture.NetworkWatcherDeleteError
      }
      if ($fixture.GroupDeleteError) {
        & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$($fixture.GroupDeleteError)'); exit 1"
        $global:LASTEXITCODE = $LASTEXITCODE
      }
    }
    'resource list' {
      if ($args[[Array]::IndexOf($args, '-g') + 1] -ne $fixture.ResourceGroup) { throw 'Unexpected cleanup scope.' }
      if ($args -contains '--resource-type') {
        switch ($args[[Array]::IndexOf($args, '--resource-type') + 1]) {
          'Microsoft.Relationships/serviceGroupMember' {
            if ($fixture.ServiceGroupMembershipExists) { return ConvertTo-Json -InputObject @(@{ id = "$resourceGroupId/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg" }) }
            return '[]'
          }
          'Microsoft.App/agents' {
            if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) { throw 'SRE discovery lost the verified subscription.' }
            if ($fixture.SreDiscoveryFails) { $global:LASTEXITCODE = 1; return '[]' }
            if ($fixture.SreAgentExists) { return ConvertTo-Json -InputObject @(@{ id = $sreAgentId; name = 'sre-test' }) }
            return '[]'
          }
          'Microsoft.Monitor/observabilityAgents' {
            if ($fixture.ObservabilityAgentExists) { return ConvertTo-Json -InputObject @(@{ id = $observabilityAgentId; name = 'obs-amlab-test' }) }
            return '[]'
          }
          'Microsoft.OperationalInsights/workspaces' { return '[]' }
          'Microsoft.Insights/dataCollectionRuleAssociations' { return ConvertTo-Json -InputObject @(@{ id = $associationId }) }
          'Microsoft.Insights/dataCollectionRules' { return ConvertTo-Json -InputObject @(@{ id = $dcrId; name = 'dcr-test' }) }
          'Microsoft.Insights/dataCollectionEndpoints' { return ConvertTo-Json -InputObject @(@{ id = $dceId; name = 'dce-test' }) }
          default { throw 'Unexpected resource type.' }
        }
      }
      return ConvertTo-Json -InputObject @(@{ id = $workspaceId; name = 'law-test' }, @{ id = $unsupportedId; name = 'ContainerInsights(law-test)' })
    }
    { $_ -in @('rest --method', 'rest --subscription') } {
      $method = $args[[Array]::IndexOf($args, '--method') + 1]
      if ($method -eq 'delete' -and $fixture.RealTenantCleanup) {
        $uri = [uri]$args[[Array]::IndexOf($args, '--url') + 1]
        if ($uri.Host -ne 'management.azure.com' -or -not $tenantDeleteApis.Contains($uri.AbsolutePath) -or
            $uri.Query -ne "?api-version=$($tenantDeleteApis[$uri.AbsolutePath])" -or
            $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) {
          throw 'Unexpected tenant-scoped deletion target.'
        }
        $fixture.TenantCleanup.Add($uri.AbsolutePath)
        if ($fixture.TenantDeleteError) {
          $errorText = $fixture.TenantDeleteError.Replace("'", "''")
          & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$errorText'); exit 1"
          $global:LASTEXITCODE = $LASTEXITCODE
        }
        return
      }
      if ($method -ne 'get') { throw 'Only read-only association discovery is expected.' }
      $url = $args[[Array]::IndexOf($args, '--url') + 1]
      if ($url -eq "https://management.azure.com$observabilityAgentId/monitoredResources?api-version=2026-05-01-preview") {
        return @{
          value = @(@{
            properties = @{
              enabled = $true
              resourceId = $appInsightsId
            }
          })
        } | ConvertTo-Json -Depth 5
      }
      if ($url -eq "$workspaceId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") {
        return @{ value = @(@{ id = $associationId }, @{ id = $associationId }) } | ConvertTo-Json -Depth 4
      }
      if ($IsWindows) {
        $forwardedJson = & $argumentShim @args
        if ($LASTEXITCODE -ne 0) { throw 'Windows batch forwarding failed for the association discovery URL.' }
        $forwarded = @($forwardedJson | ConvertFrom-Json)
        if (($forwarded | ConvertTo-Json -Compress) -cne (@($args) | ConvertTo-Json -Compress)) { throw 'Windows batch forwarding changed the Azure CLI arguments.' }
      }
      if ($url -match '[()]' -or [Uri]::UnescapeDataString($url) -ne "$unsupportedId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11") {
        throw 'Association discovery must encode parenthesized resource names without changing the resource ID.'
      }
      & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('$($fixture.DiscoveryError)'); exit 1"
      $global:LASTEXITCODE = $LASTEXITCODE
    }
    'resource show' {
      if ($fixture.RealTenantCleanup -and $args[[Array]::IndexOf($args, '--ids') + 1] -eq "$resourceGroupId/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg") {
        return @{ properties = @{ targetId = $fixture.ServiceGroupResourceId } } | ConvertTo-Json
      }
      if ($args[[Array]::IndexOf($args, '--ids') + 1] -ne $observabilityAgentId -or
          $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString() -or
          $args[[Array]::IndexOf($args, '--api-version') + 1] -ne '2026-05-01-preview') {
        throw 'Unexpected Observability Agent identity lookup.'
      }
      return $observabilityPrincipalId
    }
    'role assignment' {
      $operation = $args[2]
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString()) {
        throw 'Observability Agent RBAC cleanup lost the verified subscription.'
      }
      if ($operation -eq 'list') {
        if ($args[[Array]::IndexOf($args, '--assignee-object-id') + 1] -ne $observabilityPrincipalId -or $args -contains '--all') {
          throw 'Unexpected Observability Agent RBAC lookup.'
        }
        $scope = $args[[Array]::IndexOf($args, '--scope') + 1]
        if ($scope -eq "/subscriptions/$($fixture.Subscription)") { return $observabilityRoleAssignmentId }
        if ($scope -eq $appInsightsId) {
          return @(@{
            id = $appInsightsRoleAssignmentId
            scope = $appInsightsId
            roleDefinitionId = "/subscriptions/$($fixture.Subscription)/providers/Microsoft.Authorization/roleDefinitions/43d0d8ad-25c7-4714-9337-8ba259a9fe05"
          }) | ConvertTo-Json -Depth 3
        }
        throw 'Unexpected Observability Agent RBAC scope.'
      }
      if ($operation -eq 'delete' -and $args[[Array]::IndexOf($args, '--ids') + 1] -in @($observabilityRoleAssignmentId, $appInsightsRoleAssignmentId)) {
        $fixture.Deletes.Add("role:$($args[[Array]::IndexOf($args, '--ids') + 1])")
        return
      }
      throw 'Unexpected role assignment operation.'
    }
    'resource delete' {
      $resourceId = $args[[Array]::IndexOf($args, '--ids') + 1]
      if ($resourceId -notin @($observabilityAgentId, $associationId, $dcrId, $dceId)) { throw 'Unexpected resource deletion.' }
      if ($resourceId -eq $observabilityAgentId -and $args[[Array]::IndexOf($args, '--api-version') + 1] -ne '2026-05-01-preview') {
        throw 'Observability Agent deletion must use its preview API.'
      }
      $fixture.Deletes.Add($resourceId)
    }
    'monitor diagnostic-settings' {
      $operation = $args[3]
      if ($operation -eq 'list') { return $fixture.ActivityWorkspaceId }
      if ($operation -ne 'delete' -or $args[[Array]::IndexOf($args, '--name') + 1] -ne 'amlab-activity-to-law' -or
          $args[[Array]::IndexOf($args, '--subscription') + 1] -ne $fixture.Subscription.ToString() -or
          $args -notcontains '--yes') {
        throw 'Unexpected subscription diagnostic-setting cleanup.'
      }
      $fixture.ActivityDiagnosticDeletes++
      return
    }
    default { throw 'Unexpected native Azure request.' }
  }
}

try {
  $fixture.DiscoveryError = 'ERROR: (UnsupportedResourceType) Associations unsupported for this resource.'
  $fixture.PurgePlan = @([pscustomobject]@{
    Id = "$resourceGroupId/providers/Microsoft.KeyVault/vaults/kv-test"
    Type = 'Microsoft.KeyVault/vaults'; Name = 'kv-test'; ResourceGroup = $fixture.ResourceGroup
    Location = 'northeurope'; Deleted = $false; PurgeProtected = $false
  })
  foreach ($purgeOption in @(@{}, @{ PurgeSoftDeletedResources = $false })) {
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
    $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes @purgeOption 3>&1 6>&1 | Out-String
    if ($fixture.PurgePlans -or $fixture.PurgeCalls -or $messages -match 'PERMANENT:' -or
        $fixture.Deletes -notcontains "group:$($fixture.ResourceGroup)") {
      throw 'Default teardown, including -Yes and explicit false, must delete the group without permanent-cleanup discovery or execution.'
    }
  }
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $fixture.Confirm = 'cancel'
  $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources 3>&1 6>&1 | Out-String
  if ($fixture.PurgeCalls -or $fixture.Deletes.Count -or $messages -notmatch 'PERMANENT:' -or $messages -notmatch 'without recovery') {
    throw 'Cancellation must preserve resources and show irreversible purge scope.'
  }
  $fixture.Confirm = 'DELETE'
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources -Yes | Out-Null
  if ($fixture.PurgeCalls -ne 1 -or $fixture.ConfirmationReads) { throw 'Explicit opt-in must execute the confirmed purge plan without another prompt.' }
  $plans = $fixture.PurgePlans
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null
  if ($fixture.PurgeCalls -ne 1 -or $fixture.PurgePlans -ne $plans) { throw 'Omitting the opt-in must skip purge discovery and execution.' }
  $fixture.PurgePlan[0].PurgeProtected = $true
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $failure = ''
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources -Yes | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike '*Purge protection*without -PurgeSoftDeletedResources*' -or $fixture.Deletes.Count) { throw 'Purge protection must block permanent cleanup before any deletion.' }
  $fixture.PurgePlan[0].PurgeProtected = $false
  $fixture.PurgeFails = $true
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $failure = ''
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources -Yes | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike '*AuthorizationFailed*' -or @($fixture.Deletes | Where-Object { $_ -like 'group:*' }).Count) { throw 'Failed purge must stop before group deletion.' }
  $fixture.PurgeFails = $false
  $fixture.PrimaryGroupExists = $false; $fixture.AuxiliaryGroupExists = $false
  $fixture.HideMonitorGroup = $true
  $fixture.PurgePlan[0].Deleted = $true
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $purges = $fixture.PurgeCalls
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources -Yes | Out-Null
  if ($fixture.PurgeCalls -ne $purges + 1 -or $fixture.Deletes.Count) { throw 'Deleted vault purge must work when no resource groups remain.' }
  $fixture.HideMonitorGroup = $false
  $fixture.PurgePlan[0].Type = 'Microsoft.OperationalInsights/workspaces'
  $fixture.PurgePlan[0].Name = 'law-test'
  $fixture.PurgePlan[0].Id = $workspaceId
  $fixture.PurgePlan[0].Deleted = $true
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -PurgeSoftDeletedResources -Yes | Out-Null
  if ($fixture.Deletes -notcontains "group:$($fixture.ResourceGroup)") { throw 'A recreated recovery group must be included in final group deletion.' }
  $fixture.PrimaryGroupExists = $true; $fixture.AuxiliaryGroupExists = $true
  $fixture.PurgePlan = @()
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  Write-Output 'PASS: default and -Yes preserve recovery without purge discovery; explicit purge is scoped, confirmed, precedes group deletion, blocks on protection/errors and includes recreated recovery groups. No Azure calls.'
  foreach ($invalidCase in @(
    @{ Arguments = @('--delete-networkwatcherrg'); Named = @{} },
    @{ Arguments = @('--delete-networkwatcherrg', 'true'); Named = @{} },
    @{ Arguments = @('--delete-networkwatcherrg', 'yes', '--delete-networkwatcherrg', 'yes'); Named = @{} },
    @{ Arguments = @('--delete-networkwatcherrg', 'yes'); Named = @{ DeleteNetworkWatcherRG = 'no' } },
    @{ Arguments = @(); Named = @{ DeleteNetworkWatcherRG = 'true' } },
    @{ Arguments = @(); Named = @{ ResourceGroup = 'NetworkWatcherRG' } }
  )) {
    $arguments = $invalidCase.Arguments
    $namedArguments = $invalidCase.Named
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear(); $fixture.EntraCalls.Clear()
    $fixture.GroupLists = 0
    $rejected = $false
    try { & (Join-Path $directory 'teardown.ps1') -Yes @namedArguments @arguments | Out-Null } catch {
      if ($_.Exception.Message -notmatch 'delete-networkwatcherrg|DeleteNetworkWatcherRG') { throw }
      $rejected = $true
    }
    if (-not $rejected -or $fixture.GroupLists -or $fixture.Deletes.Count -or $fixture.EntraCalls.Count) {
      throw 'Invalid or conflicting Network Watcher options must fail before Azure discovery or cleanup.'
    }
  }
  foreach ($optionCase in @(
    @{ Arguments = @(); Named = @{}; Delete = $false },
    @{ Arguments = @('--delete-networkwatcherrg', 'no'); Named = @{}; Delete = $false },
    @{ Arguments = @(); Named = @{ DeleteNetworkWatcherRG = 'no' }; Delete = $false },
    @{ Arguments = @('--delete-networkwatcherrg', 'yes'); Named = @{}; Delete = $true },
    @{ Arguments = @(); Named = @{ DeleteNetworkWatcherRG = 'yes' }; Delete = $true },
    @{ Arguments = @(); Named = @{ 'delete-networkwatcherrg' = 'yes' }; Delete = $true }
  )) {
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
    $arguments = $optionCase.Arguments
    $namedArguments = $optionCase.Named
    $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes @namedArguments @arguments 3>&1 6>&1 | Out-String
    if (($fixture.Deletes -contains 'group:NetworkWatcherRG') -ne $optionCase.Delete -or $fixture.ConfirmationReads) {
      throw 'NetworkWatcherRG must be deleted only after explicit yes; -Yes alone must preserve it.'
    }
    if ($optionCase.Delete -and ($messages -notmatch 'ENTIRE shared NetworkWatcherRG' -or $messages -notmatch 'unrelated resources')) {
      throw 'Whole shared NetworkWatcherRG deletion must have a visible warning.'
    }
  }
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $fixture.Confirm = 'cancel'
  $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup --delete-networkwatcherrg yes 3>&1 6>&1 | Out-String
  if ($fixture.Deletes.Count -or $fixture.ConfirmationReads -ne 1 -or $messages -notmatch 'ENTIRE shared NetworkWatcherRG') {
    throw 'Cancelling an opted-in teardown must preserve all groups and display the shared-resource warning.'
  }
  $fixture.Confirm = 'DELETE'
  $fixture.NetworkWatcherGroupExists = $false
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup --delete-networkwatcherrg yes -Yes | Out-Null
  if ($fixture.Deletes -contains 'group:NetworkWatcherRG') { throw 'An absent NetworkWatcherRG must not receive a delete request.' }
  $fixture.NetworkWatcherGroupExists = $true
  $fixture.PrimaryGroupExists = $false; $fixture.AuxiliaryGroupExists = $false
  $fixture.ActivityWorkspaceId = ''
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup --delete-networkwatcherrg yes -Yes | Out-Null
  if (($fixture.Deletes -join ',') -ne 'group:NetworkWatcherRG') {
    throw 'Explicit NetworkWatcherRG cleanup must work after the original lab group has been deleted.'
  }
  $fixture.PrimaryGroupExists = $true; $fixture.AuxiliaryGroupExists = $true
  $fixture.ActivityWorkspaceId = $workspaceId
  $fixture.BadTenant = $true
  $fixture.Deletes.Clear(); $fixture.GroupLists = 0
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup --delete-networkwatcherrg yes -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.GroupLists -or $fixture.Deletes.Count) {
    throw 'NetworkWatcherRG opt-in must not bypass the subscription/tenant guard.'
  }
  $fixture.BadTenant = $false
  $fixture.NetworkWatcherDeleteError = 'ERROR: (AuthorizationFailed) Shared group deletion denied.'
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup --delete-networkwatcherrg yes -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message.Contains($fixture.NetworkWatcherDeleteError) }
  if (-not $rejected) { throw 'NetworkWatcherRG deletion failures must retain Azure details and stop teardown.' }
  $fixture.NetworkWatcherDeleteError = ''
  $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
  Write-Output 'PASS: NetworkWatcherRG is preserved by default; explicit yes deletes only the exact shared group, warns, respects cancellation and account guards, and supports reruns. No Azure calls.'
  $warningExample = '  az monitor data-collection rule create --resource-group "myResourceGroup" --location "eastus" --name "myCollectionRule" --rule-file "C:\samples\dcrEx1.json"'
  foreach ($noiseCase in @(
    @{ Text = 'WARNING: Unrelated CLI diagnostic.'; Expected = 'WARNING: Unrelated CLI diagnostic.' },
    @{ Text = $warningExample; Expected = $warningExample },
    @{ Text = 'other_module.py:21: SyntaxWarning: "\s" is an invalid escape sequence.'; Expected = 'other_module.py:21: SyntaxWarning:' }
  )) {
    $fixture.CliStderr = $noiseCase.Text
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
    $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes 2>&1 6>&1 | Out-String
    if (-not $messages.Contains($noiseCase.Expected) -or $fixture.ConfirmationReads) {
      throw 'Teardown must preserve unrelated CLI diagnostics and never prompt with -Yes.'
    }
  }
  $fixture.CliStderr = ''
  Write-Output 'PASS: unrelated CLI diagnostics and standalone sample text remain visible; -Yes does not prompt. No Azure calls.'
  foreach ($nativePreference in @($true, $false)) {
    foreach ($discoveryCase in @(
      @{ Error = 'ERROR: Bad Request({"error":{"code":"UnsupportedResourceType","message":"Association cannot be created for this resource type."}})'; Skip = $true },
      @{ Error = 'ERROR: Bad Request({"error":{"code":"UnsupportedFeature","message":"Data Collection Rule Associations is not supported in the location of the targeted parent resource.","details":[{"code":"UnsupportedFeature","message":"This parent location cannot host DCR associations.","target":"UnsupportedFeature"}]}})'; Skip = $true },
      @{ Error = 'ERROR: (UnsupportedFeature) Data Collection Rule Associations is not supported in this parent location.'; Skip = $true },
      @{ Error = 'ERROR: (ResourceNotFound) No association endpoint at this resource.'; Skip = $true },
      @{ Error = 'ERROR: Not Found({"error":{"code":"NotFound","message":"No association endpoint."}})'; Skip = $true },
      @{ Error = 'ERROR: (AuthorizationFailed) Association discovery was denied.'; Skip = $false },
      @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"NotFound and UnsupportedResourceType are not the error code."}})'; Skip = $false },
      @{ Error = 'ERROR: Forbidden({"error":{"code":"AuthorizationFailed","message":"Association discovery was denied.","details":[{"code":"UnsupportedFeature","target":"UnsupportedFeature"}]}})'; Skip = $false },
      @{ Error = 'ERROR: (InternalServerError) Association discovery is unavailable.'; Skip = $false }
    )) {
      $fixture.DiscoveryError = $discoveryCase.Error
      $fixture.Deletes.Clear()
      $fixture.TenantCleanup.Clear()
      & {
        $PSNativeCommandUseErrorActionPreference = $nativePreference
        $failure = ''
        try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
        catch { $failure = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference) { throw 'Teardown changed the caller native-error preference.' }
        if ($discoveryCase.Skip) {
          if ($failure) { throw "Expected missing association discovery must not abort teardown: $failure" }
          $expectedDeletes = @($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup")
          if (($fixture.Deletes -join ',') -ne ($expectedDeletes -join ',')) { throw 'Associations must be deduplicated and monitoring cleanup must precede only the matched group deletions.' }
            if (($fixture.TenantCleanup -join ',') -ne 'setup-slis.ps1,setup-health-model.ps1') { throw 'Normal teardown must retain its tenant cleanup order.' }
        } elseif ($failure -notlike '*DCR association discovery failed*' -or -not $failure.Contains($unsupportedId) -or
              -not $failure.Contains($discoveryCase.Error) -or $fixture.Deletes.Count -or $fixture.TenantCleanup.Count) {
          throw "Unexpected discovery errors must retain Azure diagnostics and stop before cleanup deletes: $failure"
        }
      }
    }
  }
  $fixture.DiscoveryError = 'ERROR: (UnsupportedResourceType) Associations unsupported for this resource.'
  $fixture.ObservabilityAgentExists = $true
  $fixture.Deletes.Clear()
  $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null
  if (($fixture.Deletes[0..2] -join ',') -ne "role:$observabilityRoleAssignmentId,role:$appInsightsRoleAssignmentId,$observabilityAgentId") {
    throw 'Observability Agent subscription and Application Insights RBAC and resource must be deleted before monitoring dependencies and resource groups.'
  }
  $fixture.ObservabilityAgentExists = $false
  foreach ($sreCase in @(
    @{ DiscoveryFails = $false; CleanupFails = $false; Expected = '' },
    @{ DiscoveryFails = $true; CleanupFails = $false; Expected = '*Could not inspect SRE Agents*' },
    @{ DiscoveryFails = $false; CleanupFails = $true; Expected = '*currently being processed*' }
  )) {
    $fixture.SreAgentExists = $true
    $fixture.SreDiscoveryFails = $sreCase.DiscoveryFails
    $fixture.SreCleanupFails = $sreCase.CleanupFails
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear()
    $failure = ''
    try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
    catch { $failure = $_.Exception.Message }
    if ($sreCase.Expected) {
      if ($failure -notlike $sreCase.Expected -or $fixture.Deletes.Count) { throw "SRE failures must block monitoring and resource-group deletion: $failure" }
    } elseif ($failure -or $fixture.Deletes[0] -ne $sreAgentId) {
      throw "Verified SRE cleanup must precede monitoring/resource-group deletion: $failure"
    }
  }
  $fixture.SreAgentExists = $false; $fixture.SreDiscoveryFails = $false; $fixture.SreCleanupFails = $false
  Write-Output 'PASS: SRE discovery is subscription-scoped, uses guarded removal, and blocks resource-group cleanup on discovery/stop/delete failures. No Azure calls.'
  if ($fixture.ActivityDiagnosticDeletes -eq 0) { throw 'Teardown must remove Activity Log routing owned by the selected lab.' }
  $ownedDiagnosticDeletes = $fixture.ActivityDiagnosticDeletes
  $fixture.ActivityWorkspaceId = "/subscriptions/$($fixture.Subscription)/resourceGroups/rg-other-lab/providers/Microsoft.OperationalInsights/workspaces/law-other"
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -KeepServiceGroup -Yes | Out-Null
  if ($fixture.ActivityDiagnosticDeletes -ne $ownedDiagnosticDeletes) { throw 'Teardown must preserve Activity Log routing owned by another resource group.' }
  $fixture.ActivityWorkspaceId = $workspaceId
  $fixture.Deletes.Clear()
  $fixture.TenantCleanup.Clear()
  & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -KeepServiceGroup -Yes | Out-Null
  if ($fixture.TenantCleanup.Count -or ($fixture.Deletes -join ',') -ne (@($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup") -join ',')) {
    throw 'KeepServiceGroup must preserve tenant resources while still removing the selected lab.'
  }
  foreach ($monitorGroupExists in @($true, $false)) {
    $fixture.PrimaryGroupExists = $false
    $fixture.AuxiliaryGroupExists = $false
    $fixture.MonitorGroupExists = $monitorGroupExists
    $fixture.Deletes.Clear()
    $fixture.TenantCleanup.Clear()
    $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes 6>&1 | Out-String
    if ($fixture.Deletes.Count -or $fixture.TenantCleanup.Count -or $messages -notmatch 'absence verified \(ResourceGroupNotFound\)') {
      throw 'A rerun must verify Azure-managed cleanup without directly deleting the protected group.'
    }
    $expectedChecks = if ($monitorGroupExists) { 3 } else { 1 }
    if ($fixture.MonitorChecks -ne $expectedChecks -or $fixture.MonitorSleeps -ne ($expectedChecks - 1)) {
      throw 'Managed-group cleanup must poll only until authoritative absence.'
    }
  }
  $fixture.MonitorGroupExists = $true
  $fixture.MonitorCleanupAfterChecks = 0
  $fixture.Deletes.Clear()
  $failure = ''
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $failure = $_.Exception.Message }
  if ($failure -notlike '*not removed*within 600s*' -or -not $failure.Contains($monitorGroup) -or
      -not $failure.Contains($monitorWorkspaceId) -or $fixture.MonitorChecks -ne 60 -or
      $fixture.MonitorSleeps -ne 59 -or $fixture.Deletes.Count) {
    throw "Stalled Azure-managed cleanup must fail within bounded checks without directly deleting the group: $failure"
  }
  $fixture.MonitorCleanupAfterChecks = 2
  foreach ($nativePreference in @($true, $false)) {
    foreach ($lookupError in @(
      'ERROR: (AuthorizationFailed) Cannot inspect the protected managed group.',
      'ERROR: (AuthorizationFailed) ResourceGroupNotFound appears in this message, but is not the error code.',
      'ERROR: (InternalServerError) Managed group lookup failed.'
    )) {
      $fixture.MonitorLookupError = $lookupError
      $fixture.Deletes.Clear()
      & {
        $PSNativeCommandUseErrorActionPreference = $nativePreference
        $failure = ''
        try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
        catch { $failure = $_.Exception.Message }
        if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference -or
            $failure -notlike '*Could not verify Azure-managed cleanup*No absence was assumed*' -or
            -not $failure.Contains($lookupError) -or $fixture.MonitorChecks -ne 1 -or $fixture.Deletes.Count) {
          throw "Managed-group lookup errors must retain diagnostics and never imply absence: $failure"
        }
      }
    }
  }
  $fixture.MonitorLookupError = ''
  foreach ($ownershipCase in @(
    @{ Changed = $true; AfterChecks = 0; WrongId = $false; ExpectedChecks = 1 },
    @{ Changed = $false; AfterChecks = 2; WrongId = $false; ExpectedChecks = 2 },
    @{ Changed = $false; AfterChecks = 0; WrongId = $true; ExpectedChecks = 1 }
  )) {
    $fixture.MonitorOwnerChanged = $ownershipCase.Changed
    $fixture.MonitorOwnerChangeAfterChecks = $ownershipCase.AfterChecks
    $fixture.MonitorWrongId = $ownershipCase.WrongId
    $fixture.Deletes.Clear()
    $failure = ''
    try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike '*no longer owned*Refusing further cleanup*' -or $fixture.Deletes.Count -or
        $fixture.MonitorChecks -ne $ownershipCase.ExpectedChecks) {
      throw "Ownership changes and unexpected resource IDs must stop managed-group polling: $failure"
    }
  }
  $fixture.MonitorOwnerChanged = $false
  $fixture.MonitorOwnerChangeAfterChecks = 0; $fixture.MonitorWrongId = $false
  Write-Output 'PASS: Monitor-managed groups are never directly deleted; cascade verification handles absence, delayed cleanup, bounded timeouts, lookup errors, and ownership changes. No Azure calls.'
  $fixture.PrimaryGroupExists = $true
  $fixture.AuxiliaryGroupExists = $true
  $fixture.MonitorGroupExists = $true
  $fixture.GroupDeleteError = 'ERROR: (AuthorizationFailed) Lab resource group deletion was denied.'
  foreach ($nativePreference in @($true, $false)) {
    $fixture.Deletes.Clear()
    & {
      $PSNativeCommandUseErrorActionPreference = $nativePreference
      $failure = ''
      try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
      catch { $failure = $_.Exception.Message }
      if ($PSNativeCommandUseErrorActionPreference -ne $nativePreference -or
          $failure -notlike '*failed to submit deletion*' -or -not $failure.Contains($fixture.GroupDeleteError) -or
          $fixture.Deletes -contains "group:$auxiliaryGroup" -or $fixture.MonitorChecks) {
        throw "Ordinary resource-group deletion errors must block subsequent deletion and cascade verification: $failure"
      }
    }
  }
  $fixture.GroupDeleteError = ''
  $fixture.GroupInventoryFails = $true
  $fixture.Deletes.Clear()
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like '*Failed to list resource groups*' }
  if (-not $rejected -or $fixture.Deletes.Count) { throw 'Failed ownership discovery must stop before deletion.' }
  $fixture.GroupInventoryFails = $false
  $fixture.Deletes.Clear()
  $fixture.GroupLists = 0
  $fixture.BadTenant = $true
  $rejected = $false
  try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -Yes | Out-Null }
  catch { $rejected = $_.Exception.Message -like 'BLOCKED:*' }
  if (-not $rejected -or $fixture.GroupLists -or $fixture.Deletes.Count) { throw 'Account mismatch must stop teardown before resource discovery.' }
  $fixture.BadTenant = $false
  $fixture.Confirm = 'cancel'
  $confirmationOutput = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup 6>&1 | Out-String
  if ($fixture.Deletes.Count -or $fixture.ConfirmationReads -ne 1) { throw 'Cancelled teardown must ask once and not delete resources.' }
  if (-not $confirmationOutput.Contains($monitorGroup) -or $confirmationOutput.Contains('MA_amw-amlab_northeurope_managed_2')) {
    throw 'Confirmation must list the owned managed group and exclude another lab sharing the workspace name.'
  }
  $fixture.EntraPlan = @([pscustomobject]@{ DisplayName = 'owned-console'; ApplicationObjectId = [guid]::NewGuid().ToString(); ServicePrincipalObjectId = [guid]::NewGuid().ToString() })
  foreach ($entraCase in @(
    @{ Fail = ''; Keep = $false; Confirm = 'DELETE'; Expected = 'plan,delete' },
    @{ Fail = ''; Keep = $true; Confirm = 'DELETE'; Expected = '' },
    @{ Fail = 'plan'; Keep = $false; Confirm = 'DELETE'; Expected = 'plan' },
    @{ Fail = 'delete'; Keep = $false; Confirm = 'DELETE'; Expected = 'plan,delete' },
    @{ Fail = ''; Keep = $false; Confirm = 'cancel'; Expected = 'plan' }
  )) {
    $fixture.Deletes.Clear(); $fixture.TenantCleanup.Clear(); $fixture.EntraCalls.Clear()
    $fixture.EntraFails = $entraCase.Fail; $fixture.Confirm = $entraCase.Confirm
    $failure = ''
    try { $messages = & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -KeepEntraApplications:$entraCase.Keep 6>&1 | Out-String }
    catch { $failure = $_.Exception.Message }
    if (($fixture.EntraCalls -join ',') -ne $entraCase.Expected) { throw 'Teardown did not plan, confirm, and execute Entra cleanup in order.' }
    if ($entraCase.Fail) {
      if ($failure -ne 'Entra cleanup denied.' -or $fixture.Deletes.Count) { throw 'Directory failure must stop before deleting Azure resources.' }
    } elseif ($failure) { throw $failure }
    if ($entraCase.Confirm -eq 'cancel' -and ($fixture.Deletes.Count -or $messages -notmatch 'owned-console')) { throw 'Cancelled teardown must list the identity and make no changes.' }
  }
  $fixture.EntraFails = ''; $fixture.EntraPlan = @(); $fixture.EntraCalls.Clear(); $fixture.Confirm = 'DELETE'
  foreach ($helperName in @('setup-slis.ps1', 'setup-health-model.ps1', 'remove-arm-resource.ps1', 'resolve-service-group-id.ps1')) {
    Copy-Item -LiteralPath (Join-Path $source "scripts/$helperName") -Destination $directory -Force
  }
  $fixture.RealTenantCleanup = $true
  foreach ($tenantCase in @(
    @{ Error = ''; Fails = $false; Keep = $false; Membership = $true; Group = 'amlab-workload-123456abcdef' },
    @{ Error = ''; Fails = $false; Keep = $false; Membership = $true; Group = 'custom-lab-group' },
    @{ Error = 'ERROR: Not Found({"error":{"code":"ResourceNotFound","message":"The resource does not exist."}})'; Fails = $false; Keep = $false; Membership = $true },
    @{ Error = 'ERROR: (AuthorizationFailed) Tenant cleanup was denied.'; Fails = $true; Keep = $false; Membership = $true },
    @{ Error = 'ERROR: (AuthorizationFailed) Tenant cleanup was denied.'; Fails = $false; Keep = $true; Membership = $true },
    @{ Error = 'ERROR: (AuthorizationFailed) Tenant cleanup was denied.'; Fails = $false; Keep = $false; Membership = $false }
  )) {
    $groupName = if ($tenantCase.Group) { $tenantCase.Group } else { 'amlab-workload' }
    $fixture.ServiceGroupResourceId = "/providers/Microsoft.Management/serviceGroups/$groupName"
    $tenantDeleteApis = [ordered]@{}
    $tenantDeleteApis["$($fixture.ServiceGroupResourceId)/providers/Microsoft.Monitor/slis/sli-aks-pods-running"] = '2025-03-01-preview'
    $tenantDeleteApis["$($fixture.ServiceGroupResourceId)/providers/Microsoft.Monitor/slis/sli-aks-pod-start-latency"] = '2025-03-01-preview'
    $tenantDeleteApis["$resourceGroupId/providers/Microsoft.Relationships/serviceGroupMember/sgm-amlab-rg"] = '2023-09-01-preview'
    $tenantDeleteApis[$fixture.ServiceGroupResourceId] = '2024-02-01-preview'
    $fixture.TenantDeleteError = $tenantCase.Error
    $fixture.ServiceGroupMembershipExists = $tenantCase.Membership
    $fixture.Deletes.Clear()
    $fixture.TenantCleanup.Clear()
    & {
      $PSNativeCommandUseErrorActionPreference = $true
      $failure = ''
      try { & (Join-Path $directory 'teardown.ps1') -ResourceGroup $fixture.ResourceGroup -KeepServiceGroup:$tenantCase.Keep -Yes | Out-Null }
      catch { $failure = $_.Exception.Message }
      if (-not $PSNativeCommandUseErrorActionPreference) { throw 'Tenant cleanup changed the caller native-error preference.' }
      if ($tenantCase.Fails) {
        if (-not $failure.Contains($tenantCase.Error) -or $fixture.TenantCleanup.Count -ne 1 -or @($fixture.Deletes | Where-Object { $_ -like 'group:*' }).Count) {
          throw "Tenant cleanup failure must stop before resource group deletion with Azure diagnostics: $failure"
        }
      } else {
        $expectedDeletes = @($associationId, $dcrId, $dceId, "group:$($fixture.ResourceGroup)", "group:$auxiliaryGroup")
        $expectedTenantDeletes = if ($tenantCase.Keep -or -not $tenantCase.Membership) { @() } else { @($tenantDeleteApis.Keys) }
        if ($failure -or ($fixture.Deletes -join ',') -ne ($expectedDeletes -join ',') -or
            ($fixture.TenantCleanup -join ',') -ne ($expectedTenantDeletes -join ',')) {
          throw "Real tenant cleanup must continue on absent resources and skip shared resources when requested: $failure"
        }
      }
    }
  }
  Write-Output 'PASS: tenant cleanup requires an exact lab membership, continues on absent SLIs/groups, stops on proven-scope errors, and honors KeepServiceGroup. No Azure calls.'
  Write-Output 'PASS: Entra cleanup plans are confirmed and processed before Azure deletion; cancellation, directory failures, and KeepEntraApplications preserve identities. No Azure calls.'
  Write-Output 'PASS: unsupported and missing association probes work with both native-error preferences; unexpected failures retain diagnostics and block deletion. No Azure calls.'
  Write-Output 'PASS: cleanup order, deduplication, matched group scope, tenant guard, and cancellation are preserved. No Azure calls.'
  Write-Output 'PASS: Observability Agent subscription RBAC and resource are explicitly deleted before asynchronous resource-group cleanup. No Azure calls.'
  Write-Output 'PASS: KeepServiceGroup preserves shared tenant resources without skipping resource group cleanup. No Azure calls.'
  Write-Output 'PASS: managed Monitor groups follow exact subscription/RG/workspace ownership; other labs are excluded and automatic cleanup is verified on initial runs and reruns. No Azure calls.'
  if ($IsWindows) { Write-Output 'PASS: parenthesized ARM resource paths survive native Windows .cmd argument forwarding unchanged. No Azure calls.' }
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
}