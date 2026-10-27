$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $source 'scripts/fabric-observability.ps1')
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'scripts/setup-fabric.ps1'), [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Fabric setup does not parse.' }
foreach ($name in @('Get-CollectionItem', 'Ensure-FabricItem', 'New-FabricItem', 'ConvertTo-InlineBase64')) {
  $definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
  })[0]
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Info($Message) {}
$fabricApi = 'https://api.fabric.microsoft.com/v1'
$script:fabricHeaders = @{ Authorization = 'Bearer offline-fabric-test' }
$connectionId = 'c65e7960-71e7-4e31-bacb-d379595fb3f0'
$endpoint = 'https://test.kusto.fabric.microsoft.com'
$fixture = @{}

function New-Table($Columns, $Rows, $Name = 'Table_0') {
  return @{ TableName = $Name; Columns = @($Columns | ForEach-Object { @{ ColumnName = $_ } }); Rows = $Rows }
}
function Reset-Fixture {
  $fixture.Requests = [Collections.Generic.List[object]]::new()
  $fixture.Topology = @{ sources = @(@{ name = 'source'; status = 'Running' }); destinations = @(@{ name = 'destination'; status = 'Running' }) }
  $fixture.TableExists = $true
  $fixture.LiveCount = 3
  $fixture.Samples = @{}
  $fixture.KqlError = $null
  $fixture.PartialFailure = $false
  $fixture.Dashboard = $null
  $fixture.Mirror = $null
  $fixture.Connections = @(@{ id = $connectionId; connectionDetails = @{ type = 'AzureMonitor'; path = '/central-law' } })
  $fixture.Scopes = @(@{ name = 'central'; fullyQualifiedScope = @('central'); isSelectable = 'Selectable' })
  $fixture.Tables = @('AzureActivity', 'Perf' | ForEach-Object { @{ name = $_; fullyQualifiedScope = @('central', 'logs') } })
  $fixture.MirrorStatus = 'Running'
  $fixture.Delays = 0
  $fixture.TokenFailure = $false
  $fixture.HttpFailure = $false
  $fixture.FullSetup = $false
  $fixture.CapacityState = 'Active'
  $fixture.DeletedWorkspace = $false
  $fixture.Continuation = $null
  $fixture.MoreConnections = @()
}
function az {
  if ($fixture.FullSetup) {
    $global:LASTEXITCODE = 0
    switch ($args[0..1] -join ' ') {
      'account set' { return }
      'account show' {
        if ($args -contains 'id') { return '00000000-0000-0000-0000-000000000000' }
        return '{"id":"00000000-0000-0000-0000-000000000000","tenantId":"00000000-0000-0000-0000-000000000000","userName":"operator@example.com","userType":"user"}'
      }
      'account get-access-token' {
        if ($args -contains 'https://api.fabric.microsoft.com') { return 'offline-fabric-test' }
      }
      'resource show' { return ConvertTo-Json @{ state = $fixture.CapacityState; administrators = @('operator@example.com') } }
      'resource list' {
        if ($args -contains 'Microsoft.Fabric/capacities') {
          if ($args -contains '[0].{id:id,name:name,location:location,sku:sku.name}') {
            return '{"id":"/capacity","name":"testcapacity","location":"swedencentral","sku":"F2"}'
          }
          return '[{"name":"testcapacity","location":"swedencentral","sku":{"name":"F2"}}]'
        }
        if ($args -contains 'Microsoft.Logic/workflows') { return '[]' }
        if ($args -contains 'Microsoft.EventHub/namespaces') { return 'testhub' }
        if ($args -contains 'Microsoft.OperationalInsights/workspaces') { return '[{"id":"/central-law","name":"law-amlab-central-test"}]' }
      }
    }
  }
  if (($args -join ' ') -notlike 'account get-access-token --resource https://api.kusto.windows.net*') { throw 'Unexpected Azure CLI call.' }
  $global:LASTEXITCODE = $(if ($fixture.TokenFailure) { 1 } else { 0 })
  if (-not $fixture.TokenFailure) { 'offline-kusto-test' }
}
function Start-Sleep { param($Seconds); $fixture.Delays++ }
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body, $ResponseHeadersVariable, $StatusCodeVariable)
  $fixture.Requests.Add(@{ Method = $Method; Uri = $Uri; Body = $Body })
  if ($fixture.HttpFailure) { throw 'HTTP 403 access denied.' }
  if ($Uri -like 'https://test.kusto.fabric.microsoft.com/v1/rest/*') {
    if ($Headers.Authorization -ne 'Bearer offline-kusto-test') { throw 'Wrong Kusto audience/token.' }
    if ($fixture.KqlError) { return @{ error = @{ message = $fixture.KqlError } } }
    if ($fixture.PartialFailure) {
      return @{ Tables = @((New-Table @('Count') @(,@(5))), (New-Table @('Severity', 'StatusDescription') @(,@(2, 'partial failure')) QueryStatus)) }
    }
    $query = ($Body | ConvertFrom-Json).csl
    if ($query -eq '.show tables') {
      $rows = @()
      if ($fixture.TableExists) { $rows = @(,@('AzureDiagnosticsRaw')) }
      return @{ Tables = @((New-Table @('TableName') $rows)) }
    }
    if ($query -like '.create-merge table LabSampleEvents*') { return @{ Tables = @() } }
    if ($query -like '.set-or-append LabSampleEvents*') {
      if ($query -notmatch 'where SampleId !in' -or $query -notmatch 'IsSynthetic = true') { throw 'Samples must be labelled and deduplicated.' }
      foreach ($match in [regex]::Matches($query, "'(amlab-synthetic-v1-[^']+)'")) { $fixture.Samples[$match.Groups[1].Value] = $true }
      return @{ Tables = @() }
    }
    if ($query -like 'LabSampleEvents*') { return @{ Tables = @((New-Table @('Samples') @(,@($fixture.Samples.Count)))) } }
    if ($query -like 'AzureDiagnosticsRaw*ago(15m)*') { return @{ Tables = @((New-Table @('Count') @(,@($fixture.LiveCount)))) } }
    throw "Unexpected KQL: $query"
  }
  if ($Headers.Authorization -ne $script:fabricHeaders.Authorization) { throw 'Wrong Fabric token.' }
  if ($Method -eq 'Get') {
    if ($fixture.FullSetup) {
      switch ($Uri) {
        "$fabricApi/capacities" { return @{ value = @(@{ id = 'capacity'; displayName = 'testcapacity' }) } }
        "$fabricApi/workspaces" { return @{ value = @(@{ id = 'workspace'; displayName = 'Azure Monitor Demo Lab' }) } }
        "$fabricApi/workspaces/workspace/eventhouses" { return @{ value = @(@{ id = 'eventhouse'; displayName = 'Azure Monitor Demo Eventhouse' }) } }
        "$fabricApi/workspaces/workspace/kqlDatabases" { return @{ value = @(@{ id = 'database'; displayName = 'MonitoringTelemetry' }) } }
        "$fabricApi/workspaces/workspace/eventstreams" { return @{ value = @(@{ id = 'stream'; displayName = 'AzureMonitorEvents' }) } }
        "$fabricApi/workspaces/workspace/kqlDatabases/database" { return @{ properties = @{ queryServiceUri = 'https://test.kusto.fabric.microsoft.com' } } }
      }
    }
    switch -Wildcard ($Uri) {
      '*/eventstreams/*/topology' { return $fixture.Topology }
      '*/connections' { return @{ value = $fixture.Connections; continuationUri = $fixture.Continuation } }
      '*/connections?page=2' { return @{ value = $fixture.MoreConnections } }
      '*/catalogmirroring/scopes?*' { return @{ value = $fixture.Scopes } }
      '*/catalogmirroring/tables?*' { return @{ value = $fixture.Tables } }
      '*/kqlDashboards' { return @{ value = @($(if ($fixture.Dashboard) { $fixture.Dashboard })) } }
      '*/mirroredCatalogs' { return @{ value = @($(if ($fixture.Mirror) { $fixture.Mirror })) } }
      '*/mirroringStatus?beta=true' { return @{ status = $fixture.MirrorStatus; error = @{ message = 'source access failed' } } }
    }
  }
  if ($Method -eq 'Delete' -and $Uri -eq "$fabricApi/workspaces/workspace") {
    $fixture.DeletedWorkspace = $true
    return
  }
  if ($Method -eq 'Post' -and ($Uri -like '*/kqlDashboards' -or $Uri -like '*/mirroredCatalogs')) {
    if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value 201 -Scope 1 }
    $request = $Body | ConvertFrom-Json
    $item = @{ id = [guid]::NewGuid().ToString(); displayName = $request.displayName }
    if ($Uri -like '*/kqlDashboards') { $fixture.Dashboard = $item } else { $fixture.Mirror = $item }
    return $item
  }
  throw "Unexpected REST call: $Method $Uri"
}
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}
function Test-Telemetry {
  Wait-FabricTelemetry -WorkspaceId workspace -EventstreamId stream -QueryServiceUri $endpoint `
    -DatabaseName MonitoringTelemetry -TableName AzureDiagnosticsRaw -TimeoutSeconds 1
}
function Test-Mirror {
  Initialize-FabricMirror -WorkspaceId workspace -CentralWorkspaceId '/central-law' -Tables AzureActivity, Perf
}

Reset-Fixture
if ((Test-Telemetry).Status -ne 'Verified') { throw 'Recent live rows must verify ingestion.' }
foreach ($tableExists in @($true, $false)) {
  Reset-Fixture
  $fixture.TableExists = $tableExists
  $fixture.LiveCount = 0
  if ((Test-Telemetry).Status -ne 'Pending') { throw 'Missing tables/empty telemetry must never report success.' }
}
Reset-Fixture
$fixture.Topology.sources[0].status = 'Failed'
Assert-Failure { Test-Telemetry } '*data flow failed*'
Reset-Fixture
$fixture.Topology.destinations = @()
Assert-Failure { Test-Telemetry } '*missing its source or destination*'
Reset-Fixture
$fixture.KqlError = 'query denied'
Assert-Failure { Test-Telemetry } '*query denied*'
Reset-Fixture
$fixture.PartialFailure = $true
Assert-Failure { Test-Telemetry } '*partial failure*'
Reset-Fixture
$fixture.TokenFailure = $true
Assert-Failure { Test-Telemetry } '*Kusto API token*'
Reset-Fixture
$fixture.HttpFailure = $true
Assert-Failure { Test-Telemetry } '*403*'
Assert-Failure { Invoke-FabricKql -QueryServiceUri 'https://untrusted.example' -DatabaseName db -Query 'print 1' } '*unexpected KQL*'
Assert-Failure { Get-FabricKqlScalar -Response @{ Tables = @() } -ColumnName Count } '*missing scalar*'
Write-Output 'PASS: live ingestion verification distinguishes healthy, empty, absent, failed, denied and partial-failure results.'

Reset-Fixture
1..2 | ForEach-Object { Initialize-FabricSampleData -QueryServiceUri $endpoint -DatabaseName MonitoringTelemetry }
if ($fixture.Samples.Count -ne 4) { throw 'Sample reruns must not duplicate events.' }
$dashboard = New-FabricDashboardDefinition -WorkspaceId '11111111-1111-1111-1111-111111111111' `
  -QueryServiceUri $endpoint -DatabaseName MonitoringTelemetry -TableName AzureDiagnosticsRaw
if ($dashboard.tiles.Count -ne 3 -or $dashboard.dataSources[0].kind -ne 'kusto-trident' -or
    $dashboard.dataSources[0].clusterUri -ne $endpoint -or $dashboard.tiles[2].query -notmatch 'join kind=inner' -or
    $dashboard.tiles[2].title -notmatch 'SYNTHETIC' -or $dashboard.tiles[2].query -notmatch 'IsSynthetic == true') {
  throw 'Dashboard must bind live telemetry and explicitly labelled synthetic correlation to the KQL database.'
}
foreach ($tile in $dashboard.tiles) {
  if (-not $tile.query -or $tile.dataSourceId -ne $dashboard.dataSources[0].id -or $tile.pageId -ne $dashboard.pages[0].id -or $null -eq $tile.visualOptions) {
    throw 'All dashboard tiles require queries, valid data-source/page references and visual options.'
  }
}
$noSampleDashboard = New-FabricDashboardDefinition -WorkspaceId workspace -QueryServiceUri $endpoint `
  -DatabaseName db -TableName AzureDiagnosticsRaw -IncludeSampleData:$false
if ($noSampleDashboard.tiles.Count -ne 2 -or ($noSampleDashboard | ConvertTo-Json -Depth 15) -match 'LabSampleEvents') { throw 'Sample opt-out must remove sample-dependent tiles.' }
$body = @{ displayName = $dashboard.title; definition = @{ parts = @(@{
  path = 'RealTimeDashboard.json'; payloadType = 'InlineBase64'
  payload = ConvertTo-InlineBase64 ($dashboard | ConvertTo-Json -Depth 15)
}) } }
1..2 | ForEach-Object { Ensure-FabricItem -CollectionPath workspaces/workspace/kqlDashboards -DisplayName $dashboard.title -CreateBody $body | Out-Null }
if (@($fixture.Requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*/kqlDashboards' }).Count -ne 1) { throw 'Dashboard reruns must reuse the item without overwriting user edits.' }
Write-Output 'PASS: synthetic sample deduplication, correlation joins, sample opt-out and idempotent dashboard creation.'

Reset-Fixture
1..2 | ForEach-Object { if ((Test-Mirror).Status -ne 'Pending') { throw 'Created mirror is not proof of data availability.' } }
$mirrorPosts = @($fixture.Requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*/mirroredCatalogs' })
if ($mirrorPosts.Count -ne 1) { throw 'Mirror reruns must not duplicate or overwrite items.' }
$part = ($mirrorPosts[0].Body | ConvertFrom-Json).definition.parts[0]
$definition = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
if ($part.path -ne 'MirroredCatalogDefinition.json' -or
    $definition.properties.source.type -ne 'AzureMonitorMirroredCatalog' -or
    $definition.properties.mountedTables.Count -ne 2 -or
    ($definition.properties.mountedTables.source.typeProperties.tableName -join ',') -ne 'AzureActivity,Perf') {
  throw 'Mirror must mount only the explicitly requested tables using the documented source type.'
}
Reset-Fixture
$fixture.Tables = @()
if ((Test-Mirror).Status -ne 'ActionRequired' -or $fixture.Mirror) { throw 'Missing source tables must not widen mirroring to all tables.' }
Reset-Fixture
$fixture.Scopes += @{ fullyQualifiedScope = @('another'); isSelectable = 'Selectable' }
if ((Test-Mirror).Status -ne 'ActionRequired') { throw 'Ambiguous scopes must require explicit selection.' }
Reset-Fixture
$fixture.Connections = @()
if ((Test-Mirror).Status -ne 'ActionRequired') { throw 'Missing preauthorized connection must produce an actionable result.' }
Reset-Fixture
$fixture.MirrorStatus = 'Failed'
Assert-Failure { Test-Mirror } '*Mirroring failed*'
Reset-Fixture
$fixture.HttpFailure = $true
Assert-Failure { Test-Mirror } '*403*'
Reset-Fixture
$fixture.Continuation = "$fabricApi/connections?page=2"
$fixture.MoreConnections = @(@{ id = 'second-connection' })
if (@(Get-FabricApiCollection -Path connections).Count -ne 2) { throw 'Collection pagination must include all pages.' }
$fixture.Continuation = 'https://untrusted.example/connections'
Assert-Failure { Get-FabricApiCollection -Path connections } '*Unexpected Fabric continuation URL*'
$fixture.Continuation = "$fabricApi/connections"
Assert-Failure { Get-FabricApiCollection -Path connections } '*repeated continuation URL*'
Assert-Failure { Write-FabricSetupSummary -Results @([pscustomobject]@{ Feature = 'Test'; Status = 'Failed'; Detail = 'Test failure' }) } '*automation steps failed*'
Write-Output 'PASS: preview mirroring uses explicit mounts, reuses items and reports authorization/selection/status failures. No live calls.'

Reset-Fixture
$fixture.FullSetup = $true
& (Join-Path $source 'scripts/setup-fabric.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' `
  -ResourceGroup rg-fabric-test -WorkspaceName 'Azure Monitor Demo Lab' -SkipEventstreamConnection -EnableMirroring:$true -MirrorConnectionId $connectionId -MirrorTables AzureActivity, Perf `
  -VerificationTimeoutSeconds 1
if (-not $fixture.Dashboard -or -not $fixture.Mirror -or $fixture.Samples.Count -ne 4) {
  throw 'Full setup must wire dashboard, synthetic correlation and configured mirroring without manual helper calls.'
}
Write-Output 'PASS: full setup orchestrates supported experiences and explicitly reports incomplete live ingestion and manual Capacity Metrics installation.'

Reset-Fixture
$fixture.FullSetup = $true
$fixture.CapacityState = 'Suspended'
& (Join-Path $source 'scripts/setup-fabric.ps1') -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup rg-fabric-test -WorkspaceName 'Azure Monitor Demo Lab' -Teardown
if (-not $fixture.DeletedWorkspace -or $fixture.Dashboard -or $fixture.Samples.Count) {
  throw 'Teardown must delete tenant items even after scheduled capacity suspension, without creating any demo items.'
}
Write-Output 'PASS: suspended capacity does not prevent tenant-workspace teardown.'

$configBlock = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (Test-Path -LiteralPath $configPath)')
})[0]
function Test-WorkspaceConfig {
  $configPath = 'fixture.json'
  $Teardown = $true
  $WorkspaceName = 'default'
  $EnableAutoSuspend = $false
  function Test-Path { return $true }
  function Get-Content { return '{"fabricAutomation":{"workspaceName":"Isolated lab workspace","enableAutoSuspend":true}}' }
  . ([scriptblock]::Create($configBlock.Extent.Text))
  if ($WorkspaceName -ne 'Isolated lab workspace' -or $EnableAutoSuspend) {
    throw 'Teardown must honor the configured workspace without applying setup-only options.'
  }
}
Test-WorkspaceConfig
Write-Output 'PASS: configured workspace isolation is preserved during teardown.'
