$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $source 'scripts/fabric-observability.ps1')
. (Join-Path $source 'scripts/fabric-monitoring.ps1')
$setupPath = Join-Path $source 'scripts/setup-fabric.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Fabric setup does not parse.' }
foreach ($name in @('Get-CollectionItem', 'New-FabricItem', 'ConvertTo-InlineBase64')) {
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
  $fixture.Forbidden = $false
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
  if ($Method -eq 'Post' -and $Uri -like '*/getDefinition') {
    if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value 200 -Scope 1 }
    return @{ definition = $fixture.Definitions[($Uri -split '/')[-2]] }
  }
  throw "Unexpected REST call; monitoring and agent checks must not mutate items: $Method $Uri"
}
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $message = ''
  try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
  if ($message -notlike $Expected) { throw "Expected '$Expected', got '$message'." }
}
function Test-Monitoring { Get-FabricWorkspaceMonitoringReadiness -WorkspaceId $workspaceId }
function Test-Agent {
  Get-FabricOperationsAgentReadiness -WorkspaceId $workspaceId -DatabaseId $databaseId -TableName AzureDiagnosticsRaw -Recipient operator@example.com
}
function Get-SavedContent($Item) {
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($fixture.Definitions[$Item.id].parts[0].payload)) | ConvertFrom-Json
}
function Set-SavedContent($Item, $Content) {
  $fixture.Definitions[$Item.id].parts[0].payload = ConvertTo-InlineBase64 ($Content | ConvertTo-Json -Depth 15)
}
function Add-ExistingAgent {
  $item = @{ id = 'existing-agent'; displayName = 'Azure Monitor Lab Operations Agent' }
  $fixture.Agents = @($item)
  $fixture.Definitions[$item.id] = @{
    parts = @(@{ path = 'Configurations.json'; payloadType = 'InlineBase64'; payload = '' })
  }
  Set-SavedContent $item @{
    configuration = @{
      instructions = 'User-edited instructions'
      dataSources = @{ labTelemetry = @{ id = $databaseId; workspaceId = $workspaceId; type = 'KustoDatabase' } }
      actions = @{ userAction = @{ name = 'Existing user action' } }
      messageDestination = @{ kind = 'Recipient'; recipient = 'existing@example.com' }
    }
    playbook = @{ userContent = 'Existing user playbook' }
    shouldRun = $false
  }
}

Reset-Fixture
$result = Test-Monitoring
if ($result.Status -ne 'ActionRequired' -or $result.Detail -notlike '*Allow monitoring data collection*' -or
    $result.Detail -notlike '*manual-monitoring-and-operations-agent-setup*' -or $fixture.Monitoring.Count) {
  throw 'Missing monitoring must produce actionable tenant-admin/workspace setup instructions without creating an item.'
}
$fixture.Monitoring = @(@{ id = 'monitoring'; displayName = 'Existing user monitoring' })
1..2 | ForEach-Object {
  if ((Test-Monitoring).Status -ne 'ActionRequired' -or $fixture.State -ne 'Disabled') {
    throw 'Disabled collection must remain unchanged and require manual activation, including on reruns.'
  }
}
$fixture.State = 'Enabled'
if ((Test-Monitoring).Status -ne 'Configured' -or $fixture.State -ne 'Enabled') {
  throw 'Existing enabled collection must be recognized without changing it.'
}
$fixture.State = 'Unknown'
Assert-Failure { Test-Monitoring } '*unknown dataCollectionState*'
$fixture.Monitoring += @{ id = 'second'; displayName = 'OtherMonitoring' }
if ((Test-Monitoring).Status -ne 'ActionRequired') { throw 'Ambiguous collection ownership must require manual review.' }
if (@($fixture.Requests | Where-Object Method -ne Get).Count) { throw 'Workspace monitoring checks must only issue GET requests.' }
Write-Output 'PASS: missing/disabled monitoring requires manual setup, enabled state is read back, and ambiguous/unknown states are explicit. No mutations.'

Reset-Fixture
$result = Test-Agent
if ($result.Status -ne 'ActionRequired' -or $result.Detail -notlike "*$databaseId*AzureDiagnosticsRaw*operator@example.com*" -or
    $result.Detail -notlike '*Generate/review the playbook*' -or $fixture.Agents.Count) {
  throw 'Missing agents must report the lab source, recipient and manual playbook steps, without submitting an empty playbook.'
}
Add-ExistingAgent
$payload = $fixture.Definitions['existing-agent'].parts[0].payload
if ((Test-Agent).Status -ne 'ActionRequired' -or $fixture.Definitions['existing-agent'].parts[0].payload -cne $payload) {
  throw 'Stopped agents must require manual review and preserve instructions, actions, recipient, playbook and run state.'
}
$saved = Get-SavedContent $fixture.Agents[0]
$saved.shouldRun = $true
Set-SavedContent $fixture.Agents[0] $saved
$payload = $fixture.Definitions['existing-agent'].parts[0].payload
1..2 | ForEach-Object {
  if ((Test-Agent).Status -ne 'Configured' -or $fixture.Definitions['existing-agent'].parts[0].payload -cne $payload) {
    throw 'Running agents must be recognized without overwriting existing configuration or stopping them.'
  }
}
$saved.configuration.dataSources.labTelemetry.id = $workspaceId
Set-SavedContent $fixture.Agents[0] $saved
if ((Test-Agent).Detail -notlike '*different data source*') { throw 'Conflicting agent sources require explicit review.' }
$saved.configuration.dataSources.labTelemetry.id = $databaseId
$saved.shouldRun = 'invalid'
Set-SavedContent $fixture.Agents[0] $saved
Assert-Failure { Test-Agent } '*no Boolean shouldRun*'
if (@($fixture.Requests | Where-Object { $_.Method -ne 'Get' -and $_.Uri -notlike '*/getDefinition' }).Count) {
  throw 'Agent checks must not create agents, update definitions or change run state.'
}
Reset-Fixture
$fixture.Forbidden = $true
Assert-Failure { Test-Monitoring } '*403*'
Assert-Failure { Test-Agent } '*403*'
Reset-Fixture
Assert-Failure { Get-FabricOperationsAgentReadiness -WorkspaceId $workspaceId -DatabaseId $databaseId -TableName 'bad;query' -Recipient operator@example.com } '*KQL identifier*'
if ($fixture.Requests.Count) { throw 'Invalid configuration must fail before API calls.' }
Write-Output 'PASS: agents require manual creation/playbook review, existing settings/run states are preserved, and malformed/denied requests fail explicitly.'

$configBlock = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (Test-Path -LiteralPath $configPath)')
})[0]
function Test-Config {
  param([bool] $EnableWorkspaceMonitoring = $true, [bool] $EnableOperationsAgent = $true)
  $configPath = 'fixture.json'
  $Teardown = $false
  function Test-Path { return $true }
  function Get-Content { return '{"fabricAutomation":{"enableWorkspaceMonitoring":false,"enableOperationsAgent":false}}' }
  . ([scriptblock]::Create('param($explicitParameters); $PSScriptRoot = Join-Path $source ''scripts''; $PSBoundParameters = $explicitParameters; ' + $configBlock.Extent.Text)) $PSBoundParameters
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
    if ($parameter.Count -ne 1 -or $parameter[0].DefaultValue.Extent.Text -ne '$true') { throw "Missing readiness-check default for $name." }
  }
}
Write-Output 'PASS: setup/Cloud Shell readiness defaults, config opt-outs and explicit parameter precedence. No live calls.'
