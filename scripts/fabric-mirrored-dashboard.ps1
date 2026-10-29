function New-FabricMirroredDashboardDefinition {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $QueryServiceUri,
    [Parameter(Mandatory)] [guid] $DatabaseId,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string[]] $Tables,
    [switch] $ApplicationInsights
  )
  if (-not $Tables.Count -or @($Tables | Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9_]*$' }).Count) {
    throw 'Mirrored dashboard requires an explicit list of valid table names.'
  }
  $definition = New-FabricDashboardDefinition -WorkspaceId $WorkspaceId -QueryServiceUri $QueryServiceUri `
    -DatabaseId $DatabaseId -DatabaseName $DatabaseName -TableName Unused -IncludeSampleData:$false
  $definition.title = "Azure Monitor Mirrored Logs - $DatabaseName"
  $definition.pages[0].name = 'Mirrored Log Analytics'
  $tiles = [Collections.Generic.List[object]]::new()
  function Add-MirrorTile {
    param([string] $Title, [string] $Query, [string] $Visual, [int] $X, [int] $Y, [int] $Width = 12, [int] $Height = 7)
    $options = @{}
    if ($Visual -eq 'multistat') {
      $options = @{
        multiStat__labelColumn = 'Metric'; multiStat__valueColumn = 'Value'
        multiStat__textSize = 'auto'; multiStat__displayOrientation = 'horizontal'
        multiStat__slot = @{ width = 1; height = 1 }
      }
    }
    $tiles.Add(@{
      id = [guid]::NewGuid().ToString(); title = $Title; query = $Query
      visualType = $Visual; visualOptions = $options
      pageId = $definition.pages[0].id; dataSourceId = $definition.dataSources[0].id
      usedParamVariables = @(); layout = @{ x = $X; y = $Y; width = $Width; height = $Height }
    })
  }
  $union = 'union ' + (($Tables | ForEach-Object { "(external_table('$_') | extend SourceTable='$_')" }) -join ",`n")
  $visible = @"
let Visible = $union
| where TimeGenerated > ago(24h)
| extend SourceReceipt=todatetime(column_ifexists('_TimeReceived', datetime(null)))
| extend ReceiptDelaySec=datetime_diff('millisecond', SourceReceipt, TimeGenerated) / 1000.0;
"@
  if ($ApplicationInsights) {
    if (@('AppRequests', 'AppDependencies', 'AppExceptions', 'AppTraces' | Where-Object { $_ -notin $Tables }).Count) {
      throw 'Application Insights dashboard requires AppRequests, AppDependencies, AppExceptions and AppTraces in the mirror allowlist.'
    }
    $requests = @'
let Requests = external_table('AppRequests')
| where TimeGenerated > ago(24h)
| extend Weight=coalesce(tolong(ItemCount), long(1)), IsSuccess=tobool(Success), Status=toint(ResultCode),
    ReceiptDelaySec=datetime_diff('millisecond', _TimeReceived, TimeGenerated) / 1000.0;
'@
    $dependencies = @'
let Dependencies = external_table('AppDependencies')
| where TimeGenerated > ago(24h)
| extend Weight=coalesce(tolong(ItemCount), long(1)), IsSuccess=tobool(Success);
'@
    $exceptions = @'
let Exceptions = external_table('AppExceptions')
| where TimeGenerated > ago(24h)
| extend Weight=coalesce(tolong(ItemCount), long(1));
'@
    $cards = @(
      @('Requests | 24h, sampling-adjusted', ($requests + "`nRequests | summarize Value=toreal(sum(Weight))")),
      @('Server error rate | %', ($requests + "`nRequests | summarize Total=sum(Weight), Errors=sumif(Weight, Status >= 500) | project Value=round(100.0 * Errors / Total, 2)")),
      @('Request latency | P95 ms', ($requests + "`nRequests | summarize Value=percentilew(DurationMs, Weight, 95)")),
      @('Exceptions | 24h, sampling-adjusted', ($exceptions + "`nExceptions | summarize Value=toreal(sum(Weight))")),
      @('Source receipt delay | P95 seconds', ($requests + "`nRequests | where ReceiptDelaySec >= 0 | summarize Value=round(percentile(ReceiptDelaySec, 95), 2)")),
      @('Latest request event age | minutes', ($requests + "`nRequests | summarize LatestEvent=max(TimeGenerated) | project Value=round(datetime_diff('second', now(), LatestEvent) / 60.0, 1)"))
    )
  } else {
    $cards = @(
      @('Visible records | 24h, not sampling-adjusted', ($visible + "`nVisible | summarize Value=toreal(count())")),
      @('Visible source tables | 24h', ($visible + "`nVisible | summarize Value=toreal(dcount(SourceTable))")),
      @('Latest event age | minutes', ($visible + "`nVisible | summarize LatestEvent=max(TimeGenerated) | project Value=round(datetime_diff('second', now(), LatestEvent) / 60.0, 1)")),
      @('Source receipt delay | P95 seconds', ($visible + "`nVisible | where ReceiptDelaySec >= 0 | summarize Value=round(percentile(ReceiptDelaySec, 95), 2)")),
      @('Records missing source receipt | 24h', ($visible + "`nVisible | summarize Value=toreal(countif(isnull(ReceiptDelaySec)))")),
      @('Negative source receipt intervals | 24h', ($visible + "`nVisible | summarize Value=toreal(countif(ReceiptDelaySec < 0))"))
    )
  }
  for ($i = 0; $i -lt $cards.Count; $i++) {
    $title = $cards[$i][0]
    $query = $cards[$i][1] + "`n| project Metric='$title', Value=toreal(Value)"
    Add-MirrorTile $title $query multistat (($i % 2) * 12) ([int][Math]::Floor($i / 2) * 7)
  }
  if ($ApplicationInsights) {
    Add-MirrorTile 'Traffic and server errors | event time, 15m' ($requests + @'

Requests | summarize Requests=sum(Weight), ServerErrors=sumif(Weight, Status >= 500) by bin(TimeGenerated, 15m) | order by TimeGenerated asc
'@) line 0 21
    Add-MirrorTile 'Request latency | sampling-weighted P50 / P95 / P99 ms' ($requests + @'

Requests | summarize P50Ms=percentilew(DurationMs, Weight, 50), P95Ms=percentilew(DurationMs, Weight, 95), P99Ms=percentilew(DurationMs, Weight, 99) by bin(TimeGenerated, 15m) | order by TimeGenerated asc
'@) line 12 21
    Add-MirrorTile 'Source receipt delay | seconds, not Fabric mirror latency' ($requests + @'

Requests | where ReceiptDelaySec >= 0 | summarize P50Seconds=percentile(ReceiptDelaySec, 50), P95Seconds=percentile(ReceiptDelaySec, 95) by bin(TimeGenerated, 15m) | order by TimeGenerated asc
'@) line 0 28
    Add-MirrorTile 'Dependency calls and failures | event time, 15m' ($dependencies + @'

Dependencies | summarize Calls=sum(Weight), Failures=sumif(Weight, IsSuccess == false) by bin(TimeGenerated, 15m) | order by TimeGenerated asc
'@) line 12 28
    Add-MirrorTile 'Endpoint reliability | top 12 by failed requests' ($requests + @'

Requests
| summarize Requests=sum(Weight), Failed=sumif(Weight, IsSuccess == false), ServerErrors=sumif(Weight, Status >= 500),
    P95Ms=percentilew(DurationMs, Weight, 95), LastSeen=max(TimeGenerated) by Application=AppRoleName, Endpoint=Name
| extend FailurePct=round(100.0 * Failed / Requests, 2), P95Ms=round(P95Ms, 1)
| top 12 by Failed desc
| project Application, Endpoint, Requests, Failed, FailurePct, ServerErrors, P95Ms, LastSeen
'@) table 0 35 24 8
    Add-MirrorTile 'Exception hotspots | top 10' ($exceptions + @'

Exceptions
| summarize Exceptions=sum(Weight), LastSeen=max(TimeGenerated), Example=take_any(substring(OuterMessage, 0, 200)) by Application=AppRoleName, ExceptionType
| top 10 by Exceptions desc
| project Application, ExceptionType, Exceptions, LastSeen, Example
'@) table 0 43 12 8
    Add-MirrorTile 'Dependency health | top 10 by failures' ($dependencies + @'

Dependencies
| summarize Calls=sum(Weight), Failed=sumif(Weight, IsSuccess == false), P95Ms=percentilew(DurationMs, Weight, 95) by DependencyType, Target
| extend FailurePct=round(100.0 * Failed / Calls, 2), P95Ms=round(P95Ms, 1)
| top 10 by Failed desc
| project DependencyType, Target, Calls, Failed, FailurePct, P95Ms
'@) table 12 43 12 8
    $freshnessY = 51
  } else {
    Add-MirrorTile 'Visible records by source | event time, 15m' ($visible + "`nVisible | summarize Records=count() by SourceTable, bin(TimeGenerated, 15m) | order by TimeGenerated asc") line 0 21
    Add-MirrorTile 'Source receipt delay | P95 seconds, not mirror latency' ($visible + "`nVisible | where ReceiptDelaySec >= 0 | summarize P95Seconds=percentile(ReceiptDelaySec, 95) by SourceTable, bin(TimeGenerated, 15m) | order by TimeGenerated asc") line 12 21
    Add-MirrorTile 'Recent mirrored telemetry | observed records' ($visible + @'

Visible
| project TimeGenerated, SourceTable,
    Computer=tostring(column_ifexists('Computer', '')),
    Category=tostring(column_ifexists('Category', '')),
    Operation=tostring(column_ifexists('OperationNameValue', '')),
    Message=coalesce(tostring(column_ifexists('LogMessage', '')), tostring(column_ifexists('Message', ''))),
    Counter=tostring(column_ifexists('CounterName', '')), Value=toreal(column_ifexists('CounterValue', real(null)))
| top 25 by TimeGenerated desc
'@) table 0 28 24 8
    $freshnessY = 36
  }
  Add-MirrorTile 'Mirror visibility and source receipt | event age is not mirror latency' ($visible + @'

Visible
| summarize VisibleRecords=count(), LatestEvent=max(TimeGenerated), LatestSourceReceipt=max(SourceReceipt),
    MissingReceipt=countif(isnull(ReceiptDelaySec)), NegativeReceipt=countif(ReceiptDelaySec < 0),
    P95SourceReceiptSec=percentile(iff(ReceiptDelaySec >= 0, ReceiptDelaySec, real(null)), 95) by SourceTable
| extend EventAgeMin=round(datetime_diff('second', now(), LatestEvent) / 60.0, 1), P95SourceReceiptSec=round(P95SourceReceiptSec, 2)
| project SourceTable, VisibleRecords, LatestEvent, EventAgeMin, LatestSourceReceipt, P95SourceReceiptSec, MissingReceipt, NegativeReceipt
| order by SourceTable asc
'@) table 0 $freshnessY 24 8
  $definition.tiles = $tiles.ToArray()
  return $definition
}

function Initialize-FabricMirroredDashboard {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] $Mirror,
    [switch] $ApplicationInsights,
    [ValidateRange(1, 1800)] [int] $TimeoutSeconds = 900
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $databases = @(Get-FabricApiCollection -Path "workspaces/$WorkspaceId/kqlDatabases" | Where-Object displayName -eq $Mirror.DisplayName)
    if ($databases.Count -or [DateTime]::UtcNow.AddSeconds(15) -ge $deadline) { break }
    Write-Info "Waiting for the mirror Eventhouse endpoint '$($Mirror.DisplayName)'..."
    Start-Sleep -Seconds 15
  } while ([DateTime]::UtcNow -lt $deadline)
  if (-not $databases.Count) {
    return [pscustomobject]@{
      Feature = "Mirrored dashboard ($($Mirror.DisplayName))"; Status = 'Pending'
      Detail = 'The automatically provisioned mirror Eventhouse endpoint is not visible yet. Allow initial provisioning, then rerun setup; no unrelated database was used.'
    }
  }
  if ($databases.Count -ne 1) { throw 'Mirror endpoint database name is ambiguous; refusing to bind an unrelated database.' }
  $database = Invoke-RestMethod -Method Get -Uri "$fabricApi/workspaces/$WorkspaceId/kqlDatabases/$($databases[0].id)" -Headers $script:fabricHeaders
  $definition = New-FabricMirroredDashboardDefinition -WorkspaceId $WorkspaceId -QueryServiceUri $database.properties.queryServiceUri `
    -DatabaseId $database.id -DatabaseName $Mirror.DisplayName -Tables $Mirror.Tables -ApplicationInsights:$ApplicationInsights
  $definition.title = 'Azure Monitor Mirrored Logs - ' + $(if ($ApplicationInsights) { 'Application Insights' } else { 'Central' })
  $dashboard = Ensure-FabricItem -CollectionPath "workspaces/$WorkspaceId/kqlDashboards" -DisplayName $definition.title -CreateBody @{
    displayName = $definition.title
    description = 'Mirrored Log Analytics charts, tables and KPIs. Source receipt delay and event age are not Fabric mirroring latency.'
    definition = @{ parts = @(@{
      path = 'RealTimeDashboard.json'; payloadType = 'InlineBase64'
      payload = ConvertTo-InlineBase64 -Value ($definition | ConvertTo-Json -Depth 20)
    }) }
  }
  $saved = New-FabricItem -Path "workspaces/$WorkspaceId/kqlDashboards/$($dashboard.id)/getDefinition" -Body @{}
  $part = @($saved.definition.parts | Where-Object path -eq 'RealTimeDashboard.json')
  if ($part.Count -ne 1) { throw 'Saved mirrored dashboard definition is unavailable.' }
  $savedDefinition = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part[0].payload)) | ConvertFrom-Json
  if (@($savedDefinition.dataSources).Count -ne 1 -or $savedDefinition.dataSources[0].database -ne $database.id -or
      $savedDefinition.dataSources[0].clusterUri -ne $database.properties.queryServiceUri -or
      $savedDefinition.dataSources[0].workspace -ne $WorkspaceId) {
    throw 'Existing dashboard data source differs from the mirror endpoint. Its edits were preserved; repair the binding or rename it before rerunning.'
  }
  foreach ($tile in $savedDefinition.tiles) {
    if ($tile.visualType -cnotin @('multistat', 'line', 'table') -or $tile.layout.width -lt 9 -or $tile.layout.height -lt 7 -or
        $tile.layout.x -lt 0 -or $tile.layout.y -lt 0 -or $tile.layout.x + $tile.layout.width -gt 24 -or
        $tile.dataSourceId -ne $savedDefinition.dataSources[0].id) {
      throw "Saved tile '$($tile.title)' has an unsupported visual, size or data-source binding. Its edits were preserved; repair or rename the existing dashboard."
    }
  }
  do {
    $external = Invoke-FabricKql -QueryServiceUri $database.properties.queryServiceUri -DatabaseName $database.id -Query '.show external tables' -Management
    $tableNames = @(foreach ($table in $external.Tables) {
      $index = [Array]::IndexOf(@($table.Columns.ColumnName), 'TableName')
      if ($index -ge 0) { foreach ($row in $table.Rows) { $row[$index] } }
    })
    $missing = @($Mirror.Tables | Where-Object { $_ -notin $tableNames })
    if (-not $missing.Count -or [DateTime]::UtcNow.AddSeconds(15) -ge $deadline) { break }
    Write-Info "Waiting for mirrored external tables: $($missing -join ', ')..."
    Start-Sleep -Seconds 15
  } while ([DateTime]::UtcNow -lt $deadline)
  if ($missing.Count) {
    return [pscustomobject]@{
      Feature = "Mirrored dashboard ($($Mirror.DisplayName))"; Status = 'Pending'
      Detail = "Dashboard $($dashboard.id) configured. External tables still provisioning: $($missing -join ', '). Allow about 15 minutes; new data only, no historical backfill."
    }
  }
  foreach ($tile in $savedDefinition.tiles) {
    $result = Invoke-FabricKql -QueryServiceUri $database.properties.queryServiceUri -DatabaseName $database.id -Query $tile.query
    if ($tile.visualType -eq 'multistat') {
      $primary = @($result.Tables | Where-Object { $_.TableName -eq 'Table_0' })
      if ($primary.Count -ne 1 -or $primary[0].Rows.Count -ne 1 -or
          ($primary[0].Columns.ColumnName -join ',') -cne 'Metric,Value') {
        throw "Numeric tile '$($tile.title)' did not return exactly one Metric/Value row."
      }
    }
  }
  $union = 'union ' + (($Mirror.Tables | ForEach-Object { "external_table('$_')" }) -join ', ')
  $rows = Invoke-FabricKql -QueryServiceUri $database.properties.queryServiceUri -DatabaseName $database.id `
    -Query "$union | where TimeGenerated > ago(24h) | count"
  $count = [long](Get-FabricKqlScalar -Response $rows -ColumnName Count)
  return [pscustomobject]@{
    Feature = "Mirrored dashboard ($($Mirror.DisplayName))"
    Status = $(if ($count -gt 0) { 'Verified' } else { 'Pending' })
    Detail = "https://app.fabric.microsoft.com/groups/$WorkspaceId/kqlDashboards/$($dashboard.id) : saved queries executed; $count visible records in 24h. Not browser-rendering or end-to-end latency verification."
  }
}
