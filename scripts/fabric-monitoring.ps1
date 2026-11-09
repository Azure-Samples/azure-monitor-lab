function Get-FabricDefinitionContent {
  param(
    [Parameter(Mandatory)] [string] $ItemPath,
    [Parameter(Mandatory)] [string] $PartPath
  )

  $response = New-FabricItem -Path "$ItemPath/getDefinition" -Body @{}
  $parts = @($response.definition.parts | Where-Object path -CEQ $PartPath)
  if ($parts.Count -ne 1 -or $parts[0].payloadType -ne 'InlineBase64') {
    throw "Fabric definition for '$ItemPath' must contain one InlineBase64 '$PartPath' part."
  }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0].payload)) | ConvertFrom-Json
}

function Get-FabricWorkspaceMonitoringReadiness {
  param([Parameter(Mandatory)] [string] $WorkspaceId)

  $collection = "workspaces/$WorkspaceId/monitoringItems"
  $items = @(Get-FabricApiCollection -Path $collection)
  if ($items.Count -gt 1) {
    return [pscustomobject]@{
      Feature = 'Workspace monitoring'; Status = 'ActionRequired'
      Detail = 'Multiple Monitoring items exist. Select the collection owner in Fabric; setup will not transfer collection or change existing routes.'
    }
  }
  $manualSteps = "Manual post-deployment: a Fabric tenant admin enables 'Allow monitoring data collection' and the workspace-monitoring prerequisites. A workspace admin then creates/configures monitoring and enables collection in Fabric. Setup does not create items, enable collection or change tenant settings. See docs/STAGE-FABRIC.md#manual-monitoring-and-operations-agent-setup and https://app.fabric.microsoft.com/groups/$WorkspaceId"
  if (-not $items.Count) {
    return [pscustomobject]@{
      Feature = 'Workspace monitoring'; Status = 'ActionRequired'
      Detail = $manualSteps
    }
  }
  $item = $items[0]
  $path = "$collection/$($item.id)"
  $state = Invoke-RestMethod -Method Get -Uri "$fabricApi/$path" -Headers $script:fabricHeaders
  if ($state.properties.dataCollectionState -notin @('Enabled', 'Disabled')) {
    throw "Monitoring item $($item.id) returned unknown dataCollectionState '$($state.properties.dataCollectionState)'."
  }
  $enabled = $state.properties.dataCollectionState -eq 'Enabled'
  return [pscustomobject]@{
    Feature = 'Workspace monitoring'; Status = $(if ($enabled) { 'Configured' } else { 'ActionRequired' })
    Detail = $(if ($enabled) {
      "Monitoring item $($item.id): existing collection is Enabled. Read-only check; routes unchanged. Fresh telemetry is not verified; collection/storage consume capacity."
    } else {
      "Monitoring item $($item.id): collection is Disabled. $manualSteps"
    })
  }
}

function Get-FabricOperationsAgentReadiness {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [guid] $DatabaseId,
    [Parameter(Mandatory)] [string] $TableName,
    [Parameter(Mandatory)] [string] $Recipient
  )

  if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw 'Operations Agent telemetry table must be a KQL identifier.' }
  $collection = "workspaces/$WorkspaceId/operationsAgents"
  $name = 'Azure Monitor Lab Operations Agent'
  $existing = Get-CollectionItem -Path $collection -DisplayName $name
  if (-not $existing) {
    return [pscustomobject]@{
      Feature = 'Operations Agent'; Status = 'ActionRequired'
      Detail = "Manual post-deployment: create '$name' in Fabric, select the lab KQL database $DatabaseId and table $TableName, and configure Teams recipient $Recipient. Generate/review the playbook and start only after review. Setup does not submit an empty playbook, create or start an agent. See docs/STAGE-FABRIC.md#manual-monitoring-and-operations-agent-setup and https://app.fabric.microsoft.com/groups/$WorkspaceId"
    }
  }
  $item = $existing
  $saved = Get-FabricDefinitionContent -ItemPath "$collection/$($item.id)" -PartPath 'Configurations.json'
  $sources = @($saved.configuration.dataSources.PSObject.Properties | ForEach-Object Value)
  if ($sources.Count -ne 1 -or $sources[0].id -ne $DatabaseId.ToString() -or
      $sources[0].workspaceId -ne $WorkspaceId -or $sources[0].type -ne 'KustoDatabase') {
    return [pscustomobject]@{
      Feature = 'Operations Agent'; Status = 'ActionRequired'
      Detail = "Agent $($item.id) uses a different data source. Existing instructions, actions and run state were preserved; review it in Fabric."
    }
  }
  if ($saved.shouldRun -isnot [bool]) { throw "Operations Agent $($item.id) returned no Boolean shouldRun state." }
  return [pscustomobject]@{
    Feature = 'Operations Agent'; Status = $(if ($saved.shouldRun) { 'Configured' } else { 'ActionRequired' })
    Detail = "Agent $($item.id): saved shouldRun=$($saved.shouldRun). Read-only check; instructions, actions, recipient and run state are unchanged. If stopped, review instructions and generate/review the playbook before starting in Fabric. Agent behavior is not verified. See docs/STAGE-FABRIC.md#manual-monitoring-and-operations-agent-setup and https://app.fabric.microsoft.com/groups/$WorkspaceId"
  }
}
