function Invoke-FabricKql {
  param(
    [Parameter(Mandatory)] [string] $QueryServiceUri,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $Query,
    [switch] $Management
  )

  $endpoint = [uri]$QueryServiceUri
  if ($endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Query -or
      $endpoint.AbsolutePath -ne '/' -or
      ($endpoint.DnsSafeHost -notlike '*.kusto.fabric.microsoft.com' -and $endpoint.DnsSafeHost -notlike '*.kusto.windows.net')) {
    throw 'Fabric returned an unexpected KQL service endpoint.'
  }
  $token = az account get-access-token --resource https://api.kusto.windows.net --query accessToken -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Could not acquire a Kusto API token.' }
  try {
    $route = if ($Management) { 'mgmt' } else { 'query' }
    $response = Invoke-RestMethod -Method Post -Uri "$($QueryServiceUri.TrimEnd('/'))/v1/rest/$route" `
      -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' `
      -Body (@{ db = $DatabaseName; csl = $Query } | ConvertTo-Json -Compress)
    if ($response.error -or $response.Exceptions) {
      throw "KQL request failed: $(@($response.error; $response.Exceptions) | ConvertTo-Json -Depth 8 -Compress)"
    }
    if ($null -eq $response.Tables) { throw 'KQL returned no result tables.' }
    foreach ($statusTable in @($response.Tables | Where-Object TableName -eq QueryStatus)) {
      $names = @($statusTable.Columns | ForEach-Object { $_.ColumnName })
      $severityIndex = [Array]::IndexOf($names, 'Severity')
      if ($severityIndex -lt 0) { throw 'KQL returned a malformed QueryStatus table.' }
      foreach ($row in $statusTable.Rows) {
        if ([int]$row[$severityIndex] -le 2) { throw "KQL reported a partial failure: $($row -join ' | ')" }
      }
    }
    return $response
  } finally {
    $token = $null
  }
}

function Get-FabricKqlScalar {
  param(
    [Parameter(Mandatory)] $Response,
    [Parameter(Mandatory)] [string] $ColumnName
  )
  foreach ($table in $Response.Tables) {
    $names = @($table.Columns | ForEach-Object { $_.ColumnName })
    $index = [Array]::IndexOf($names, $ColumnName)
    if ($index -ge 0 -and $table.Rows.Count -gt 0) { return $table.Rows[0][$index] }
  }
  throw "KQL response is missing scalar '$ColumnName'."
}

function Wait-FabricTelemetry {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventstreamId,
    [Parameter(Mandatory)] [string] $QueryServiceUri,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $TableName,
    [ValidateRange(1, 900)] [int] $TimeoutSeconds = 180
  )

  if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw 'Telemetry table name must be a KQL identifier.' }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $attempts = [Math]::Max(1, [Math]::Ceiling($TimeoutSeconds / 10))
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $topology = Invoke-RestMethod -Method Get `
      -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/topology" -Headers $script:fabricHeaders
    if (-not $topology.sources -or -not $topology.destinations) { throw 'Eventstream topology is missing its source or destination. Repair the stream and rerun setup.' }
    $failed = @(@($topology.sources) + @($topology.destinations) | Where-Object { $_.status -eq 'Failed' })
    if ($failed.Count) { throw "Eventstream data flow failed: $($failed.name -join ', ')." }
    $tables = Invoke-FabricKql -QueryServiceUri $QueryServiceUri -DatabaseName $DatabaseName -Query '.show tables' -Management
    $exists = @($tables.Tables | ForEach-Object {
      $names = @($_.Columns | ForEach-Object { $_.ColumnName })
      $index = [Array]::IndexOf($names, 'TableName')
      if ($index -ge 0) {
        foreach ($row in $_.Rows) { if ($row[$index] -eq $TableName) { $true } }
      }
    }).Count -gt 0
    if ($exists) {
      $response = Invoke-FabricKql -QueryServiceUri $QueryServiceUri -DatabaseName $DatabaseName `
        -Query "$TableName | where ingestion_time() > ago(15m) | count"
      $count = [long](Get-FabricKqlScalar -Response $response -ColumnName 'Count')
      if ($count -gt 0) {
        return [pscustomobject]@{ Feature = 'Live ingestion'; Status = 'Verified'; Detail = "$count rows ingested in the last 15 minutes into $TableName." }
      }
    }
    if ([DateTime]::UtcNow.AddSeconds(10) -ge $deadline -or $attempt -eq $attempts - 1) { break }
    Start-Sleep -Seconds 10
  }
  return [pscustomobject]@{
    Feature = 'Live ingestion'; Status = 'Pending'
    Detail = "No recent telemetry in $TableName within ${TimeoutSeconds}s. Generate application traffic, inspect Eventstream Live view and rerun setup."
  }
}

function Initialize-FabricSampleData {
  param(
    [Parameter(Mandatory)] [string] $QueryServiceUri,
    [Parameter(Mandatory)] [string] $DatabaseName
  )
  $arguments = @{ QueryServiceUri = $QueryServiceUri; DatabaseName = $DatabaseName; Management = $true }
  Invoke-FabricKql @arguments -Query '.create-merge table LabSampleEvents (SampleId:string, Timestamp:datetime, Kind:string, Service:string, CorrelationId:string, Outcome:string, Amount:real, IsSynthetic:bool)' | Out-Null
  $query = @'
.set-or-append LabSampleEvents <|
datatable(SampleId:string, Kind:string, Service:string, CorrelationId:string, Outcome:string, Amount:real)
[
  'amlab-synthetic-v1-op-1', 'Operational', 'SYNTHETIC customer app', 'SYNTHETIC-001', 'Error', 0.0,
  'amlab-synthetic-v1-order-1', 'Business', 'SYNTHETIC customer app', 'SYNTHETIC-001', 'Failed', 49.0,
  'amlab-synthetic-v1-op-2', 'Operational', 'SYNTHETIC customer app', 'SYNTHETIC-002', 'Healthy', 0.0,
  'amlab-synthetic-v1-order-2', 'Business', 'SYNTHETIC customer app', 'SYNTHETIC-002', 'Completed', 25.0
]
| where SampleId !in (LabSampleEvents | project SampleId)
| extend Timestamp = now(), IsSynthetic = true
| project SampleId, Timestamp, Kind, Service, CorrelationId, Outcome, Amount, IsSynthetic
'@
  Invoke-FabricKql @arguments -Query $query | Out-Null
  $response = Invoke-FabricKql -QueryServiceUri $QueryServiceUri -DatabaseName $DatabaseName `
    -Query "LabSampleEvents | where SampleId startswith 'amlab-synthetic-v1-' and IsSynthetic == true | summarize Samples=dcount(SampleId)"
  if ([long](Get-FabricKqlScalar -Response $response -ColumnName Samples) -ne 4) {
    throw 'Synthetic correlation sample verification failed: expected four distinct sample events.'
  }
}

function Write-FabricSetupSummary {
  param([Parameter(Mandatory)] [object[]] $Results)
  Write-Host "`nFabric setup results" -ForegroundColor Cyan
  $Results | Format-Table Feature, Status, Detail -Wrap -AutoSize | Out-Host
  $incomplete = @($Results | Where-Object { $_.Status -in @('Pending', 'ActionRequired', 'Failed') })
  if ($incomplete.Count) {
    Write-Warning 'Fabric setup is partial. Follow the actions above; resource creation alone does not verify a healthy data flow.'
  } else {
    Write-Host 'All requested automatable Fabric setup steps completed.' -ForegroundColor Green
  }
  if (@($Results | Where-Object Status -eq 'Failed').Count) { throw 'One or more Fabric automation steps failed. See the setup results above.' }
}

function New-FabricDashboardDefinition {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $QueryServiceUri,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $TableName,
    [bool] $IncludeSampleData = $true
  )
  if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw 'Telemetry table name must be a KQL identifier.' }
  $pageId = '23acdd3d-a4b3-4ad1-b93f-9702966bdfb0'
  $dataSourceId = '22c5b148-7ca3-4201-af93-d86b134875c1'
  $liveQuery = "union isfuzzy=true (datatable(IngestedAt:datetime, Payload:string)[]), ($TableName | project IngestedAt=ingestion_time(), Payload=tostring(pack_all()))"
  $tiles = @(
    @{
      id = '993183ed-f2de-42ef-9987-a96bb5b59f36'; title = 'Live ingestion rate (last hour)'
      query = "$liveQuery | where IngestedAt > ago(1h) | summarize Events=count() by bin(IngestedAt, 5m) | render timechart"
      layout = @{ x = 0; y = 0; width = 12; height = 5 }
      pageId = $pageId; dataSourceId = $dataSourceId; visualType = 'line'; usedParamVariables = @()
      visualOptions = @{}
    }
    @{
      id = '91ae253d-d3c9-471f-bda0-6c8c0c6a9c5f'; title = 'Recent live telemetry (raw payload)'
      query = "$liveQuery | where IngestedAt > ago(1h) | top 20 by IngestedAt desc"
      layout = @{ x = 0; y = 5; width = 12; height = 5 }
      pageId = $pageId; dataSourceId = $dataSourceId; visualType = 'table'; usedParamVariables = @()
      visualOptions = @{}
    }
  )
  if ($IncludeSampleData) {
    $tiles += @{
      id = 'ab9bce2a-859b-49e4-aee5-9275854cbd0a'; title = 'SYNTHETIC business correlation - not live customer orders'
      query = @'
LabSampleEvents
| where IsSynthetic == true and Kind == 'Operational'
| project CorrelationId, Service, OperationalOutcome=Outcome
| join kind=inner (
    LabSampleEvents
    | where IsSynthetic == true and Kind == 'Business'
    | project CorrelationId, BusinessOutcome=Outcome, Amount
  ) on CorrelationId
| project CorrelationId, Service, OperationalOutcome, BusinessOutcome, Amount
'@
      layout = @{ x = 0; y = 10; width = 12; height = 5 }
      pageId = $pageId; dataSourceId = $dataSourceId; visualType = 'table'; usedParamVariables = @()
      visualOptions = @{}
    }
  }
  return @{
    '$schema' = 'https://dataexplorer.azure.com/static/d/schema/20/dashboard.json'
    schema_version = '20'
    title = 'Azure Monitor Demo Live Health'
    tiles = $tiles
    parameters = @()
    dataSources = @(@{
      id = $dataSourceId; name = $DatabaseName; scopeId = 'kusto-trident'; kind = 'kusto-trident'
      clusterUri = $QueryServiceUri; database = $DatabaseName; workspace = $WorkspaceId
    })
    pages = @(@{ id = $pageId; name = 'Monitoring and sample business impact' })
    autoRefresh = @{ enabled = $true; defaultInterval = '5m'; minInterval = '5m' }
  }
}

function Get-FabricApiCollection {
  param([Parameter(Mandatory)] [string] $Path)
  $next = "$fabricApi/$Path"
  $visited = [Collections.Generic.HashSet[string]]::new()
  while ($next) {
    if (-not $visited.Add($next)) { throw 'Fabric returned a repeated continuation URL.' }
    $uri = [uri]$next
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.fabric.microsoft.com') { throw 'Unexpected Fabric continuation URL.' }
    $response = Invoke-RestMethod -Method Get -Uri $next -Headers $script:fabricHeaders
    $response.value
    if ($response.continuationToken -and -not $response.continuationUri) {
      throw 'Fabric returned a continuation token without a continuation URI.'
    }
    $next = $response.continuationUri
  }
}

function Get-FabricSelectableScope {
  param([object[]] $Nodes)
  foreach ($node in $Nodes) {
    if ($node.isSelectable -eq 'Selectable') { $node }
    if ($node.children) { Get-FabricSelectableScope -Nodes $node.children }
  }
}

function Initialize-FabricMirror {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $CentralWorkspaceId,
    [string] $ConnectionId = '',
    [string[]] $Scope = @(),
    [string[]] $Tables = @('AzureActivity', 'ContainerLogV2', 'AppServiceHTTPLogs', 'Perf')
  )
  if (-not $Tables.Count -or @($Tables | Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9_]*$' }).Count) {
    throw 'Mirroring requires an explicit nonempty list of table names.'
  }
  $connections = @(Get-FabricApiCollection -Path connections)
  if ($ConnectionId) {
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($ConnectionId, [ref]$parsedId)) { throw 'MirrorConnectionId must be a Fabric connection GUID.' }
    $connection = @($connections | Where-Object id -eq $ConnectionId)
    if ($connection.Count -ne 1) { throw 'The configured mirror connection is not accessible to the signed-in user.' }
  } else {
    $connection = @($connections | Where-Object {
      $_.connectionDetails.type -match 'AzureMonitor|LogAnalytics' -and
      $_.connectionDetails.path -and
      $_.connectionDetails.path.IndexOf($CentralWorkspaceId, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($connection.Count -ne 1) {
      return [pscustomobject]@{
        Feature = 'Azure Monitor mirroring'; Status = 'ActionRequired'
        Detail = 'Create/authorize one Azure Monitor connection to central Log Analytics in Fabric, set fabricAutomation.mirrorConnectionId and rerun. Preview tenant enablement and source RBAC remain administrator actions.'
      }
    }
  }
  $connectionIdValue = $connection[0].id
  $discoveryPath = "workspaces/$WorkspaceId/catalogmirroring"
  $scopes = @(Get-FabricSelectableScope -Nodes @(Get-FabricApiCollection -Path "$discoveryPath/scopes?beta=true&connectionId=$connectionIdValue&recursive=true"))
  if ($Scope.Count) {
    $selected = @($scopes | Where-Object { (ConvertTo-Json -InputObject @($_.fullyQualifiedScope) -Compress) -ceq (ConvertTo-Json -InputObject $Scope -Compress) })
  } else {
    $selected = $scopes
  }
  if ($selected.Count -ne 1) {
    return [pscustomobject]@{
      Feature = 'Azure Monitor mirroring'; Status = 'ActionRequired'
      Detail = 'Mirror connection has no unique selectable scope. Set fabricAutomation.mirrorScope to the exact fullyQualifiedScope array returned by Fabric catalogmirroring/scopes, then rerun.'
    }
  }
  $scopeQuery = (@($selected[0].fullyQualifiedScope | ForEach-Object { 'scope=' + [uri]::EscapeDataString($_) }) -join '&')
  $tablePath = "$discoveryPath/tables?beta=true&connectionId=$connectionIdValue"
  if ($scopeQuery) { $tablePath += "&$scopeQuery" }
  $available = @(Get-FabricApiCollection -Path $tablePath)
  $mounts = @()
  foreach ($tableName in $Tables) {
    $match = @($available | Where-Object name -ceq $tableName)
    if ($match.Count -ne 1) {
      return [pscustomobject]@{
        Feature = 'Azure Monitor mirroring'; Status = 'ActionRequired'
        Detail = "Requested table '$tableName' is absent or ambiguous in the selected source. Enable its collection or explicitly adjust mirrorTables; no broader table selection was applied."
      }
    }
    $mounts += @{ source = @{ typeProperties = @{ fullyQualifiedScope = @($match[0].fullyQualifiedScope); tableName = $tableName } } }
  }
  $definition = @{
    '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/mirroredCatalog/definition/mirroredCatalogDefinition/1.0.0/schema.json'
    properties = @{
      source = @{ type = 'AzureMonitorMirroredCatalog'; typeProperties = @{ connectionId = $connectionIdValue; scope = @($selected[0].fullyQualifiedScope) } }
      mountedTables = $mounts
    }
  }
  $mirror = Ensure-FabricItem -CollectionPath "workspaces/$WorkspaceId/mirroredCatalogs" `
    -DisplayName 'Azure Monitor Demo Mirrored Logs' -CreateBody @{
      displayName = 'Azure Monitor Demo Mirrored Logs'
      description = 'Read-only OneLake shortcuts to explicitly selected central Log Analytics tables. No data copy.'
      definition = @{ parts = @(@{
        path = 'MirroredCatalogDefinition.json'
        payload = ConvertTo-InlineBase64 -Value ($definition | ConvertTo-Json -Depth 15)
        payloadType = 'InlineBase64'
      }) }
    }
  $status = Invoke-RestMethod -Method Get `
    -Uri "$fabricApi/workspaces/$WorkspaceId/mirroredCatalogs/$($mirror.id)/mirroringStatus?beta=true" -Headers $script:fabricHeaders
  if ($status.status -eq 'Failed') { throw "Mirroring failed: $($status.error | ConvertTo-Json -Depth 6 -Compress)" }
  if ($status.status -notin @('Running', 'Stopped')) { throw "Unexpected mirroring status '$($status.status)'." }
  return [pscustomobject]@{
    Feature = 'Azure Monitor mirroring'; Status = 'Pending'
    Detail = "Mirrored item $($mirror.id): $($status.status). Allow about 15 minutes, then verify table data. Existing items are reused without overwriting their table selection."
  }
}
