$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..' 'cleanup-legacy-rbac.ps1'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
$logicModuleSource = Get-Content -Raw (Join-Path $repoRoot 'infra/modules/automitigation-logicapp.bicep')
$observabilityRbacSource = Get-Content -Raw (Join-Path $repoRoot 'infra/modules/observability-agent-resource-rbac.bicep')
$mainSource = Get-Content -Raw (Join-Path $repoRoot 'infra/main.bicep')
$observabilityStageSource = Get-Content -Raw (Join-Path $repoRoot 'infra/stages/70-observability-agent.bicep')
if ($logicModuleSource -notmatch "actions:\s*\[\s*'Microsoft\.Compute/virtualMachines/start/action'\s*\]" -or
    $logicModuleSource -notmatch 'scope:\s*linuxVm' -or
    $logicModuleSource -notmatch 'scope:\s*windowsVm' -or
    $observabilityRbacSource -notmatch 'scope:\s*appInsights' -or
    $mainSource -notmatch 'observability-agent-resource-rbac\.bicep' -or
    $observabilityStageSource -notmatch 'observability-agent-resource-rbac\.bicep' -or
    (Test-Path (Join-Path $repoRoot 'infra/modules/observability-agent-subscription-rbac.bicep'))) {
  throw 'Bicep RBAC modules must keep auto-mitigation VM-scoped and Observability Agent access on Application Insights.'
}

$subscription = [guid]::NewGuid()
$resourceGroup = 'rg-rbac-test'
$resourceGroupId = "/subscriptions/$subscription/resourceGroups/$resourceGroup"
$logicPrincipal = [guid]::NewGuid().ToString()
$agentPrincipal = [guid]::NewGuid().ToString()
$logicId = "$resourceGroupId/providers/Microsoft.Logic/workflows/la-amlab-automitigation"
$agentId = "$resourceGroupId/providers/Microsoft.Monitor/observabilityAgents/obs-amlab"
$vmId = "$resourceGroupId/providers/Microsoft.Compute/virtualMachines/vm-amlab-lin"
$appInsightsId = "$resourceGroupId/providers/Microsoft.Insights/components/appi-amlab"
$vmStartRoleId = [guid]::NewGuid().ToString()
$deletedAssignments = [Collections.Generic.List[string]]::new()
$missingLogicReplacement = $false
$missingAgentReplacement = $false

function az {
  $global:LASTEXITCODE = 0
  $command = $args[0..1] -join ' '
  switch ($command) {
    'account set' { return }
    'account show' { return (@{ id = $subscription } | ConvertTo-Json -Compress) }
    'group show' { return $resourceGroupId }
    'role definition' {
      if ($args[2] -ne 'list') { throw 'Unexpected role-definition command.' }
      return ConvertTo-Json -Depth 6 -InputObject @(@{
        id = "$resourceGroupId/providers/Microsoft.Authorization/roleDefinitions/$vmStartRoleId"
        roleName = 'Azure Monitor Lab VM Start'
      }) -Compress
    }
    'resource list' {
      if ($args -contains 'Microsoft.Logic/workflows') {
        return ConvertTo-Json -Depth 6 -InputObject @(@{ id = $logicId; name = 'la-amlab-automitigation' }) -Compress
      }
      if ($args -contains 'Microsoft.Monitor/observabilityAgents') {
        return ConvertTo-Json -Depth 6 -InputObject @(@{ id = $agentId; name = 'obs-amlab' }) -Compress
      }
      throw 'Unexpected resource-list command.'
    }
    'vm list' { return ConvertTo-Json -InputObject @($vmId) -Compress }
    'resource show' {
      $id = $args[[Array]::IndexOf($args, '--ids') + 1]
      if ($id -eq $logicId) {
        return ConvertTo-Json -Depth 6 -Compress @{ identity = @{ principalId = $logicPrincipal } }
      }
      if ($id -eq $agentId) {
        return ConvertTo-Json -Depth 6 -Compress @{ identity = @{ principalId = $agentPrincipal } }
      }
      throw "Unexpected resource lookup: $id"
    }
    'rest --subscription' {
      return ConvertTo-Json -Depth 6 -Compress @{ value = @(@{
        properties = @{ enabled = $true; resourceId = $appInsightsId }
      }) }
    }
    'rest --method' {
      return ConvertTo-Json -Depth 6 -Compress @{ value = @(@{
        properties = @{ enabled = $true; resourceId = $appInsightsId }
      }) }
    }
    'role assignment' {
      if ($args[2] -eq 'delete') {
        $deletedAssignments.Add($args[[Array]::IndexOf($args, '--ids') + 1])
        return
      }
      if ($args[2] -ne 'list') { throw 'Unexpected role-assignment command.' }
      $principal = $args[[Array]::IndexOf($args, '--assignee-object-id') + 1]
      if ($principal -eq $logicPrincipal) {
        $assignments = @(@{
          id = "$resourceGroupId/providers/Microsoft.Authorization/roleAssignments/legacy-logic"
          scope = $resourceGroupId
          roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
        })
        if (-not $missingLogicReplacement) {
          $assignments += @{
            id = "$vmId/providers/Microsoft.Authorization/roleAssignments/vm-start"
            scope = $vmId
            roleDefinitionId = "$resourceGroupId/providers/Microsoft.Authorization/roleDefinitions/$vmStartRoleId"
          }
        }
        return ConvertTo-Json -Depth 6 -InputObject $assignments -Compress
      }
      if ($principal -eq $agentPrincipal) {
        $assignments = @(@{
          id = "$resourceGroupId/providers/Microsoft.Authorization/roleAssignments/legacy-monitor-reader"
          scope = "/subscriptions/$subscription"
          roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/43d0d8ad-25c7-4714-9337-8ba259a9fe05"
        })
        if (-not $missingAgentReplacement) {
          $assignments += @{
            id = "$appInsightsId/providers/Microsoft.Authorization/roleAssignments/appi-monitor-reader"
            scope = $appInsightsId
            roleDefinitionId = "/subscriptions/$subscription/providers/Microsoft.Authorization/roleDefinitions/43d0d8ad-25c7-4714-9337-8ba259a9fe05"
          }
        }
        return ConvertTo-Json -Depth 6 -InputObject $assignments -Compress
      }
      throw "Unexpected role-assignment principal: $principal"
    }
    default { throw "Unexpected Azure CLI command: $command" }
  }
}

& $scriptPath -SubscriptionId $subscription -ResourceGroup $resourceGroup -AutoMitigation
if ($deletedAssignments.Count -ne 1 -or $deletedAssignments[0] -notlike '*legacy-logic') {
  throw 'Auto-mitigation migration did not remove exactly the verified legacy assignment.'
}

$deletedAssignments.Clear()
& $scriptPath -SubscriptionId $subscription -ResourceGroup $resourceGroup -ObservabilityAgent
if ($deletedAssignments.Count -ne 1 -or $deletedAssignments[0] -notlike '*legacy-monitor-reader') {
  throw 'Observability Agent migration did not remove exactly the verified legacy assignment.'
}

$missingLogicReplacement = $true
$deletedAssignments.Clear()
$logicMigrationRejected = $false
try {
  & $scriptPath -SubscriptionId $subscription -ResourceGroup $resourceGroup -AutoMitigation
} catch {
  $logicMigrationRejected = $_.Exception.Message -like '*retaining the resource-group Contributor assignment*'
}
if (-not $logicMigrationRejected -or $deletedAssignments.Count -ne 0) {
  throw 'Auto-mitigation migration removed a broad grant without every lab VM replacement.'
}

$missingLogicReplacement = $false
$missingAgentReplacement = $true
$deletedAssignments.Clear()
$agentMigrationRejected = $false
try {
  & $scriptPath -SubscriptionId $subscription -ResourceGroup $resourceGroup -ObservabilityAgent
} catch {
  $agentMigrationRejected = $_.Exception.Message -like '*retaining the subscription grant*'
}
if (-not $agentMigrationRejected -or $deletedAssignments.Count -ne 0) {
  throw 'Observability Agent migration removed a broad grant without its Application Insights replacement.'
}

Write-Output 'PASS: legacy RBAC grants are removed only after all replacement scopes are verified.'
