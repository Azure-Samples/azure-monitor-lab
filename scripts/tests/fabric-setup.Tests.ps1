$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scriptPath = Join-Path $source 'scripts/setup-fabric.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Fabric setup does not parse: $($parseErrors.Message -join '; ')" }

foreach ($name in @('Write-Info', 'Wait-FabricOperation', 'New-FabricItem', 'ConvertTo-InlineBase64', 'Set-EventstreamTopology', 'Ensure-EventHubConnection')) {
  $definition = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
  })
  if ($definition.Count -ne 1) { throw "Expected one Fabric helper named '$name'." }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}

$fabricApi = 'https://api.fabric.microsoft.com/v1'
$script:fabricHeaders = @{ Authorization = 'Bearer ' + [guid]::NewGuid().ToString('N') }
$MaxOperationMinutes = 1
$fixture = @{}

function Reset-Fixture {
  $fixture.StatusCode = 201
  $fixture.Headers = @{ Location = @("$fabricApi/workspaces/test-workspace") }
  $fixture.CreateUri = "$fabricApi/workspaces"
  $fixture.OperationUri = "$fabricApi/operations/test-operation"
  $fixture.States = [Collections.Generic.Queue[object]]::new()
  $fixture.Posts = 0
  $fixture.Polls = 0
  $fixture.Delays = [Collections.Generic.List[int]]::new()
  $fixture.PostFailure = ''
  $fixture.Connection = $null
  $fixture.KeyReads = 0
  $fixture.ConnectionBody = $null
}

function Get-FabricConnection { param($DisplayName, $NamespaceName, $EventHubName); return $fixture.Connection }
function az {
  if (($args -join ' ') -notlike 'eventhubs namespace authorization-rule keys list *') { throw 'Unexpected Azure CLI call.' }
  $fixture.KeyReads++
  $global:LASTEXITCODE = 0
  return 'offline-listen-test'
}

function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body, $ResponseHeadersVariable, $StatusCodeVariable)
  if ($Headers.Authorization -ne $script:fabricHeaders.Authorization) { throw 'Unexpected Fabric authorization.' }
  if ($Method -eq 'Post' -and $Uri -eq "$fabricApi/connections") {
    $fixture.Posts++
    $fixture.ConnectionBody = $Body | ConvertFrom-Json
    return @{ id = 'test-connection' }
  }
  if ($Method -eq 'Post' -and $Uri -eq "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/getDefinition") {
    return @{ definition = @{ parts = @() } }
  }
  if ($Method -eq 'Get' -and $Uri -eq "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/topology") {
    return @{ sources = @() }
  }
  if ($Method -eq 'Post' -and $Uri -eq $fixture.CreateUri) {
    $fixture.Posts++
    if ($fixture.PostFailure) { throw $fixture.PostFailure }
    if ($ContentType -ne 'application/json' -or -not ($Body | ConvertFrom-Json)) { throw 'Invalid Fabric request body.' }
    if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value $fixture.Headers -Scope 1 }
    if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value $fixture.StatusCode -Scope 1 }
    if ($fixture.StatusCode -eq 202) { return }
    return [pscustomobject]@{ id = 'test-workspace'; displayName = 'Test workspace' }
  }
  if ($Method -eq 'Get') {
    $fixture.Polls++
    if ($Uri -ne $fixture.OperationUri) { throw "Unexpected polling URL '$Uri' after HTTP $($fixture.StatusCode)." }
    if (-not $fixture.States.Count) { throw 'The test did not expect another operation poll.' }
    if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value @{ 'Retry-After' = @('2') } -Scope 1 }
    return $fixture.States.Dequeue()
  }
  throw "Unexpected Fabric request: $Method $Uri"
}

function Start-Sleep {
  param([int] $Seconds)
  $fixture.Delays.Add($Seconds)
}

function Assert-Failure {
  param([scriptblock] $Action, [string] $ExpectedMessage)
  $failure = ''
  try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike $ExpectedMessage) { throw "Expected '$ExpectedMessage', got '$failure'." }
}

function Invoke-TestCreate {
  New-FabricItem -Path 'workspaces' -Body @{ displayName = 'Test workspace' }
}

function Invoke-TestTopology {
  Set-EventstreamTopology -WorkspaceId test-workspace -EventstreamId test-stream `
    -ConnectionId test-connection -KqlDatabaseId test-database -DatabaseName TestDatabase -TableName TestTable
}

foreach ($statusCode in @(201, 200)) {
  Reset-Fixture
  $fixture.StatusCode = $statusCode
  $created = Invoke-TestCreate
  if ($created.id -ne 'test-workspace' -or $fixture.Posts -ne 1 -or $fixture.Polls -or $fixture.Delays.Count) {
    throw "HTTP $statusCode must return the created resource without polling or rerunning the POST."
  }
}
Write-Output 'PASS: HTTP 200/201 with a resource Location return immediately.'

foreach ($headerMode in @('absolute', 'relative', 'id-only', 'id-with-result-location')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = switch ($headerMode) {
    'absolute' { @{ Location = @($fixture.OperationUri) } }
    'relative' { @{ Location = @('/v1/operations/test-operation') } }
    'id-only' { @{ 'x-ms-operation-id' = @('test-operation') } }
    'id-with-result-location' { @{ Location = @("$($fixture.OperationUri)/result"); 'x-ms-operation-id' = @('test-operation') } }
  }
  foreach ($status in @('NotStarted', 'Running', 'Succeeded')) { $fixture.States.Enqueue(@{ status = $status }) }
  Invoke-TestCreate | Out-Null
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 3 -or ($fixture.Delays -join ',') -ne '2,2') {
    throw "HTTP 202 must wait to completion using '$headerMode' headers without repeating the POST."
  }
}
Write-Output 'PASS: HTTP 202 waits for completion using operation Location or ID and honors Retry-After.'

Reset-Fixture
$fixture.StatusCode = 202
$fixture.Headers = @{}
Assert-Failure { Invoke-TestCreate } '*operation URL or ID*'
if ($fixture.Posts -ne 1 -or $fixture.Polls -or $fixture.Delays.Count) { throw 'Missing operation metadata must fail before polling.' }

foreach ($status in @($null, '', 'UnexpectedStatus')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = @{ Location = @($fixture.OperationUri) }
  $fixture.States.Enqueue(@{ status = $status })
  Assert-Failure { Invoke-TestCreate } '*unexpected status*'
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 1 -or $fixture.Delays.Count) { throw 'Missing or unknown status must fail without an empty polling loop.' }
}

foreach ($status in @('Failed', 'Cancelled')) {
  Reset-Fixture
  $fixture.StatusCode = 202
  $fixture.Headers = @{ Location = @($fixture.OperationUri) }
  $fixture.States.Enqueue(@{ status = $status; error = @{ errorCode = 'TestFailure'; message = 'Test operation failed.' } })
  Assert-Failure { Invoke-TestCreate } "*status '$status'*TestFailure*"
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne 1 -or $fixture.Delays.Count) { throw 'Failed operations must stop without resubmission.' }
}

Reset-Fixture
$fixture.PostFailure = 'Test request denied.'
Assert-Failure { Invoke-TestCreate } 'Test request denied.'
if ($fixture.Posts -ne 1 -or $fixture.Polls) { throw 'Request failures must not be retried or polled.' }
Write-Output 'PASS: Missing operation metadata, invalid statuses, failed operations, and request errors stop promptly.'

foreach ($statusCode in @(200, 202)) {
  Reset-Fixture
  $fixture.StatusCode = $statusCode
  $fixture.CreateUri = "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/updateDefinition"
  if ($statusCode -eq 202) {
    $fixture.Headers = @{ 'x-ms-operation-id' = @('test-operation') }
    $fixture.States.Enqueue(@{ status = 'Running' })
    $fixture.States.Enqueue(@{ status = 'Succeeded' })
  }
  Invoke-TestTopology
  $expectedPolls = if ($statusCode -eq 202) { 2 } else { 0 }
  if ($fixture.Posts -ne 1 -or $fixture.Polls -ne $expectedPolls) { throw "Eventstream update mishandled HTTP $statusCode." }
}

Reset-Fixture
$fixture.StatusCode = 202
$fixture.CreateUri = "$fabricApi/workspaces/test-workspace/eventstreams/test-stream/updateDefinition"
$fixture.Headers = @{}
Assert-Failure { Invoke-TestTopology } '*operation URL or ID*'
if ($fixture.Posts -ne 1 -or $fixture.Polls) { throw 'An accepted Eventstream update without operation metadata must not report success.' }
Write-Output 'PASS: Eventstream updates use the same synchronous/asynchronous rules. No Azure calls or real delays.'

Reset-Fixture
$fixture.Connection = @{ id = 'identity-connection'; credentialDetails = @{ credentialType = 'WorkspaceIdentity' } }
$connection = Ensure-EventHubConnection -NamespaceName testhub -EventHubName diagnostics
if ($connection.id -ne 'identity-connection' -or $fixture.KeyReads -or $fixture.Posts) {
  throw 'Workspace-identity connections must be reused without reading shared keys or replacing credentials.'
}
Reset-Fixture
$connection = Ensure-EventHubConnection -NamespaceName testhub -EventHubName diagnostics
$endpoint = @($fixture.ConnectionBody.connectionDetails.parameters | Where-Object name -eq endpoint)
if ($connection.id -ne 'test-connection' -or $fixture.KeyReads -ne 1 -or $fixture.Posts -ne 1 -or
    $endpoint.Count -ne 1 -or $endpoint[0].value -ne 'testhub' -or
    $fixture.ConnectionBody.credentialDetails.credentials.credentialType -ne 'Basic') {
  throw 'Shared-key connections must use the connector namespace parameter, not a Service Bus URI.'
}
Write-Output 'PASS: Workspace identity is preserved and new connections use the established EventHub endpoint format.'

$mainTemplate = Get-Content -LiteralPath (Join-Path $source 'infra/main.json') -Raw | ConvertFrom-Json -AsHashtable
$capacityDeployments = @($mainTemplate.resources | Where-Object { $_.name -eq 'fabric-capacity' })
if ($mainTemplate.outputs.Count -gt 64 -or $capacityDeployments.Count -ne 1 -or
    $capacityDeployments[0].condition -cne "[parameters('enableFabric')]" -or
    $mainTemplate.parameters.enableFabric.defaultValue -ne $false) {
  throw 'The combined lab must retain the optional capacity without exceeding the ARM output limit.'
}
[xml]$architecture = Get-Content -LiteralPath (Join-Path $source 'docs/architecture-overview-sre.svg') -Raw
$elements = @{}
foreach ($element in $architecture.SelectNodes('//*[@id]')) { $elements[$element.id] = $element }
foreach ($id in @('node-CUSTOMER', 'node-OBS', 'node-OAMW', 'node-OTEL', 'node-COPILOT',
    'node-FAB', 'node-EVSTR', 'node-EH', 'node-RTD', 'node-DELTA', 'edge-PLAT-EVSTR', 'edge-EVSTR-EH', 'edge-EH-RTD', 'edge-LAW-DELTA', 'edge-DELTA-EH')) {
  if (-not $elements.ContainsKey($id)) { throw "Shared architecture is missing '$id'." }
}
$azureBoundary = $elements['azure-resource-group-boundary']
$azureBottom = [double]$azureBoundary.y + [double]$azureBoundary.height
$fabricBoundary = $elements['fabric-workspace-boundary']
if ([double]$fabricBoundary.y -le $azureBottom -or
    [double]$elements['node-FAB'].rect.y -ge $azureBottom) {
  throw 'The Fabric capacity must be inside Azure and tenant-scoped items outside the resource group.'
}
foreach ($id in @('node-EVSTR', 'node-EH', 'node-RTD', 'node-DELTA')) {
  if ([double]$elements[$id].rect.y -lt [double]$fabricBoundary.y -or
      [double]$elements[$id].rect.y + [double]$elements[$id].rect.height -gt [double]$fabricBoundary.y + [double]$fabricBoundary.height) {
    throw "Fabric item '$id' is outside the tenant-scoped workspace boundary."
  }
  if ($elements['fabric-workspace-title'].InnerText -match '(?i)optional' -or
      $elements['fabric-mirroring-storage-note'].InnerText -notmatch 'Azure Monitor Delta storage.*no data copy') {
    throw 'Fabric title must omit optional and mirroring must describe shared Azure Monitor storage without a data copy.'
  }
  $customerImages = @($elements['node-CUSTOMER'].GetElementsByTagName('image'))
  $customerIcons = @('Customer_App_Service.svg', 'Customer_Service_Bus.svg', 'Customer_Function_App.svg', 'Customer_SQL_Database.svg')
  if ($customerImages.Count -ne 4) { throw 'Customer application must retain all four original service icons.' }
  for ($i = 0; $i -lt $customerIcons.Count; $i++) {
    $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source "docs/icons/azure/$($customerIcons[$i])")))
    if ($customerImages[$i].href -cne "data:image/svg+xml;base64,$expected" -or $customerImages[$i].width -ne '28') {
      throw "Customer service icon '$($customerIcons[$i])' was replaced or resized."
    }
  }
  foreach ($icon in @{ 'node-EH' = 'Fabric_Eventhouse.svg'; 'node-RTD' = 'Fabric_Real_Time_Dashboard.svg' }.GetEnumerator()) {
    $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $source "docs/icons/azure/$($icon.Value)")))
    if ($elements[$icon.Key].image.href -cne "data:image/svg+xml;base64,$expected") {
      throw "Fabric item '$($icon.Key)' must use its service-specific icon."
    }
  }
  if ($elements['node-DELTA'].image.href -cne $elements['node-FAB'].image.href) {
    throw 'The mirrored Delta Lake access node must have its own Fabric logo.'
  }
}
$scenarioText = Get-Content -LiteralPath (Join-Path $source 'docs/DEMO-SCENARIOS.md') -Raw
$scenarioIds = @([regex]::Matches($scenarioText, '<a id="s(\d+)"></a>') | ForEach-Object { [int]$_.Groups[1].Value })
if (@($scenarioIds | Select-Object -Unique).Count -ne $scenarioIds.Count) { throw 'Scenario anchors must remain unique.' }
foreach ($number in 0..80) {
  if ($scenarioIds -notcontains $number) { throw "Integration or Fabric scenario '$number' was lost." }
}
Write-Output 'PASS: combined template output budget, shared architecture boundaries, and all integration/Fabric scenario anchors are preserved.'