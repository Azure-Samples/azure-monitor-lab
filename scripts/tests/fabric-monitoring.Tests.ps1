$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $source 'scripts/fabric-observability.ps1')
. (Join-Path $source 'scripts/fabric-monitoring.ps1')
$setupPath = Join-Path $source 'scripts/setup-fabric.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Fabric setup does not parse.' }
foreach ($name in @('Get-CollectionItem', 'Ensure-FabricItem', 'New-FabricItem', 'ConvertTo-InlineBase64')) {
  $definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
  })[0]
  . ([scriptblock]::Create($definition.Extent.Text))
}
function Write-Info($Message) {}
$fabricApi = 'https://api.fabric.microsoft.com/v1'
$script:fabricHeaders = @{ Authorization = 'offline-fabric-test' }
$workspaceId = '11111111-1111-1111-1111-111111111111'
$databaseId = '22222222-2222-2222-2222-222222222222'
$fixture = @{}

function Reset-Fixture {
  $fixture.Monitoring = @()
  $fixture.Agents = @()
  $fixture.Definitions = @{}
  $fixture.State = 'Disabled'
  $fixture.Requests = [Collections.Generic.List[object]]::new()
  $fixture.EnableCount = 0
  $fixture.Pending = $false
  $fixture.Forbidden = $false
  $fixture.TamperAgent = $false
}
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body, $StatusCodeVariable)
  $fixture.Requests.Add(@{ Method = $Method; Uri = $Uri; Body = $Body })
  if ($fixture.Forbidden) { throw 'HTTP 403 Forbidden.' }
  if ($Method -eq 'Get') {
    switch ($Uri) {
      "$fabricApi/workspaces/$workspaceId/monitoringItems" { return @{ value = $fixture.Monitoring } }
      "$fabricApi/workspaces/$workspaceId/operationsAgents" { return @{ value = $fixture.Agents } }
    }
    if ($Uri -match '/monitoringItems/[^/]+$') { return @{ properties = @{ dataCollectionState = $fixture.State } } }
  }
  if ($Method -eq 'Post') {
    if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value 200 -Scope 1 }
    if ($Uri -like '*/getDefinition') { return @{ definition = $fixture.Definitions[($Uri -split '/')[-2]] } }
    if ($Uri -like '*/enableDataCollection') {
      if ($Body) { throw 'Enable collection must not send a request body.' }
      $fixture.EnableCount++
      if (-not $fixture.Pending) { $fixture.State = 'Enabled' }
      return
    }
    if ($Uri -match '/(monitoringItems|operationsAgents)$') {
      if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value 201 -Scope 1 }
      $request = $Body | ConvertFrom-Json
      $item = @{ id = [guid]::NewGuid().ToString(); displayName = $request.displayName }
      $fixture.Definitions[$item.id] = $request.definition
      if ($Uri -like '*/monitoringItems') { $fixture.Monitoring += $item } else {
        $fixture.Agents += $item
        if ($fixture.TamperAgent) {
          $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($request.definition.parts[0].payload)) | ConvertFrom-Json
          $content.shouldRun = $true
          $request.definition.parts[0].payload = ConvertTo-InlineBase64 ($content | ConvertTo-Json -Depth 15)
        }
      }
      return $item
    }
  }
  throw "Unexpected REST call: $Method $Uri"
}
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}
function Test-Monitoring { Initialize-FabricWorkspaceMonitoring -WorkspaceId $workspaceId }
function Test-Agent {
  Initialize-FabricOperationsAgent -WorkspaceId $workspaceId -DatabaseId $databaseId -TableName AzureDiagnosticsRaw -Recipient operator@example.com
}
function Get-SavedContent($Item) {
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fixture.Definitions[$Item.id].parts[0].payload)) | ConvertFrom-Json
}
function Set-SavedContent($Item, $Content) {
  $fixture.Definitions[$Item.id].parts[0].payload = ConvertTo-InlineBase64 ($Content | ConvertTo-Json -Depth 15)
}

Reset-Fixture
if ((Test-Monitoring).Status -ne 'Configured' -or $fixture.EnableCount -ne 1) { throw 'Monitoring must configure and enable collection.' }
$saved = Get-SavedContent $fixture.Monitoring[0]
if ($fixture.Definitions[$fixture.Monitoring[0].id].format -ne 'MonitoringV1' -or
    $saved.dataCollectionSettings.Count -ne 1 -or
    $saved.dataCollectionSettings[0].sources.workspaceDiagnostics.mode -ne 'All' -or
    $saved.dataCollectionSettings[0].destinations.eventhouse.mode -ne 'Auto' -or
    $saved.operationsAgent) {
  throw 'Monitoring must use the documented Auto destination, without enabling its irreversible child agent.'
}
Test-Monitoring | Out-Null
if ($fixture.Monitoring.Count -ne 1 -or $fixture.EnableCount -ne 1) { throw 'Monitoring reruns must reuse the item and active collection.' }
$saved.dataCollectionSettings[0].destinations.eventhouse = @{ mode = 'Linked'; parentMonitoringItem = @{ itemId = $databaseId; workspaceId = $workspaceId } }
Set-SavedContent $fixture.Monitoring[0] $saved
Test-Monitoring | Out-Null
if ((Get-SavedContent $fixture.Monitoring[0]).dataCollectionSettings[0].destinations.eventhouse.mode -ne 'Linked') {
  throw 'Existing monitoring destinations must remain unchanged.'
}
$fixture.State = 'Unknown'
Assert-Failure { Test-Monitoring } '*unknown dataCollectionState*'
$fixture.State = 'Disabled'
$fixture.Pending = $true
if ((Test-Monitoring).Status -ne 'Pending' -or $fixture.EnableCount -ne 2) { throw 'Unconfirmed collection must stay Pending without repeated enable requests.' }
$saved.PSObject.Properties.Remove('dataCollectionSettings')
Set-SavedContent $fixture.Monitoring[0] $saved
if ((Test-Monitoring).Status -ne 'ActionRequired') { throw 'Unconfigured existing monitoring must not be overwritten.' }
$fixture.Monitoring += @{ id = 'second'; displayName = 'OtherMonitoring' }
if ((Test-Monitoring).Status -ne 'ActionRequired' -or $fixture.EnableCount -ne 2) { throw 'Ambiguous collection ownership must not be changed.' }
Write-Output 'PASS: monitoring definition, enable/readback, idempotency, linked routing, ambiguity and pending/unknown states.'

Reset-Fixture
$result = Test-Agent
$saved = Get-SavedContent $fixture.Agents[0]
if ($result.Status -ne 'ActionRequired' -or $saved.shouldRun -ne $false -or
    $fixture.Definitions[$fixture.Agents[0].id].parts[0].path -cne 'Configurations.json' -or
    $saved.configuration.dataSources.labTelemetry.id -ne $databaseId -or
    $saved.configuration.messageDestination.recipient -ne 'operator@example.com' -or
    $saved.configuration.goals -or $saved.configuration.recipient -or
    @($saved.configuration.actions.PSObject.Properties).Count -ne 0) {
  throw 'New agents must use the current definition, verified lab source and recipient, no remediation actions, and remain stopped.'
}
$saved.configuration.instructions = 'User-edited instructions'
$saved.shouldRun = $true
Set-SavedContent $fixture.Agents[0] $saved
Test-Agent | Out-Null
if ($fixture.Agents.Count -ne 1 -or (Get-SavedContent $fixture.Agents[0]).shouldRun -ne $true -or
    (Get-SavedContent $fixture.Agents[0]).configuration.instructions -ne 'User-edited instructions') {
  throw 'Agent reruns must preserve existing instructions and run state.'
}
$saved.configuration.dataSources.labTelemetry.id = $workspaceId
Set-SavedContent $fixture.Agents[0] $saved
if ((Test-Agent).Detail -notlike '*different data source*') { throw 'Conflicting agent sources require explicit review.' }
Reset-Fixture
$fixture.TamperAgent = $true
Assert-Failure { Test-Agent } '*saved configuration differs*'
Reset-Fixture
$fixture.Forbidden = $true
Assert-Failure { Test-Monitoring } '*403*'
Assert-Failure { Test-Agent } '*403*'
Reset-Fixture
Assert-Failure { Initialize-FabricOperationsAgent -WorkspaceId $workspaceId -DatabaseId $databaseId -TableName 'bad;query' -Recipient operator@example.com } '*KQL identifier*'
if ($fixture.Requests.Count) { throw 'Invalid table identifiers must fail before API calls.' }
Write-Output 'PASS: stopped agent definition/readback, safe reruns, source mismatch, rejected mutations and explicit authorization failures.'

$configBlock = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (Test-Path -LiteralPath $configPath)')
})[0]
function Test-Config {
  param([bool] $EnableWorkspaceMonitoring = $true, [bool] $EnableOperationsAgent = $true)
  $configPath = 'fixture.json'
  $Teardown = $false
  function Test-Path { return $true }
  function Get-Content { return '{"fabricAutomation":{"enableWorkspaceMonitoring":false,"enableOperationsAgent":false}}' }
  . ([scriptblock]::Create('param($explicitParameters); $PSBoundParameters = $explicitParameters; ' + $configBlock.Extent.Text)) $PSBoundParameters
  return @($EnableWorkspaceMonitoring, $EnableOperationsAgent)
}
if ((Test-Config) -contains $true -or (Test-Config -EnableWorkspaceMonitoring:$true -EnableOperationsAgent:$true) -contains $false) {
  throw 'Config opt-outs and explicit parameter precedence must both work.'
}
$wrapperErrors = $null
$wrapper = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'scripts/setup-fabric-cloud-shell.ps1'), [ref]$null, [ref]$wrapperErrors)
if ($wrapperErrors.Count) { throw 'Cloud Shell wrapper does not parse.' }
foreach ($name in @('EnableWorkspaceMonitoring', 'EnableOperationsAgent')) {
  foreach ($scriptAst in @($ast, $wrapper)) {
    $parameter = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name })
    if ($parameter.Count -ne 1 -or $parameter[0].DefaultValue.Extent.Text -ne '$true') { throw "Missing safe default for $name." }
  }
}
Write-Output 'PASS: setup/Cloud Shell defaults, config opt-outs and explicit parameter precedence. No live calls.'
