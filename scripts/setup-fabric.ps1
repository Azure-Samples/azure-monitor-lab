<#
.SYNOPSIS
  Create the optional Microsoft Fabric Real-Time Intelligence demo items.

.DESCRIPTION
  Pins and verifies the Azure subscription, finds the deployed Fabric F2 capacity,
  then creates or reuses a workspace, Eventhouse, KQL database, and Eventstream.
  It attempts to create the Event Hubs connection and publish the source-to-Eventhouse
  topology using workspace identity and Extended Event Hubs. By default it also
  provisions both Log Analytics mirrors/dashboards and daily capacity suspension.
  Tenant preview enablement and Capacity Metrics licensing remain prerequisites.

.EXAMPLE
  ./scripts/setup-fabric.ps1 -SubscriptionId <subscription-id> -ResourceGroup rg-azure-monitor-lab
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [string] $NamePrefix = 'amlab',
  [string] $WorkspaceName = 'Azure Monitor Demo Lab',
  [string] $EventhouseName = 'Azure Monitor Demo Eventhouse',
  [string] $KqlDatabaseName = 'MonitoringTelemetry',
  [string] $EventstreamName = 'AzureMonitorEvents',
  [string] $DestinationTableName = 'AzureDiagnosticsRaw',
  [bool] $SeedSampleData = $true,
  [bool] $EnableMirroring = $true,
  [string] $MirrorConnectionId = '',
  [string[]] $MirrorScope = @(),
  [string[]] $MirrorTables = @('AzureActivity', 'ContainerLogV2', 'AppServiceHTTPLogs', 'Perf'),
  [string] $AppInsightsMirrorConnectionId = '',
  [string[]] $AppInsightsMirrorTables = @('AppRequests', 'AppDependencies', 'AppExceptions', 'AppTraces'),
  [ValidateRange(1, 900)] [int] $VerificationTimeoutSeconds = 180,
  [bool] $EnableAutoSuspend = $true,
  [ValidateRange(0, 23)] [int] $AutoSuspendHourUtc = 20,
  [ValidateRange(0, 59)] [int] $AutoSuspendMinuteUtc = 0,
  [ValidateRange(5, 120)] [int] $MaxOperationMinutes = 30,
  [switch] $SkipEventstreamConnection,
  [switch] $Teardown
)

$ErrorActionPreference = 'Stop'
$fabricApi = 'https://api.fabric.microsoft.com/v1'
. (Join-Path $PSScriptRoot 'fabric-observability.ps1')
. (Join-Path $PSScriptRoot 'fabric-connections.ps1')
. (Join-Path $PSScriptRoot 'fabric-mirrored-dashboard.ps1')

$configPath = Join-Path $PSScriptRoot '..' 'lab.config.json'
if (Test-Path -LiteralPath $configPath) {
  $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $automation = $configuration.fabricAutomation
  if (-not $PSBoundParameters.ContainsKey('NamePrefix') -and $configuration.namePrefix) {
    $NamePrefix = $configuration.namePrefix
  }
  $options = @{
    WorkspaceName = 'workspaceName'
    SeedSampleData = 'seedSampleData'; EnableMirroring = 'enableMirroring'
    MirrorConnectionId = 'mirrorConnectionId'; MirrorScope = 'mirrorScope'; MirrorTables = 'mirrorTables'
    AppInsightsMirrorConnectionId = 'appInsightsMirrorConnectionId'; AppInsightsMirrorTables = 'appInsightsMirrorTables'
    VerificationTimeoutSeconds = 'verificationTimeoutSeconds'; EnableAutoSuspend = 'enableAutoSuspend'
    AutoSuspendHourUtc = 'autoSuspendHourUtc'; AutoSuspendMinuteUtc = 'autoSuspendMinuteUtc'
  }
  foreach ($parameter in $options.Keys) {
    if ($Teardown -and $parameter -ne 'WorkspaceName') { continue }
    $value = $automation.($options[$parameter])
    if (-not $PSBoundParameters.ContainsKey($parameter) -and $null -ne $value) {
      if ($parameter -in @('SeedSampleData', 'EnableMirroring', 'EnableAutoSuspend') -and $value -isnot [bool]) {
        throw "fabricAutomation.$($options[$parameter]) must be a JSON boolean."
      }
      Set-Variable -Name $parameter -Value $value
    }
  }
}
if ($VerificationTimeoutSeconds -lt 1 -or $VerificationTimeoutSeconds -gt 900 -or
    $AutoSuspendHourUtc -lt 0 -or $AutoSuspendHourUtc -gt 23 -or
    $AutoSuspendMinuteUtc -lt 0 -or $AutoSuspendMinuteUtc -gt 59) {
  throw 'Fabric automation timeout or UTC schedule is outside its supported range.'
}

function Write-Step($Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info($Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

function Get-CollectionItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $DisplayName
  )

  $items = @(Get-FabricApiCollection -Path $Path | Where-Object { $_.displayName -eq $DisplayName })
  if ($items.Count -gt 1) { throw "Multiple Fabric items are named '$DisplayName'; refusing an ambiguous match." }
  return $items | Select-Object -First 1
}

function Wait-FabricOperation {
  param(
    [Parameter(Mandatory)] [string] $OperationUrl,
    [string] $OperationId = ''
  )

  if ($OperationUrl.StartsWith('/')) {
    $OperationUrl = "https://api.fabric.microsoft.com$OperationUrl"
  }
  if ([string]::IsNullOrWhiteSpace($OperationId)) {
    $OperationId = ($OperationUrl.TrimEnd('/') -split '/')[-1]
  }

  $deadline = [DateTime]::UtcNow.AddMinutes($MaxOperationMinutes)
  $lastStatus = ''
  $operation = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    $pollHeaders = $null
    $operation = Invoke-RestMethod `
      -Method Get `
      -Uri $OperationUrl `
      -Headers $script:fabricHeaders `
      -ResponseHeadersVariable pollHeaders
    if ($operation.status -notin @('NotStarted', 'Running', 'Succeeded', 'Failed', 'Cancelled')) {
      $unexpectedStatus = if ([string]::IsNullOrWhiteSpace($operation.status)) { '<missing>' } else { $operation.status }
      throw "Fabric operation '$OperationId' returned unexpected status '$unexpectedStatus'. Expected an operation status response. Operation URL: $OperationUrl"
    }
    if ($operation.status -ne $lastStatus) {
      $progress = if ($null -ne $operation.percentComplete) { " ($($operation.percentComplete)%)" } else { '' }
      Write-Info "Fabric operation $OperationId`: $($operation.status)$progress"
      $lastStatus = $operation.status
    }
    if ($operation.status -eq 'Succeeded') { return }
    if ($operation.status -in @('Failed', 'Cancelled')) {
      $errorDetails = $operation.error | ConvertTo-Json -Depth 8 -Compress
      throw "Fabric operation '$OperationId' ended with status '$($operation.status)': $errorDetails"
    }

    $retryAfter = 10
    if ($pollHeaders -and $pollHeaders.'Retry-After') {
      $parsedRetryAfter = 0
      if ([int]::TryParse(($pollHeaders.'Retry-After' | Select-Object -First 1), [ref]$parsedRetryAfter)) {
        $retryAfter = [Math]::Min([Math]::Max($parsedRetryAfter, 1), 60)
      }
    }
    Start-Sleep -Seconds $retryAfter
  }

  $lastOperationStatus = if ($operation -and $operation.status) { $operation.status } else { '<unknown>' }
  $lastUpdated = if ($operation.lastUpdatedTimeUtc) { $operation.lastUpdatedTimeUtc } else { '<unknown>' }
  $percentComplete = if ($null -ne $operation.percentComplete) { $operation.percentComplete } else { '<unknown>' }
  throw "Fabric operation '$OperationId' did not complete within $MaxOperationMinutes minutes. Last status: '$lastOperationStatus', progress: $percentComplete%, last updated: $lastUpdated. The operation may still complete; rerun this script safely to discover and reuse the item. Operation URL: $OperationUrl"
}

function New-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [hashtable] $Body
  )

  $responseHeaders = $null
  $responseStatus = $null
  $request = @{
    Method = 'Post'
    Uri = "$fabricApi/$Path"
    Headers = $script:fabricHeaders
    ContentType = 'application/json'
    Body = ($Body | ConvertTo-Json -Depth 8)
    ResponseHeadersVariable = 'responseHeaders'
    StatusCodeVariable = 'responseStatus'
  }
  $result = Invoke-RestMethod @request
  if ($responseStatus -in @(200, 201)) { return $result }
  if ($responseStatus -ne 202) { throw "Fabric request '$Path' returned unexpected HTTP status '$responseStatus'." }

  $operationId = $responseHeaders.'x-ms-operation-id' | Select-Object -First 1
  $operationUrl = if ($operationId) { "$fabricApi/operations/$operationId" } else { $responseHeaders.Location | Select-Object -First 1 }
  if ([string]::IsNullOrWhiteSpace($operationUrl)) {
    throw "Fabric accepted '$Path' but did not return an operation URL or ID. No request was retried."
  }
  if ($operationUrl.StartsWith('/')) { $operationUrl = "https://api.fabric.microsoft.com$operationUrl" }
  Wait-FabricOperation -OperationUrl $operationUrl -OperationId $operationId
  if ($Path -match '/getDefinition$') {
    return Invoke-RestMethod -Method Get -Uri "$($operationUrl.TrimEnd('/'))/result" -Headers $script:fabricHeaders
  }
  return $result
}

function Ensure-FabricItem {
  param(
    [Parameter(Mandatory)] [string] $CollectionPath,
    [Parameter(Mandatory)] [string] $DisplayName,
    [Parameter(Mandatory)] [hashtable] $CreateBody
  )

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if ($item) {
    Write-Info "Reusing '$DisplayName' ($($item.id))"
    return $item
  }

  Write-Info "Creating '$DisplayName'"
  $created = New-FabricItem -Path $CollectionPath -Body $CreateBody
  if ($created.id) { return $created }

  $item = Get-CollectionItem -Path $CollectionPath -DisplayName $DisplayName
  if (-not $item) { throw "Fabric created '$DisplayName', but it could not be resolved afterward." }
  return $item
}

function ConvertTo-InlineBase64 {
  param([Parameter(Mandatory)] [string] $Value)
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-FabricConnection {
  param(
    [Parameter(Mandatory)] [string] $DisplayName,
    [string] $NamespaceName = '',
    [string] $EventHubName = ''
  )

  $connections = @(Get-FabricApiCollection -Path connections)
  $connection = @($connections | Where-Object { $_.displayName -eq $DisplayName })
  if ($connection.Count -gt 1) { throw "Multiple connections are named '$DisplayName'." }
  if ([string]::IsNullOrWhiteSpace($NamespaceName)) { return $connection | Select-Object -First 1 }
  $namespacePattern = '(^|[;"/:=])' + [regex]::Escape($NamespaceName) + '(\.servicebus\.windows\.net)?(?=$|[;"/},])'
  $eventHubPattern = '(^|[;"/:=])' + [regex]::Escape($EventHubName) + '(?=$|[;"/},])'
  $matches = @($connections | Where-Object {
    $_.connectionDetails.type -eq 'EventHub' -and
    $_.connectionDetails.path -match $namespacePattern -and $_.connectionDetails.path -match $eventHubPattern
  })
  if ($connection.Count -and $connection[0].id -notin $matches.id) {
    throw "Connection '$DisplayName' targets a different Event Hub; refusing reuse or credential changes."
  }
  if ($connection.Count) { return $connection[0] }
  if ($matches.Count -gt 1) { throw 'Multiple connections target the Event Hub; use a uniquely named lab connection.' }
  return $matches | Select-Object -First 1
}

function Ensure-EventHubConnection {
  param(
    [Parameter(Mandatory)] [string] $NamespaceName,
    [Parameter(Mandatory)] [string] $EventHubName,
    [Parameter(Mandatory)] [string] $WorkspaceId
  )

  $identity = Ensure-FabricWorkspaceIdentity -WorkspaceId $WorkspaceId
  $hubScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.EventHub/namespaces/$NamespaceName/eventhubs/$EventHubName"
  Grant-FabricSourceRole -PrincipalId $identity.servicePrincipalId -Scope $hubScope `
    -RoleId 'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
  $connectionName = "amlab-$NamespaceName-$EventHubName"
  $connection = Get-FabricConnection `
    -DisplayName $connectionName `
    -NamespaceName $NamespaceName `
    -EventHubName $EventHubName
  if ($connection -and $connection.credentialDetails.credentialType -eq 'WorkspaceIdentity') {
    Write-Info "Reusing workspace-identity Fabric connection '$connectionName' ($($connection.id)); shared keys are not required."
    return $connection
  }
  if ($connection) { throw "Connection '$connectionName' is not keyless. Preserve it and create a WorkspaceIdentity connection for this hub before rerunning; setup will not overwrite credentials." }
  return New-FabricKeylessConnection -Body @{
      connectivityType = 'ShareableCloud'
      displayName = $connectionName
      connectionDetails = @{
        type = 'EventHub'
        creationMethod = 'EventHub.Contents'
        parameters = @(
          @{ dataType = 'Text'; name = 'endpoint'; value = "$NamespaceName.servicebus.windows.net" }
          @{ dataType = 'Text'; name = 'entityPath'; value = $EventHubName }
        )
      }
      privacyLevel = 'Organizational'
      credentialDetails = @{
        connectionEncryption = 'NotEncrypted'
        credentials = @{ credentialType = 'WorkspaceIdentity' }
        skipTestConnection = $false
      }
  }
}

function Set-EventstreamTopology {
  param(
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventstreamId,
    [Parameter(Mandatory)] [string] $ConnectionId,
    [Parameter(Mandatory)] [string] $KqlDatabaseId,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $TableName
  )

  $sourceName = 'AzureEventHubSource'
  $streamName = "$EventstreamName-stream"
  $destinationName = 'EventhouseDestination'
  $definitionResponse = New-FabricItem -Path "workspaces/$WorkspaceId/eventstreams/$EventstreamId/getDefinition" -Body @{}
  $eventstreamPart = @($definitionResponse.definition.parts | Where-Object { $_.path -eq 'eventstream.json' }) | Select-Object -First 1
  $existingTopology = if ($eventstreamPart -and $eventstreamPart.payload) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($eventstreamPart.payload)) | ConvertFrom-Json
  } else {
    [pscustomobject]@{
      sources = @()
      destinations = @()
      streams = @()
      operators = @()
    }
  }

  $runtimeTopology = Invoke-RestMethod -Method Get `
    -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/topology" -Headers $script:fabricHeaders
  $existingSource = @($existingTopology.sources | Where-Object { $_.name -eq $sourceName }) | Select-Object -First 1
  $existingStream = @($existingTopology.streams | Where-Object { $_.name -eq $streamName }) | Select-Object -First 1
  $existingDestination = @($existingTopology.destinations | Where-Object { $_.name -eq $destinationName }) | Select-Object -First 1
  if (@($existingTopology.sources).Count -eq 1 -and @($existingTopology.destinations).Count -eq 1 -and
      @($existingTopology.streams).Count -eq 1 -and -not $existingTopology.operators -and
      -not @(@($runtimeTopology.sources) + @($runtimeTopology.destinations) | Where-Object status -eq 'Failed').Count) {
    $source = $existingTopology.sources[0]
    $stream = $existingTopology.streams[0]
    $destination = $existingTopology.destinations[0]
    if ($source.type -eq 'AzureEventHubExtended' -and $source.properties.dataConnectionId -eq $ConnectionId -and
        $source.properties.consumerGroupName -ceq '$Default' -and $destination.type -eq 'Eventhouse' -and
        $destination.properties.itemId -eq $KqlDatabaseId -and $destination.properties.workspaceId -eq $WorkspaceId -and
        $destination.properties.tableName -eq $TableName -and
        @($stream.inputNodes).Count -eq 1 -and $stream.inputNodes[0].name -eq $source.name -and
        @($destination.inputNodes).Count -eq 1 -and $destination.inputNodes[0].name -eq $stream.name) {
      Write-Info 'Existing Extended Event Hubs topology already targets this database/table; preserving its published definition.'
      return
    }
  }
  if (@($existingTopology.sources | Where-Object name -ne $sourceName).Count -or
      @($existingTopology.destinations | Where-Object name -ne $destinationName).Count -or
      @($existingTopology.streams | Where-Object name -ne $streamName).Count -or
      @($existingTopology.operators | Where-Object { $null -ne $_ }).Count) {
    throw 'Eventstream contains a custom topology; refusing to replace user-defined nodes. Use a separate EventstreamName for generated topology.'
  }
  $runtimeSource = @($runtimeTopology.sources | Where-Object { $_.name -eq $sourceName }) | Select-Object -First 1
  $sourceId = if ($existingSource.id -and $existingSource.type -eq 'AzureEventHubExtended' -and $runtimeSource.status -ne 'Failed') {
    $existingSource.id
  } else {
    if ($runtimeSource.status -eq 'Failed') {
      Write-Info "Recreating failed Eventstream source '$sourceName'"
    }
    [guid]::NewGuid().ToString()
  }
  $streamId = if ($existingStream.id) { $existingStream.id } else { [guid]::NewGuid().ToString() }
  $destinationId = if ($existingDestination.id) { $existingDestination.id } else { [guid]::NewGuid().ToString() }

  $topology = [ordered]@{
    sources = @(
      [ordered]@{
        id = $sourceId
        name = $sourceName
        type = 'AzureEventHubExtended'
        properties = [ordered]@{
          dataConnectionId = $ConnectionId
          consumerGroupName = '$Default'
          startPosition = 'Latest'
        }
      }
    )
    destinations = @(
      [ordered]@{
        id = $destinationId
        name = $destinationName
        type = 'Eventhouse'
        properties = [ordered]@{
          dataIngestionMode = 'ProcessedIngestion'
          workspaceId = $WorkspaceId
          itemId = $KqlDatabaseId
          databaseName = $DatabaseName
          tableName = $TableName
          inputSerialization = @{ type = 'Json'; properties = @{ encoding = 'UTF8' } }
        }
        inputNodes = @( @{ name = $streamName } )
      }
    )
    streams = @(
      [ordered]@{
        id = $streamId
        name = $streamName
        type = 'DefaultStream'
        properties = @{}
        inputNodes = @( @{ name = $sourceName } )
      }
    )
    operators = @()
    compatibilityLevel = '1.1'
  }

  $properties = [ordered]@{
    retentionTimeInDays = 1
    eventThroughputLevel = 'Low'
  }
  $otherParts = @($definitionResponse.definition.parts | Where-Object { $_.path -notin @('eventstream.json', 'eventstreamProperties.json') })
  $requestBody = @{
    definition = @{
      parts = @(
        @{
          path = 'eventstream.json'
          payload = ConvertTo-InlineBase64 -Value ($topology | ConvertTo-Json -Depth 20)
          payloadType = 'InlineBase64'
        }
        @{
          path = 'eventstreamProperties.json'
          payload = ConvertTo-InlineBase64 -Value ($properties | ConvertTo-Json -Depth 5)
          payloadType = 'InlineBase64'
        }
      ) + $otherParts
    }
  }

  $responseHeaders = $null
  $responseStatus = $null
  try {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$fabricApi/workspaces/$WorkspaceId/eventstreams/$EventstreamId/updateDefinition" `
      -Headers $script:fabricHeaders `
      -ContentType 'application/json' `
      -Body ($requestBody | ConvertTo-Json -Depth 25) `
      -ResponseHeadersVariable responseHeaders `
      -StatusCodeVariable responseStatus | Out-Null
  } catch {
    $fabricError = $_.ErrorDetails.Message
    if ($fabricError) {
      try {
        $parsedError = $fabricError | ConvertFrom-Json
        throw "Eventstream definition was rejected: $($parsedError.errorCode): $($parsedError.message)"
      } catch {
        if ($_.Exception.Message -like 'Eventstream definition was rejected:*') { throw }
      }
    }
    throw "Eventstream definition was rejected: $($_.Exception.Message)"
  }
  if ($responseStatus -eq 202) {
    $operationId = $responseHeaders.'x-ms-operation-id' | Select-Object -First 1
    $operationUrl = if ($operationId) { "$fabricApi/operations/$operationId" } else { $responseHeaders.Location | Select-Object -First 1 }
    if ([string]::IsNullOrWhiteSpace($operationUrl)) {
      throw 'Fabric accepted the Eventstream definition but did not return an operation URL or ID. No request was retried.'
    }
    Wait-FabricOperation -OperationUrl $operationUrl -OperationId $operationId
  }
}

Write-Step 'Pinning the Azure subscription'
az account set --subscription $SubscriptionId | Out-Null
$active = az account show --query '{id:id,tenantId:tenantId,userName:user.name,userType:user.type}' -o json | ConvertFrom-Json
if ($active.id -ne $SubscriptionId) {
  throw "Subscription guardrail failed: expected '$SubscriptionId', got '$($active.id)'."
}
Write-Info "Subscription: $($active.id)"
Write-Info "Tenant: $($active.tenantId)"
Write-Info "Signed-in identity: $($active.userName) ($($active.userType))"

Write-Step 'Discovering the deployed Fabric capacity'
$armCapacity = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.Fabric/capacities `
  --query '[0].{id:id,name:name,location:location,sku:sku.name}' `
  -o json | ConvertFrom-Json
if (-not $armCapacity) {
  throw "No Microsoft Fabric capacity was found in '$ResourceGroup'. Enable the Fabric stage first."
}
if ($armCapacity.sku -ne 'F2' -or $armCapacity.location.Replace(' ', '').ToLowerInvariant() -ne 'swedencentral') {
  throw "Expected an F2 capacity in swedencentral, found '$($armCapacity.sku)' in '$($armCapacity.location)'."
}
Write-Info "Capacity: $($armCapacity.name) (F2, swedencentral)"
Write-Host '    Cost warning: indicative PAYG retail cost while active is about $0.36/hour, $8.64/day, or $262.80/month.' -ForegroundColor Yellow

$capacityDetails = az resource show `
  --ids $armCapacity.id `
  --api-version 2023-11-01 `
  --query '{state:properties.state,administrators:properties.administration.members}' `
  -o json | ConvertFrom-Json
$capacityAdministrators = @($capacityDetails.administrators)
Write-Info "Capacity state: $($capacityDetails.state)"
Write-Info "Capacity administrators: $($capacityAdministrators -join ', ')"
if (-not $Teardown -and $capacityDetails.state -ne 'Active') {
  throw "Fabric capacity '$($armCapacity.name)' is '$($capacityDetails.state)'. Resume it before setup: ./scripts/resume-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup"
}
if ($active.userType -ne 'user') {
  throw "Fabric setup requires an interactive Microsoft Entra user. Azure CLI is signed in as '$($active.userType)'."
}
if ($capacityAdministrators -notcontains $active.userName) {
  throw "Signed-in user '$($active.userName)' is not a configured Fabric capacity administrator. Redeploy with fabricAdminEmail set to this tenant user UPN, or sign in as one of: $($capacityAdministrators -join ', ')."
}

Write-Step 'Authenticating to the Fabric API'
$fabricToken = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($fabricToken)) { throw 'Could not acquire a Microsoft Fabric API token.' }
$script:fabricHeaders = @{ Authorization = "Bearer $fabricToken" }

if ($Teardown) {
  Write-Step 'Removing the Fabric workspace and contained items'
  $workspace = Get-CollectionItem -Path 'workspaces' -DisplayName $WorkspaceName
  if (-not $workspace) {
    Write-Info "Workspace '$WorkspaceName' does not exist; nothing to remove."
    return
  }
  if (-not $workspace.capacityId) {
    $workspace = Invoke-RestMethod -Method Get -Uri "$fabricApi/workspaces/$($workspace.id)" -Headers $script:fabricHeaders
  }
  $teardownCapacities = @(Get-FabricApiCollection -Path capacities | Where-Object displayName -eq $armCapacity.name)
  if ($teardownCapacities.Count -ne 1 -or $workspace.capacityId -ne $teardownCapacities[0].id) {
    throw 'Teardown workspace is not on the lab capacity; refusing to delete a shared or unrelated workspace.'
  }
  $teardownNamespace = az resource list `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroup `
    --resource-type Microsoft.EventHub/namespaces `
    --query '[0].name' `
    -o tsv
  if (-not [string]::IsNullOrWhiteSpace($teardownNamespace)) {
    $connectionName = "amlab-$teardownNamespace-diagnostics"
    $connection = Get-FabricConnection `
      -DisplayName $connectionName `
      -NamespaceName $teardownNamespace `
      -EventHubName 'diagnostics'
    if ($connection -and $connection.displayName -eq $connectionName) {
      Write-Info "Deleting Fabric connection '$($connection.displayName)' ($($connection.id))"
      Invoke-RestMethod `
        -Method Delete `
        -Uri "$fabricApi/connections/$($connection.id)" `
        -Headers $script:fabricHeaders | Out-Null
    }
  }

  $sourceWorkspaces = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
    --resource-type Microsoft.OperationalInsights/workspaces --output json | ConvertFrom-Json |
    Where-Object { $_.name -like "law-$NamePrefix-central-*" -or $_.name -like "law-$NamePrefix-appinsights-*" })
  if ($LASTEXITCODE -ne 0) { throw 'Cannot discover source Log Analytics workspaces during Fabric teardown.' }
  foreach ($sourceWorkspace in $sourceWorkspaces) {
    $customerId = az monitor log-analytics workspace show --subscription $SubscriptionId --ids $sourceWorkspace.id --query customerId --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $customerId) { throw 'Cannot resolve a mirror source during teardown.' }
    Remove-FabricMonitorAccess -WorkspaceId $workspace.id -SourceResourceId $sourceWorkspace.id -SourceCustomerId $customerId
  }

  Invoke-RestMethod `
    -Method Delete `
    -Uri "$fabricApi/workspaces/$($workspace.id)" `
    -Headers $script:fabricHeaders | Out-Null
  Write-Host "Fabric workspace '$WorkspaceName' and its contained items were deleted." -ForegroundColor Green
  return
}

$capacities = Invoke-RestMethod -Method Get -Uri "$fabricApi/capacities" -Headers $script:fabricHeaders
$fabricCapacity = @($capacities.value | Where-Object { $_.displayName -eq $armCapacity.name }) | Select-Object -First 1
if (-not $fabricCapacity) {
  throw "Fabric API did not return capacity '$($armCapacity.name)'. Confirm the tenant is Fabric-enabled and your identity is a capacity administrator."
}

Write-Step 'Creating or reusing the Fabric workspace'
$workspace = Ensure-FabricItem `
  -CollectionPath 'workspaces' `
  -DisplayName $WorkspaceName `
  -CreateBody @{
    displayName = $WorkspaceName
    description = 'Real-Time Intelligence scenarios for the Azure Monitor Demo Lab.'
    capacityId = $fabricCapacity.id
  }
if (-not $workspace.capacityId) {
  $workspace = Invoke-RestMethod -Method Get -Uri "$fabricApi/workspaces/$($workspace.id)" -Headers $script:fabricHeaders
}
if ($workspace.capacityId -ne $fabricCapacity.id) {
  throw "Existing workspace '$WorkspaceName' is not assigned to this lab's capacity. Choose a unique WorkspaceName; setup will not move a shared workspace or schedule suspension against another capacity."
}

Write-Step 'Creating or reusing Real-Time Intelligence items'
$eventhouse = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventhouses" `
  -DisplayName $EventhouseName `
  -CreateBody @{
    displayName = $EventhouseName
    description = 'Eventhouse for operational and business event correlation.'
  }

$kqlDatabase = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/kqlDatabases" `
  -DisplayName $KqlDatabaseName `
  -CreateBody @{
    displayName = $KqlDatabaseName
    description = 'Read-write KQL database for streamed lab telemetry.'
    creationPayload = @{
      databaseType = 'ReadWrite'
      parentEventhouseItemId = $eventhouse.id
    }
  }

$eventstream = Ensure-FabricItem `
  -CollectionPath "workspaces/$($workspace.id)/eventstreams" `
  -DisplayName $EventstreamName `
  -CreateBody @{
    displayName = $EventstreamName
    description = 'Eventstream for the Azure Event Hubs diagnostics source and Eventhouse destination.'
  }

Write-Step 'Resolving the Azure Event Hub source'
$eventHubNamespace = az resource list `
  --subscription $SubscriptionId `
  --resource-group $ResourceGroup `
  --resource-type Microsoft.EventHub/namespaces `
  --query '[0].name' `
  -o tsv
if ([string]::IsNullOrWhiteSpace($eventHubNamespace)) {
  Write-Host '    No Event Hubs namespace was found. Deploy Stage A before configuring the Eventstream source.' -ForegroundColor Yellow
} else {
  Write-Info "Namespace: $eventHubNamespace"
  Write-Info 'Event Hub: diagnostics'
  Write-Info 'Authentication: workspace identity; receiver access scoped to this event hub.'
}

$eventstreamAutomated = $false
$setupResults = [Collections.Generic.List[object]]::new()
if (-not $SkipEventstreamConnection -and -not [string]::IsNullOrWhiteSpace($eventHubNamespace)) {
  Write-Step 'Connecting the Fabric Eventstream automatically'
  try {
    $eventHubConnection = Ensure-EventHubConnection `
      -NamespaceName $eventHubNamespace `
      -EventHubName 'diagnostics' -WorkspaceId $workspace.id
    Set-EventstreamTopology `
      -WorkspaceId $workspace.id `
      -EventstreamId $eventstream.id `
      -ConnectionId $eventHubConnection.id `
      -KqlDatabaseId $kqlDatabase.id `
      -DatabaseName $KqlDatabaseName `
      -TableName $DestinationTableName
    $eventstreamAutomated = $true
    Write-Host "Eventstream source and Eventhouse destination configured." -ForegroundColor Green
    $setupResults.Add([pscustomobject]@{ Feature = 'Eventstream topology'; Status = 'Configured'; Detail = 'Event Hub -> Eventstream -> Eventhouse. Data delivery is verified separately.' })
  } catch {
    $connectionAction = 'Verify workspace-admin and event-hub-scoped RBAC assignment permissions, then rerun. Keep shared keys disabled; WorkspaceIdentity requires the Extended Event Hubs source.'
    $setupResults.Add([pscustomobject]@{
      Feature = 'Eventstream topology'; Status = 'ActionRequired'
      Detail = "$($_.Exception.Message) $connectionAction"
    })
  }
} else {
  $setupResults.Add([pscustomobject]@{
    Feature = 'Eventstream topology'; Status = 'ActionRequired'
    Detail = 'Connection automation was skipped or Stage A Event Hubs is absent. Configure the stream and generate traffic before verifying ingestion.'
  })
}

Write-Step 'Configuring the Fabric suspension schedule'
try {
  & (Join-Path $PSScriptRoot 'setup-fabric-auto-suspend.ps1') -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -Enabled $EnableAutoSuspend -HourUtc $AutoSuspendHourUtc -MinuteUtc $AutoSuspendMinuteUtc
  $setupResults.Add([pscustomobject]@{
    Feature = 'Daily auto-suspension'; Status = 'Configured'
    Detail = $(if ($EnableAutoSuspend) { "Daily $($AutoSuspendHourUtc.ToString('00')):$($AutoSuspendMinuteUtc.ToString('00')) UTC. Interrupts queries and ingestion." } else { 'Disabled; no automatic capacity state changes.' })
  })
} catch {
  $setupResults.Add([pscustomobject]@{ Feature = 'Daily auto-suspension'; Status = 'Failed'; Detail = $_.Exception.Message })
}

Write-Step 'Creating and verifying the observability experience'
try {
  $databaseDetails = Invoke-RestMethod -Method Get `
    -Uri "$fabricApi/workspaces/$($workspace.id)/kqlDatabases/$($kqlDatabase.id)" -Headers $script:fabricHeaders
  $queryServiceUri = $databaseDetails.properties.queryServiceUri
  if ([string]::IsNullOrWhiteSpace($queryServiceUri)) { throw 'Fabric has not returned the KQL database queryServiceUri. Rerun setup once the database is ready.' }
  $samplesReady = $false
  if ($SeedSampleData) {
    try {
      Initialize-FabricSampleData -QueryServiceUri $queryServiceUri -DatabaseName $KqlDatabaseName
      $samplesReady = $true
      $setupResults.Add([pscustomobject]@{ Feature = 'Business correlation'; Status = 'Verified'; Detail = 'Four deduplicated SYNTHETIC sample events in LabSampleEvents. No real orders or customer data were created.' })
    } catch {
      $setupResults.Add([pscustomobject]@{ Feature = 'Business correlation'; Status = 'Failed'; Detail = $_.Exception.Message })
    }
  } else {
    $setupResults.Add([pscustomobject]@{ Feature = 'Business correlation'; Status = 'Skipped'; Detail = 'Synthetic sample seeding is disabled.' })
  }
  try {
    $dashboardDefinition = New-FabricDashboardDefinition -WorkspaceId $workspace.id -QueryServiceUri $queryServiceUri `
      -DatabaseId $kqlDatabase.id -DatabaseName $KqlDatabaseName -TableName $DestinationTableName -IncludeSampleData $samplesReady
    $dashboard = Ensure-FabricItem -CollectionPath "workspaces/$($workspace.id)/kqlDashboards" `
      -DisplayName 'Azure Monitor Demo Live Health' -CreateBody @{
        displayName = 'Azure Monitor Demo Live Health'
        description = 'Live ingestion and raw diagnostics, with separately labelled synthetic business correlation.'
        definition = @{ parts = @(@{
          path = 'RealTimeDashboard.json'
          payload = ConvertTo-InlineBase64 -Value ($dashboardDefinition | ConvertTo-Json -Depth 15)
          payloadType = 'InlineBase64'
        }) }
      }
    $setupResults.Add([pscustomobject]@{ Feature = 'Real-Time Dashboard'; Status = 'Configured'; Detail = "Dashboard $($dashboard.id) created/reused. Existing dashboard edits are preserved; live tiles are empty until telemetry arrives." })
  } catch {
    $setupResults.Add([pscustomobject]@{ Feature = 'Real-Time Dashboard'; Status = 'Failed'; Detail = $_.Exception.Message })
  }
  if ($eventstreamAutomated) {
    $setupResults.Add((Wait-FabricTelemetry -WorkspaceId $workspace.id -EventstreamId $eventstream.id `
      -QueryServiceUri $queryServiceUri -DatabaseName $KqlDatabaseName -TableName $DestinationTableName -TimeoutSeconds $VerificationTimeoutSeconds))
  } else {
    $setupResults.Add([pscustomobject]@{ Feature = 'Live ingestion'; Status = 'Pending'; Detail = 'Stream connection is incomplete. Synthetic samples do not count as live ingestion verification.' })
  }
} catch {
  $setupResults.Add([pscustomobject]@{ Feature = 'Observability experience'; Status = 'Failed'; Detail = $_.Exception.Message })
}

if ($EnableMirroring) {
  Write-Step 'Configuring Azure Monitor mirroring (preview)'
  $mirroredSources = [Collections.Generic.List[object]]::new()
  foreach ($source in @(
    @{ Kind = 'central'; Name = 'Azure Monitor Demo Mirrored Logs'; ConnectionId = $MirrorConnectionId; Tables = $MirrorTables; Scope = $MirrorScope },
    @{ Kind = 'appinsights'; Name = 'Azure Monitor Demo Mirrored App Insights'; ConnectionId = $AppInsightsMirrorConnectionId; Tables = $AppInsightsMirrorTables; Scope = @() }
  )) {
    try {
      $sourceWorkspaces = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
        --resource-type Microsoft.OperationalInsights/workspaces --output json | ConvertFrom-Json |
        Where-Object { $_.name -like "law-$NamePrefix-$($source.Kind)-*" })
      if ($LASTEXITCODE -ne 0 -or $sourceWorkspaces.Count -ne 1) { throw "Cannot uniquely discover the $($source.Kind) Log Analytics workspace." }
      $customerId = az monitor log-analytics workspace show --subscription $SubscriptionId --ids $sourceWorkspaces[0].id --query customerId --output tsv
      if ($LASTEXITCODE -ne 0 -or -not $customerId) { throw 'Cannot read the Log Analytics workspace customer GUID.' }
      $connection = Ensure-FabricMonitorConnection -WorkspaceId $workspace.id -SourceResourceId $sourceWorkspaces[0].id `
        -SourceCustomerId $customerId -ConnectionId $source.ConnectionId
      $mirror = Initialize-FabricMirror -WorkspaceId $workspace.id -SourceCustomerId $customerId `
        -DisplayName $source.Name -ConnectionId $connection.id -Scope $source.Scope -Tables $source.Tables
      $setupResults.Add($mirror)
      if ($mirror.MirrorId) {
        $mirroredSources.Add(@{ Mirror = $mirror; ApplicationInsights = ($source.Kind -eq 'appinsights') })
      }
    } catch {
      $setupResults.Add([pscustomobject]@{ Feature = "Azure Monitor mirroring ($($source.Kind))"; Status = 'Failed'; Detail = $_.Exception.Message })
    }
  }
  foreach ($mirroredSource in $mirroredSources) {
    try {
      $dashboardResult = Initialize-FabricMirroredDashboard -WorkspaceId $workspace.id -Mirror $mirroredSource.Mirror `
        -ApplicationInsights:$mirroredSource.ApplicationInsights
      $setupResults.Add($dashboardResult)
      if ($dashboardResult.Status -eq 'Verified') {
        $mirroredSource.Mirror.Status = 'Verified'
        $mirroredSource.Mirror.Detail = "Mirrored item $($mirroredSource.Mirror.MirrorId): external tables and visible data verified through its dashboard queries."
      }
    } catch {
      $setupResults.Add([pscustomobject]@{ Feature = "Mirrored dashboard ($($mirroredSource.Mirror.DisplayName))"; Status = 'Failed'; Detail = $_.Exception.Message })
    }
  }
} else {
  $setupResults.Add([pscustomobject]@{ Feature = 'Azure Monitor mirroring'; Status = 'Skipped'; Detail = 'Disabled explicitly. Preview source protections do not carry into Fabric; review workspace access before enabling.' })
}
$setupResults.Add([pscustomobject]@{
  Feature = 'Capacity Metrics app'; Status = 'ActionRequired'
  Detail = 'If not installed, install Capacity Metrics once using a capacity admin with Power BI Pro/PPU/trial: https://learn.microsoft.com/fabric/enterprise/metrics-app-install . No documented public installation API; setup cannot verify installation.'
})

Write-Host "Workspace: https://app.fabric.microsoft.com/groups/$($workspace.id)"
Write-Host "Eventhouse ID: $($eventhouse.id)"
Write-Host "KQL database ID: $($kqlDatabase.id)"
Write-Host "Eventstream ID: $($eventstream.id)"
if (-not $eventstreamAutomated) {
  Write-Host "`nManual Eventstream connection:" -ForegroundColor Cyan
  Write-Host "1. Resolve the reported workspace identity/RBAC/API error and rerun setup."
  Write-Host "2. For a manual source, select Azure Event Hubs with Extended features and Workspace identity, namespace '$eventHubNamespace', event hub 'diagnostics', consumer group '`$Default'."
  Write-Host "3. Connect it to the '$KqlDatabaseName' Eventhouse database and '$DestinationTableName' table, then publish. Basic AzureEventHub does not support WorkspaceIdentity."
  Write-Host "4. Keep local/shared-key authentication disabled. Use -SkipEventstreamConnection to preserve manual topology on rerun."
}
Write-Host "`nNext steps: docs/STAGE-FABRIC.md#after-deployps1-checklist" -ForegroundColor Cyan
Write-Host "Check the results below, open the dashboard and Azure health views, and suspend F2 when finished."
Write-Host "`nSuspend F2 when idle: ./scripts/suspend-fabric.ps1 -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup" -ForegroundColor Yellow
Write-FabricSetupSummary -Results $setupResults.ToArray()