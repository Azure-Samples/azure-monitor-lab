$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $source 'scripts/fabric-connections.ps1')
. (Join-Path $source 'scripts/fabric-observability.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'scripts/setup-fabric.ps1'), [ref]$null, [ref]$null)
$definition = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-FabricConnection' })[0]
. ([scriptblock]::Create($definition.Extent.Text))
$fabricApi = 'https://api.fabric.microsoft.com/v1'
$script:fabricHeaders = @{ Authorization = 'offline-test' }
$SubscriptionId = '11111111-1111-1111-1111-111111111111'
$customerId = '22222222-2222-2222-2222-222222222222'
$resourceGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/test-lab"
$sourceId = "$resourceGroupScope/providers/Microsoft.OperationalInsights/workspaces/test-law"
$fixture = @{}
function Reset-Fixture {
  $fixture.Identity = $null
  $fixture.Provisions = 0
  $fixture.Connections = @()
  $fixture.Posts = 0
  $fixture.Body = $null
  $fixture.Roles = @()
  $fixture.Assignments = @()
  $fixture.CreatedRole = $null
  $fixture.Grants = 0
  $fixture.AzureFailure = $false
  $fixture.RemainingAssignments = @()
  $fixture.DeletedConnections = @()
  $fixture.DeletedRoles = 0
  $fixture.DeletedAssignments = 0
  $fixture.ConnectionFailures = 0
  $fixture.Delays = 0
}
function New-FabricItem {
  param($Path, $Body)
  if ($Path -notlike 'workspaces/*/provisionIdentity') { throw "Unexpected identity request: $Path" }
  $fixture.Provisions++
  $fixture.Identity = @{ servicePrincipalId = 'workspace-principal' }
}
function Invoke-RestMethod {
  param($Method, $Uri, $Headers, $ContentType, $Body)
  if ($Headers.Authorization -ne 'offline-test') { throw 'Unexpected Fabric credentials.' }
  if ($Method -eq 'Get' -and $Uri -eq "$fabricApi/workspaces/workspace") { return @{ workspaceIdentity = $fixture.Identity } }
  if ($Method -eq 'Get' -and $Uri -eq "$fabricApi/connections") { return @{ value = $fixture.Connections } }
  if ($Method -eq 'Post' -and $Uri -eq "$fabricApi/connections") {
    $fixture.Posts++
    if ($fixture.ConnectionFailures -gt 0) {
      $fixture.ConnectionFailures--
      $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
      $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('Source access denied', $response)
      $record = [Management.Automation.ErrorRecord]::new($exception, 'FabricAuthorization', [Management.Automation.ErrorCategory]::PermissionDenied, $null)
      $record.ErrorDetails = [Management.Automation.ErrorDetails]::new('{"errorCode":"InvalidConnectionCredentials","message":"Source access denied"}')
      throw $record
    }
    $fixture.Body = $Body | ConvertFrom-Json
    return @{ id = 'new-connection' }
  }
  if ($Method -eq 'Delete' -and $Uri -like "$fabricApi/connections/*") { $fixture.DeletedConnections += $Uri; return }
  throw "Unexpected request: $Method $Uri"
}
function az {
  $global:LASTEXITCODE = $(if ($fixture.AzureFailure) { 1 } else { 0 })
  if ($fixture.AzureFailure) { return }
  if (($args -join ' ') -match 'keys|password|secret|Owner|disableLocalAuth') { throw 'Source setup must not read keys, enable local auth or grant Owner.' }
  if ($args -notcontains $SubscriptionId) { throw 'Azure subscription must be explicit.' }
  switch ($args[0..2] -join ' ') {
    'role definition list' { return ConvertTo-Json -InputObject @($fixture.Roles) -Depth 10 }
    'role definition create' {
      $fixture.CreatedRole = $args[([Array]::IndexOf($args, '--role-definition') + 1)] | ConvertFrom-Json
      return '{"name":"33333333-3333-3333-3333-333333333333"}'
    }
    'role assignment list' {
      if ($args -contains '--role') { return ConvertTo-Json -InputObject @($fixture.RemainingAssignments) -Depth 10 }
      return ConvertTo-Json -InputObject @($fixture.Assignments) -Depth 10
    }
    'role assignment create' {
      if ($args -notcontains $sourceId -or $args -notcontains 'workspace-principal' -or
          $args -notcontains 'ServicePrincipal') { throw 'Mirror role must be assigned only to the workspace identity at the source LAW.' }
      $fixture.Grants++
      return
    }
    'role assignment delete' {
      if ($args -notcontains $sourceId -or $args -notcontains 'workspace-principal') { throw 'Cleanup must remain source-LAW/workspace-identity scoped.' }
      $fixture.DeletedAssignments++
      return
    }
    'role definition delete' { $fixture.DeletedRoles++; return }
  }
  throw "Unexpected Azure command: $($args -join ' ')"
}
function Start-Sleep { param($Seconds); $fixture.Delays++ }
function Assert-Failure([scriptblock] $Action, [string] $Expected) {
  $failure = ''
  try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
  if ($failure -notlike $Expected) { throw "Expected '$Expected', got '$failure'." }
}
function Test-MonitorConnection {
  Ensure-FabricMonitorConnection -WorkspaceId workspace -SourceResourceId $sourceId -SourceCustomerId $customerId
}

Reset-Fixture
1..2 | ForEach-Object { Ensure-FabricWorkspaceIdentity -WorkspaceId workspace | Out-Null }
if ($fixture.Provisions -ne 1) { throw 'Workspace identity must be provisioned once and reused.' }
Reset-Fixture
$connection = Test-MonitorConnection
if ($connection.id -ne 'new-connection' -or $fixture.Grants -ne 1 -or $fixture.Posts -ne 1 -or
    $fixture.Body.connectionDetails.type -ne 'AzureMonitorMirroredCatalog' -or
    $fixture.Body.credentialDetails.credentials.credentialType -ne 'WorkspaceIdentity' -or
    $fixture.Body.credentialDetails.skipTestConnection -ne $false -or
    @($fixture.Body.connectionDetails.parameters | Where-Object { $_.name -eq 'workspaceId' -and $_.value -eq $customerId }).Count -ne 1) {
  throw 'Mirror creation must use customer GUID, tested keyless credentials and source-scoped authorization.'
}
$actions = @($fixture.CreatedRole.Actions | Sort-Object)
if (($actions -join ',') -cne 'Microsoft.Authorization/roleAssignments/write,Microsoft.OperationalInsights/workspaces/query/read,Microsoft.OperationalInsights/workspaces/read' -or
    ($fixture.CreatedRole.AssignableScopes -join ',') -ne $resourceGroupScope) {
  throw 'Custom-role availability must be resource-group-scoped and its permissions must be exactly the documented connection requirements.'
}
Reset-Fixture
$fixture.Roles = @(@{
  name = '33333333-3333-3333-3333-333333333333'; roleType = 'CustomRole'
  assignableScopes = @($resourceGroupScope)
  permissions = @(@{ actions = $actions; notActions = @(); dataActions = @(); notDataActions = @() })
})
$fixture.Assignments = @(@{ roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/33333333-3333-3333-3333-333333333333' })
Test-MonitorConnection | Out-Null
if ($fixture.Grants -or $fixture.CreatedRole) { throw 'Existing exact source roles and assignments must be reused.' }
$fixture.Roles[0].permissions[0].actions = @('*')
Assert-Failure { Test-MonitorConnection } '*refusing reuse*'
Reset-Fixture
$fixture.AzureFailure = $true
Assert-Failure { Test-MonitorConnection } '*Cannot inspect*'
Reset-Fixture
$fixture.ConnectionFailures = 1
Test-MonitorConnection | Out-Null
if ($fixture.Posts -ne 2 -or $fixture.Delays -ne 1) { throw 'Explicit connection authorization failures should allow bounded RBAC propagation retries.' }
Reset-Fixture
$fixture.ConnectionFailures = 6
Assert-Failure { Test-MonitorConnection } '*Source access denied*'
if ($fixture.Posts -ne 6 -or $fixture.Delays -ne 5) { throw 'Authorization retries must stop after six attempts and propagate failure.' }
Reset-Fixture
$fixture.Connections = @(@{ id = 'existing'; connectionDetails = @{ type = 'AzureMonitorMirroredCatalog'; path = "$customerId;https://api.loganalytics.io/iceberg" } })
if ((Test-MonitorConnection).id -ne 'existing' -or $fixture.Provisions -or $fixture.Grants -or $fixture.Posts) {
  throw 'Existing authorized connection must not trigger identity, role or credential writes.'
}
Assert-Failure {
  Ensure-FabricMonitorConnection -WorkspaceId workspace -SourceResourceId $sourceId -SourceCustomerId $customerId -ConnectionId 'wrong-source-connection'
} '*must target the discovered*'
$fixture.Connections += $fixture.Connections[0]
Assert-Failure { Test-MonitorConnection } '*Multiple mirror connections*'
Write-Output 'PASS: workspace identity provisioning, customer GUID matching, scoped mirroring role grants, exact role reuse and explicit authorization failures.'

Reset-Fixture
$fixture.Connections = @(@{
  id = 'event-hub'; displayName = 'amlab-testhub-diagnostics'
  connectionDetails = @{ type = 'EventHub'; path = 'testhub.servicebus.windows.net;diagnostics' }
})
$parameters = @{ DisplayName = 'amlab-testhub-diagnostics'; NamespaceName = 'testhub'; EventHubName = 'diagnostics' }
if ((Get-FabricConnection @parameters).id -ne 'event-hub') { throw 'Exact Event Hub endpoint must match.' }
$fixture.Connections[0].connectionDetails.path = 'testhub-other.servicebus.windows.net;diagnostics'
Assert-Failure { Get-FabricConnection @parameters } '*targets a different Event Hub*'
$fixture.Connections[0].displayName = 'other-name'
if (Get-FabricConnection @parameters) { throw 'Namespace substrings must not match another namespace.' }
$fixture.Connections[0].connectionDetails.path = 'testhub;diagnostics-other'
if (Get-FabricConnection @parameters) { throw 'Event Hub substrings must not match another entity.' }
$fixture.Connections[0].connectionDetails.path = 'testhub;diagnostics'
$fixture.Connections += $fixture.Connections[0]
Assert-Failure { Get-FabricConnection @parameters } '*Multiple connections target*'
Write-Output 'PASS: Event Hub discovery rejects mismatched names, namespace/entity substrings and ambiguous matches. No live calls.'

foreach ($sharedRole in @($false, $true)) {
  Reset-Fixture
  $fixture.Identity = @{ servicePrincipalId = 'workspace-principal' }
  $fixture.Roles = @(@{
    name = '33333333-3333-3333-3333-333333333333'; roleType = 'CustomRole'
    assignableScopes = @($resourceGroupScope)
  })
  $fixture.Connections = @(
    @{ id = 'generated'; displayName = "amlab-mirror-$customerId"; connectionDetails = @{ type = 'AzureMonitorMirroredCatalog'; path = "$customerId;https://api.loganalytics.io/iceberg" } },
    @{ id = 'preauthorized'; displayName = 'User authorized mirror'; connectionDetails = @{ type = 'AzureMonitorMirroredCatalog'; path = "$customerId;https://api.loganalytics.io/iceberg" } }
  )
  if ($sharedRole) { $fixture.RemainingAssignments = @(@{ principalId = 'other-workspace' }) }
  Remove-FabricMonitorAccess -WorkspaceId workspace -SourceResourceId $sourceId -SourceCustomerId $customerId
  $expectedDeletes = if ($sharedRole) { 0 } else { 1 }
  if ($fixture.DeletedConnections.Count -ne 1 -or $fixture.DeletedConnections[0] -notlike '*/generated' -or
      $fixture.DeletedAssignments -ne 1 -or $fixture.DeletedRoles -ne $expectedDeletes) {
    throw 'Teardown must preserve preauthorized connections and roles assigned elsewhere, deleting only the generated source access.'
  }
}
Write-Output 'PASS: generated connection/access teardown is source-scoped and preserves independently authorized connections and shared roles.'
