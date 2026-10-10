<#
.SYNOPSIS
  Remove obsolete broad RBAC grants after their least-privilege replacements deploy.

.DESCRIPTION
  Removes only the lab Logic App's resource-group Contributor grant and the
  Observability Agent's subscription Monitoring Reader grant. Replacement scopes
  are checked before removing each legacy assignment.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [switch] $AutoMitigation,
  [switch] $ObservabilityAgent
)

$ErrorActionPreference = 'Stop'
$vmStartRoleName = 'Azure Monitor Lab VM Start'
$legacyContributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
$monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
$observabilityApiVersion = '2026-05-01-preview'

if (-not $AutoMitigation -and -not $ObservabilityAgent) {
  throw 'Select at least one RBAC migration with -AutoMitigation or -ObservabilityAgent.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI is required. Install it and run az login before continuing.'
}

function Invoke-AzJson {
  param(
    [Parameter(Mandatory)] [string[]] $AzArguments,
    [Parameter(Mandatory)] [string] $Operation
  )

  $output = & az @AzArguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed (exit code $LASTEXITCODE):`n$($output -join "`n")"
  }
  $json = $output -join "`n"
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }
  return @($json | ConvertFrom-Json)
}

function Test-RoleDefinitionId {
  param([string] $Actual, [string] $Expected)
  if ([string]::IsNullOrWhiteSpace($Actual)) { return $false }
  return $Actual.TrimEnd('/').Split('/')[-1] -ieq $Expected
}

function Remove-Assignments {
  param(
    [object[]] $Assignments,
    [string] $Description
  )

  foreach ($assignment in $Assignments) {
    Write-Host "Removing $Description assignment $($assignment.id) ..." -ForegroundColor DarkGray
    $output = & az role assignment delete --subscription $SubscriptionId --ids $assignment.id --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Could not remove $Description assignment '$($assignment.id)':`n$($output -join "`n")"
    }
  }
  if ($Assignments.Count -eq 0) {
    Write-Host "No obsolete $Description assignment found." -ForegroundColor DarkGray
  }
}

az account set --subscription $SubscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Could not select subscription '$SubscriptionId'." }
$account = Invoke-AzJson -AzArguments @('account', 'show', '--query', '{id:id}', '--output', 'json', '--only-show-errors') -Operation 'Azure account verification'
if ($account.id -ne $SubscriptionId.ToString()) {
  throw "Active subscription '$($account.id)' does not match expected subscription '$SubscriptionId'."
}
$resourceGroupIdOutput = & az group show --subscription $SubscriptionId --name $ResourceGroup --query id --output tsv --only-show-errors 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$ResourceGroup' lookup failed (exit code $LASTEXITCODE):`n$($resourceGroupIdOutput -join "`n")"
}
$resourceGroupId = [string]($resourceGroupIdOutput -join '').Trim()
if ([string]::IsNullOrWhiteSpace($resourceGroupId)) {
  throw "Could not resolve resource group '$ResourceGroup'."
}

if ($AutoMitigation) {
  $roleDefinitions = Invoke-AzJson -AzArguments @(
    'role', 'definition', 'list', '--subscription', $SubscriptionId.ToString(),
    '--scope', $resourceGroupId, '--name', $vmStartRoleName, '--output', 'json', '--only-show-errors'
  ) -Operation "Checking the '$vmStartRoleName' role"
  $replacementRole = @($roleDefinitions | Where-Object { $_.roleName -eq $vmStartRoleName })

  if ($replacementRole.Count -eq 0) {
    Write-Host "The '$vmStartRoleName' role is not deployed; retaining any existing Logic App assignment." -ForegroundColor Yellow
  } else {
    if ($replacementRole.Count -ne 1) {
      throw "Expected one '$vmStartRoleName' role definition in '$ResourceGroup'; found $($replacementRole.Count)."
    }
    $logicApps = Invoke-AzJson -AzArguments @(
      'resource', 'list', '--subscription', $SubscriptionId.ToString(), '--resource-group', $ResourceGroup,
      '--resource-type', 'Microsoft.Logic/workflows', '--output', 'json', '--only-show-errors'
    ) -Operation 'Logic App discovery'
    $labLogicApps = @($logicApps | Where-Object { $_.name -match '^la-.+-(automitigation|automitigate)$' })
    $labVmIds = Invoke-AzJson -AzArguments @(
      'vm', 'list', '--subscription', $SubscriptionId.ToString(), '--resource-group', $ResourceGroup,
      '--query', "[?tags.purpose=='azure-monitor-lab'].id", '--output', 'json', '--only-show-errors'
    ) -Operation 'Lab VM discovery'

    foreach ($logicApp in $labLogicApps) {
      $logic = Invoke-AzJson -AzArguments @(
        'resource', 'show', '--subscription', $SubscriptionId.ToString(), '--ids', $logicApp.id,
        '--api-version', '2019-05-01', '--output', 'json', '--only-show-errors'
      ) -Operation "Logic App identity lookup for '$($logicApp.name)'"
      $principalId = [string]$logic.identity.principalId
      if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Logic App '$($logicApp.name)' has no system-assigned principal ID."
      }

      $assignments = Invoke-AzJson -AzArguments @(
        'role', 'assignment', 'list', '--subscription', $SubscriptionId.ToString(),
        '--assignee-object-id', $principalId, '--all', '--output', 'json', '--only-show-errors'
      ) -Operation "RBAC lookup for Logic App '$($logicApp.name)'"
      foreach ($vmId in $labVmIds) {
        $vmAssignment = @($assignments | Where-Object {
          $_.scope.TrimEnd('/') -ieq ([string]$vmId).TrimEnd('/') -and
          (Test-RoleDefinitionId -Actual $_.roleDefinitionId -Expected $replacementRole[0].id.Split('/')[-1])
        })
        if ($vmAssignment.Count -eq 0) {
          throw "VM-scoped '$vmStartRoleName' access on '$vmId' is missing; retaining the resource-group Contributor assignment."
        }
      }
      if ($labVmIds.Count -eq 0) {
        Write-Host 'No lab-tagged standalone VMs were found; the Logic App has no VM start targets.' -ForegroundColor DarkGray
      }
      $legacy = @($assignments | Where-Object {
        $_.scope.TrimEnd('/') -ieq $resourceGroupId.TrimEnd('/') -and
        (Test-RoleDefinitionId -Actual $_.roleDefinitionId -Expected $legacyContributorRoleId)
      })
      Remove-Assignments -Assignments $legacy -Description "resource-group Contributor for '$($logicApp.name)'"
    }
  }
}

if ($ObservabilityAgent) {
  $agents = Invoke-AzJson -AzArguments @(
    'resource', 'list', '--subscription', $SubscriptionId.ToString(), '--resource-group', $ResourceGroup,
    '--resource-type', 'Microsoft.Monitor/observabilityAgents', '--output', 'json', '--only-show-errors'
  ) -Operation 'Observability Agent discovery'
  if ($agents.Count -gt 1) {
    throw "Expected at most one Observability Agent in '$ResourceGroup'; found $($agents.Count)."
  }

  foreach ($agentResource in $agents) {
    $agent = Invoke-AzJson -AzArguments @(
      'resource', 'show', '--subscription', $SubscriptionId.ToString(), '--ids', $agentResource.id,
      '--api-version', $observabilityApiVersion, '--output', 'json', '--only-show-errors'
    ) -Operation "Observability Agent identity lookup for '$($agentResource.name)'"
    $principalId = [string]$agent.identity.principalId
    if ([string]::IsNullOrWhiteSpace($principalId)) {
      throw "Observability Agent '$($agentResource.name)' has no system-assigned principal ID."
    }

    $monitoredResources = Invoke-AzJson -AzArguments @(
      'rest', '--subscription', $SubscriptionId.ToString(), '--method', 'get',
      '--url', "https://management.azure.com$($agent.id)/monitoredResources?api-version=$observabilityApiVersion",
      '--output', 'json', '--only-show-errors'
    ) -Operation "Monitored-resource lookup for '$($agentResource.name)'"
    $appInsightsResources = @($monitoredResources.value | Where-Object {
      $_.properties.enabled -and $_.properties.resourceId -match '/providers/Microsoft\.Insights/components/'
    })
    if ($appInsightsResources.Count -ne 1) {
      throw "Expected one enabled Application Insights resource for '$($agentResource.name)'; found $($appInsightsResources.Count)."
    }
    $appInsightsId = [string]$appInsightsResources[0].properties.resourceId

    $assignments = Invoke-AzJson -AzArguments @(
      'role', 'assignment', 'list', '--subscription', $SubscriptionId.ToString(),
      '--assignee-object-id', $principalId, '--all', '--output', 'json', '--only-show-errors'
    ) -Operation "RBAC lookup for Observability Agent '$($agentResource.name)'"
    $replacement = @($assignments | Where-Object {
      $_.scope.TrimEnd('/') -ieq $appInsightsId.TrimEnd('/') -and
      (Test-RoleDefinitionId -Actual $_.roleDefinitionId -Expected $monitoringReaderRoleId)
    })
    if ($replacement.Count -eq 0) {
      throw "The resource-scoped Monitoring Reader assignment on '$appInsightsId' is missing; retaining the subscription grant."
    }

    $subscriptionScope = "/subscriptions/$SubscriptionId"
    $legacy = @($assignments | Where-Object {
      $_.scope.TrimEnd('/') -ieq $subscriptionScope.TrimEnd('/') -and
      (Test-RoleDefinitionId -Actual $_.roleDefinitionId -Expected $monitoringReaderRoleId)
    })
    Remove-Assignments -Assignments $legacy -Description "subscription Monitoring Reader for '$($agentResource.name)'"
  }
}

Write-Host 'Legacy RBAC migration completed.' -ForegroundColor Green
