$ErrorActionPreference = 'Stop'
$helpers = Join-Path $PSScriptRoot '..\telemetry-ingestion-helpers.ps1'
. $helpers

function Assert-Throws {
  param([scriptblock] $Action, [string] $Message)
  $threw = $false
  try { & $Action | Out-Null } catch {
    if ($_.Exception.Message -notmatch $Message) { throw }
    $threw = $true
  }
  if (-not $threw) { throw "Expected failure containing '$Message'." }
}

$run = [guid]::NewGuid()
$events = @(New-TelemetryIngestionFixture -RunId $run)
if ($events.Count -ne 100 -or
    @($events | Where-Object Severity -EQ 'Error').Count -ne 20 -or
    @($events | Where-Object Severity -EQ 'Warning').Count -ne 30 -or
    @($events | Where-Object Severity -EQ 'Debug').Count -ne 50 -or
    @($events | Where-Object { $_.TimeGenerated -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$' }).Count -ne 0 -or
    @($events | Select-Object -ExpandProperty EventId -Unique).Count -ne 100) {
  throw 'Fixture must have 100 unique IDs, microsecond UTC timestamps, and a 20/30/50 severity split.'
}
foreach ($profile in @('Baseline', 'Transformed', 'Tiered', 'EdgeFanout', 'EdgeTiered')) {
  $counts = @(Get-TelemetryIngestionDestinations -Profile $profile | ForEach-Object {
    @(Get-TelemetryIngestionExpectedIds -Profile $profile -Destination $_).Count
  })
  $expected = switch ($profile) {
    'Baseline' { @(100, 100) }
    'Transformed' { @(50, 50) }
    'Tiered' { @(50, 50) }
    'EdgeFanout' { @(50, 60) }
    'EdgeTiered' { @(50, 10) }
  }
  if (Compare-Object $expected $counts) { throw "Unexpected event-set counts for $profile." }
}
Assert-Throws { Get-TelemetryIngestionExpectedIds -Profile Tiered -Destination Diagnostic } 'no Diagnostic'

$rows = @(1..50 | ForEach-Object {
  [pscustomobject]@{
    TimeGenerated = [datetime]::UtcNow
    RunId = $run.ToString('D')
    EventId = 'event-{0:D3}' -f $_
    SampleSetId = 'telemetry-ingestion-v1'
    Severity = if ($_ -le 20) { 'Error' } else { 'Warning' }
    Workload = 'ingestion-demo'
    Message = "Synthetic $(if ($_ -le 20) { 'Error' } else { 'Warning' }) event $_"
    SyntheticUser = '[REDACTED]'
    DebugField = ''
    NormalizedSeverity = if ($_ -le 20) { 'error' } else { 'warning' }
  }
})
$expectedIds = @(Get-TelemetryIngestionExpectedIds -Profile Transformed -Destination Operational)
if (-not (Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed).Passed) {
  throw 'Valid transformed rows did not pass.'
}
$baselineRows = @($events | ForEach-Object {
  [pscustomobject]@{
    TimeGenerated = $_.TimeGenerated
    RunId = $_.RunId
    EventId = $_.EventId
    SampleSetId = $_.SampleSetId
    Severity = $_.Severity
    Workload = $_.Workload
    Message = $_.Message
    SyntheticUser = $_.SyntheticUser
    NormalizedSeverity = $_.Severity
    DebugField = ''
  }
})
$baselineIds = @(Get-TelemetryIngestionExpectedIds -Profile Baseline -Destination Operational)
if (-not (Assert-TelemetryIngestionRows -Rows $baselineRows -ExpectedIds $baselineIds -RunId $run.ToString('D') -Destination Operational -Profile Baseline).Passed) {
  throw 'Valid untransformed baseline rows did not pass.'
}
$baselineRows[0].SyntheticUser = '[REDACTED]'
if ((Assert-TelemetryIngestionRows -Rows $baselineRows -ExpectedIds $baselineIds -RunId $run.ToString('D') -Destination Operational -Profile Baseline).Passed) {
  throw 'Masked baseline was accepted as an untransformed record.'
}
$rows[0].SyntheticUser = 'demo.user@example.invalid'
if ((Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed).Passed) {
  throw 'Sensitive unmasked value was accepted.'
}
$rows[0].SyntheticUser = '[REDACTED]'
$rows[0].NormalizedSeverity = 'Error'
if ((Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed).Passed) {
  throw 'Incorrect severity normalization was accepted.'
}
$rows[0].NormalizedSeverity = 'error'
$rows[0].SyntheticUser = 'masked'
if ((Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed).Passed) {
  throw 'Unexpected masking value was accepted.'
}
$rows[0].SyntheticUser = '[REDACTED]'
$rows[1].EventId = $rows[0].EventId
$duplicate = Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed
if ($duplicate.Passed -or $duplicate.DuplicateIds.Count -ne 1 -or $duplicate.MissingIds.Count -ne 1) {
  throw 'Duplicate and missing IDs were not reported together.'
}
$rows[1].EventId = 'event-002'
$rows[2].EventId = 'event-061'
if ((Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expectedIds -RunId $run.ToString('D') -Destination Operational -Profile Transformed).Passed) {
  throw 'A filtered-out Debug ID was accepted.'
}

Write-Output 'PASS: deterministic fixture, profile event sets, redaction, filtered IDs, and duplicate/missing validation.'

$subscription = '00000000-0000-0000-0000-000000000001'
$global:uploadAttempts = 0
$global:uploadStatus = 204
$global:uploadedBytes = $null
function az {
  $command = $args -join ' '
  $global:LASTEXITCODE = 0
  if ($command -match '^account show ') {
    return (@{ id = $subscription; tenantId = '00000000-0000-0000-0000-000000000002' } | ConvertTo-Json -Compress)
  }
  if ($command -match '^account get-access-token ') {
    return '{"accessToken":"fake-test-token"}'
  }
  if ($command -match '^monitor log-analytics workspace list ') {
    return '[{"name":"law-demo-central-test","customerId":"00000000-0000-0000-0000-000000000003"}]'
  }
  if ($command -match '^resource show ' -and $command -match 'dataCollectionRules') {
    return (@{
      name = 'dcr-demo-telemetry-ingestion'
      id = '/test/dcr'
      properties = @{ immutableId = 'dcr-test'; streamDeclarations = @{ 'Custom-TelemetryIngestion' = @{ columns = @() } } }
    } | ConvertTo-Json -Depth 7 -Compress)
  }
  if ($command -match '^resource show ' -and $command -match 'dataCollectionEndpoints') {
    return (@{
      name = 'dce-demo-telemetry-ingestion'
      id = '/test/dce'
      properties = @{ logsIngestion = @{ endpoint = 'https://test.ingest.monitor.azure.com' } }
    } | ConvertTo-Json -Depth 5 -Compress)
  }
  throw "Unexpected Azure command: $command"
}
function Invoke-WebRequest {
  param($Method, $Uri, $Headers, $ContentType, $Body, [switch]$SkipHttpErrorCheck, $TimeoutSec)
  if ($Headers.Authorization -ne 'Bearer fake-test-token' -or
      $Uri -notmatch '/streams/Custom-TelemetryIngestion\?api-version=2023-01-01$' -or
      $ContentType -notmatch 'application/json' -or $Body -isnot [byte[]]) {
    throw 'Upload did not use the expected authenticated UTF-8 request.'
  }
  $global:uploadAttempts++
  $global:uploadedBytes = $Body
  [pscustomobject]@{ StatusCode = $global:uploadStatus; Content = 'synthetic failure'; Headers = @{} }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "telemetry-ingestion-test-$([guid]::NewGuid().ToString('N'))"
try {
  $testScripts = New-Item -ItemType Directory -Path (Join-Path $testRoot 'scripts')
  foreach ($name in @('send-telemetry-ingestion.ps1', 'test-telemetry-ingestion.ps1', 'telemetry-ingestion-helpers.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\$name") -Destination $testScripts.FullName
  }
  @{ expectedSubscriptionId = $subscription; expectedTenantId = '00000000-0000-0000-0000-000000000002' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testRoot '.azure-target.json')
  $sender = Join-Path $testScripts.FullName 'send-telemetry-ingestion.ps1'
  $runId = [guid]::NewGuid()
  Assert-Throws {
    & $sender -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo -RunId ([guid]::Empty) -SkipVerification
  } 'RunId must not be the empty GUID'
  Assert-Throws {
    & (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
      -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo -RunId ([guid]::Empty)
  } 'RunId must not be the empty GUID'
  $result = & $sender -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo -RunId $runId -SkipVerification
  if (-not $result.Accepted -or $result.Verified -or $result.Requests -ne 1 -or $result.Generated -ne 100) {
    throw 'Sender did not report upload acceptance separately from destination verification.'
  }
  $payload = [Text.Encoding]::UTF8.GetString($global:uploadedBytes) | ConvertFrom-Json
  if (@($payload).Count -ne 100 -or $payload[0].RunId -ne $runId.ToString('D') -or
      $payload[99].EventId -ne 'event-100') {
    throw 'Sender did not upload the deterministic 100-record fixture.'
  }
  $global:uploadStatus = 403
  Assert-Throws {
    & $sender -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo -SkipVerification
  } 'HTTP 403 after 1 attempt'
  if ($global:uploadAttempts -ne 2) { throw 'A nonretryable 403 was retried.' }
  function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec)
    if ($Uri -notmatch '/(query|search)\?timespan=PT2H$' -or
        $Headers.Authorization -ne 'Bearer fake-test-token') { throw 'Validation must query the correct authenticated endpoint.' }
    $path = $Matches[1]
    $query = $Body | ConvertFrom-Json
    if ($query.query -notmatch "where RunId == '$runId'") { throw 'Validation must filter the current run.' }
    if ($query.query -match 'TelemetryIngestionVerbose_CL') {
      if ($path -ne 'search') { throw 'Auxiliary validation must use the search endpoint.' }
      $indices = 51..100
    } else {
      if ($path -ne 'query') { throw 'Analytics validation must use the query endpoint.' }
      $indices = if ($global:mockBaseline) { 1..100 }
        elseif ($global:mockEdgeFanout -and $query.query -match 'TelemetryIngestionDiagnostic_CL') { 1..60 }
        else { 1..50 }
    }
    if ($global:queryFailureTarget -and $query.query -match $global:queryFailureTarget) {
      throw 'Synthetic workspace query denial'
    }
    $columns = @('TimeGenerated', 'RunId', 'EventId', 'SampleSetId', 'Severity', 'Workload', 'Message', 'SyntheticUser', 'DebugField', 'NormalizedSeverity')
    $data = @()
    foreach ($number in $indices) {
      $data += ,@([datetime]::UtcNow.ToString('o'), $runId.ToString('D'),
        ('event-{0:D3}' -f $number), 'telemetry-ingestion-v1',
        $(if ($number -le 20) { 'Error' } elseif ($number -le 50) { 'Warning' } else { 'Debug' }),
        'ingestion-demo', "Synthetic $(if ($number -le 20) { 'Error' } elseif ($number -le 50) { 'Warning' } else { 'Debug' }) event $number",
        $(if ($global:mockBaseline) { 'demo.user@example.invalid' } else { '[REDACTED]' }), '',
        $(if ($global:mockBaseline) { if ($number -le 20) { 'Error' } elseif ($number -le 50) { 'Warning' } else { 'Debug' } }
          elseif ($number -le 20) { 'error' } elseif ($number -le 50) { 'warning' } else { 'debug' }))
    }
    [pscustomobject]@{ tables = @([pscustomobject]@{
      columns = @($columns | ForEach-Object { [pscustomobject]@{ name = $_ } })
      rows = $data
    }) }
  }
  $validation = @(& (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
    -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo `
    -RunId $runId -TimeoutSeconds 1)
  if ($validation.Count -ne 2 -or @($validation | Where-Object { -not $_.Passed }).Count -ne 0) {
    throw 'Per-destination analytics queries did not verify both tables.'
  }
  $global:mockBaseline = $true
  $baseline = @(& (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
    -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo `
    -RunId $runId -Profile Baseline -TimeoutSeconds 1)
  if ($baseline.Count -ne 2 -or @($baseline | Where-Object { -not $_.Passed }).Count -ne 0 -or
      @($baseline | Where-Object Destination -EQ 'Diagnostic')[0].Expected -ne 100) {
    throw 'Baseline must independently verify 100 untransformed records in each table.'
  }
  $global:mockBaseline = $false
  $tiered = @(& (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
    -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo `
    -RunId $runId -Profile Tiered -TimeoutSeconds 1)
  if ($tiered.Count -ne 2 -or @($tiered | Where-Object { -not $_.Passed }).Count -ne 0 -or
      @($tiered | Where-Object Destination -EQ 'Verbose')[0].Expected -ne 50) {
    throw 'Analytics and Auxiliary destinations were not validated independently.'
  }
  $global:mockEdgeFanout = $true
  $edge = @(& (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
    -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo `
    -RunId $runId -Profile EdgeFanout -TimeoutSeconds 1)
  if ($edge.Count -ne 2 -or @($edge | Where-Object { -not $_.Passed }).Count -ne 0 -or
      @($edge | Where-Object Destination -EQ 'Operational')[0].Expected -ne 50 -or
      @($edge | Where-Object Destination -EQ 'Diagnostic')[0].Expected -ne 60) {
    throw 'Edge fan-out must independently verify 50 Operational and 60 Diagnostic IDs.'
  }
  $global:mockEdgeFanout = $false
  $global:queryFailureTarget = 'TelemetryIngestionDiagnostic_CL'
  Assert-Throws {
    & (Join-Path $testScripts.FullName 'test-telemetry-ingestion.ps1') `
      -SubscriptionId $subscription -ResourceGroup 'test-rg' -NamePrefix demo `
      -RunId $runId -Profile Transformed -TimeoutSeconds 1
  } 'Querying TelemetryIngestionDiagnostic_CL.*Synthetic workspace query denial'
} finally {
  if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
Write-Output 'PASS: sender accepts exactly one bounded UTF-8 upload and rejects a denied upload without retry.'
