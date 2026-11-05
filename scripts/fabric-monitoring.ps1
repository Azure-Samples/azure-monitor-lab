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

function Initialize-FabricWorkspaceMonitoring {
  param([Parameter(Mandatory)] [string] $WorkspaceId)

  $collection = "workspaces/$WorkspaceId/monitoringItems"
  $items = @(Get-FabricApiCollection -Path $collection)
  if ($items.Count -gt 1) {
    return [pscustomobject]@{
      Feature = 'Workspace monitoring'; Status = 'ActionRequired'
      Detail = 'Multiple Monitoring items exist. Select the collection owner in Fabric; setup will not transfer collection or change existing routes.'
    }
  }
  if ($items.Count -eq 1) {
    $item = $items[0]
  } else {
    $properties = @{
      '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/monitoring/definition/monitoringProperties/1.0.0/schema.json'
      dataCollectionSettings = @(@{
        sources = @{ workspaceDiagnostics = @{ mode = 'All' } }
        destinations = @{ eventhouse = @{ mode = 'Auto' } }
      })
    }
    $item = Ensure-FabricItem -CollectionPath $collection -DisplayName 'AzureMonitorLabMonitoring' -CreateBody @{
      displayName = 'AzureMonitorLabMonitoring'
      description = 'Workspace diagnostics for supported Fabric items. Additional storage and capacity usage apply.'
      definition = @{
        format = 'MonitoringV1'
        parts = @(@{
          path = 'MonitoringProperties.json'
          payload = ConvertTo-InlineBase64 ($properties | ConvertTo-Json -Depth 10 -Compress)
          payloadType = 'InlineBase64'
        })
      }
    }
  }

  $path = "$collection/$($item.id)"
  $saved = Get-FabricDefinitionContent -ItemPath $path -PartPath 'MonitoringProperties.json'
  if (-not $saved.dataCollectionSettings -or @($saved.dataCollectionSettings).Count -ne 1 -or
      -not $saved.dataCollectionSettings[0].destinations.eventhouse) {
    return [pscustomobject]@{
      Feature = 'Workspace monitoring'; Status = 'ActionRequired'
      Detail = "Monitoring item $($item.id) has no collection route. Configure its destination in Fabric; setup preserves existing definitions."
    }
  }
  $state = Invoke-RestMethod -Method Get -Uri "$fabricApi/$path" -Headers $script:fabricHeaders
  if ($state.properties.dataCollectionState -eq 'Disabled') {
    Invoke-RestMethod -Method Post -Uri "$fabricApi/$path/enableDataCollection" -Headers $script:fabricHeaders | Out-Null
    $state = Invoke-RestMethod -Method Get -Uri "$fabricApi/$path" -Headers $script:fabricHeaders
  }
  if ($state.properties.dataCollectionState -notin @('Enabled', 'Disabled')) {
    throw "Monitoring item $($item.id) returned unknown dataCollectionState '$($state.properties.dataCollectionState)'."
  }
  $enabled = $state.properties.dataCollectionState -eq 'Enabled'
  return [pscustomobject]@{
    Feature = 'Workspace monitoring'; Status = $(if ($enabled) { 'Configured' } else { 'Pending' })
    Detail = "Monitoring item $($item.id): collection state $($state.properties.dataCollectionState). Existing routes preserved. First telemetry arrival is not verified; collection/storage consume capacity."
  }
}

function Initialize-FabricOperationsAgent {
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
  $instructions = @"
Monitor the Azure Monitor lab's live operational telemetry in table $TableName.
Recommend an investigation when no rows have ingestion_time() in the last 15 minutes.
Distinguish ingestion silence from application failure, and capacity suspension from an outage.
Report supporting timestamps and counts, and uncertainty. Never treat LabSampleEvents or other synthetic examples as customer impact.
Send recommendations to the configured Teams recipient. Do not execute remediation, invoke jobs or flows, change resources, or grant permissions.
"@
  $configuration = @{
    configuration = @{
      instructions = $instructions
      dataSources = @{ labTelemetry = @{ id = $DatabaseId.ToString(); type = 'KustoDatabase'; workspaceId = $WorkspaceId } }
      actions = @{}
      messageDestination = @{ kind = 'Recipient'; recipient = $Recipient }
    }
    playbook = @{}
    shouldRun = $false
  }
  $item = Ensure-FabricItem -CollectionPath $collection -DisplayName $name -CreateBody @{
    displayName = $name
    description = 'Recommendation-only lab agent. Created stopped; review the generated playbook before starting.'
    definition = @{
      format = 'OperationsAgentV1'
      parts = @(@{
        path = 'Configurations.json'
        payload = ConvertTo-InlineBase64 ($configuration | ConvertTo-Json -Depth 10 -Compress)
        payloadType = 'InlineBase64'
      })
    }
  }
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
  if (-not $existing -and ($saved.shouldRun -or $saved.configuration.instructions -ne $instructions -or
      @($saved.configuration.actions.PSObject.Properties).Count -ne 0 -or
      $saved.configuration.messageDestination.kind -ne 'Recipient' -or
      $saved.configuration.messageDestination.recipient -ne $Recipient)) {
    throw "Operations Agent $($item.id) saved configuration differs from the requested stopped, recommendation-only definition."
  }
  return [pscustomobject]@{
    Feature = 'Operations Agent'; Status = 'ActionRequired'
    Detail = "Agent $($item.id): saved shouldRun=$($saved.shouldRun). Review instructions, generate/review the playbook and start in Fabric when ready. Existing agents are never overwritten, stopped or started. https://app.fabric.microsoft.com/groups/$WorkspaceId"
  }
}
