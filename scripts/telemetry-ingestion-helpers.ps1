$ErrorActionPreference = 'Stop'

function Assert-TelemetryIngestionCommand {
  param([string] $Operation)
  if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
}

function Get-TelemetryIngestionAzJson {
  param([string[]] $Arguments, [string] $Operation)
  $result = & az @Arguments
  Assert-TelemetryIngestionCommand $Operation
  if ([string]::IsNullOrWhiteSpace(($result -join ''))) { throw "$Operation returned no data." }
  $result | ConvertFrom-Json -NoEnumerate
}

function Assert-TelemetryIngestionTarget {
  param([string] $SubscriptionId)
  $parsedSubscription = [guid]::Empty
  if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$parsedSubscription) -or
      $parsedSubscription -eq [guid]::Empty) {
    throw 'SubscriptionId must be a GUID.'
  }
  $account = Get-TelemetryIngestionAzJson @('account', 'show', '--subscription', $SubscriptionId, '-o', 'json') 'Reading the selected Azure account'
  if ($account.id -ine $SubscriptionId) { throw 'The selected Azure account does not match SubscriptionId.' }
  $targetPath = Join-Path $PSScriptRoot '..' '.azure-target.json'
  if (Test-Path -LiteralPath $targetPath) {
    $target = Get-Content -LiteralPath $targetPath -Raw | ConvertFrom-Json
    if ($target.expectedSubscriptionId -ine $account.id -or $target.expectedTenantId -ine $account.tenantId) {
      throw 'The selected Azure account does not match .azure-target.json.'
    }
  }
  $account
}

function New-TelemetryIngestionFixture {
  param([Parameter(Mandatory)] [guid] $RunId)
  for ($index = 1; $index -le 100; $index++) {
    $severity = if ($index -le 20) { 'Error' } elseif ($index -le 50) { 'Warning' } else { 'Debug' }
    [pscustomobject][ordered]@{
      TimeGenerated = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ', [Globalization.CultureInfo]::InvariantCulture)
      RunId = $RunId.ToString('D')
      EventId = 'event-{0:D3}' -f $index
      SampleSetId = 'telemetry-ingestion-v1'
      Severity = $severity
      Workload = 'ingestion-demo'
      Message = "Synthetic $severity event $index"
      SyntheticUser = 'demo.user@example.invalid'
      DebugField = "disposable-$index"
    }
  }
}

function Get-TelemetryIngestionExpectedIds {
  param(
    [ValidateSet('Baseline', 'Transformed', 'Tiered', 'EdgeFanout', 'EdgeTiered')]
    [string] $Profile,
    [ValidateSet('Operational', 'Diagnostic', 'Verbose')]
    [string] $Destination
  )
  switch ($Profile) {
    'Baseline' {
      if ($Destination -eq 'Verbose') { throw 'Baseline has no Verbose destination.' }
      $indices = 1..100
    }
    'Transformed' {
      if ($Destination -eq 'Verbose') { throw 'Transformed has no Verbose destination.' }
      $indices = 1..50
    }
    'Tiered' {
      $indices = if ($Destination -eq 'Verbose') { 51..100 } elseif ($Destination -eq 'Operational') { 1..50 } else { throw 'Tiered has no Diagnostic destination.' }
    }
    'EdgeFanout' {
      if ($Destination -eq 'Verbose') { throw 'EdgeFanout has no Verbose destination.' }
      $indices = if ($Destination -eq 'Operational') { 1..50 } else { 1..60 }
    }
    'EdgeTiered' {
      $indices = if ($Destination -eq 'Verbose') { 51..60 } elseif ($Destination -eq 'Operational') { 1..50 } else { throw 'EdgeTiered has no Diagnostic destination.' }
    }
  }
  @($indices | ForEach-Object { 'event-{0:D3}' -f $_ })
}

function Get-TelemetryIngestionDestinations {
  param([ValidateSet('Baseline', 'Transformed', 'Tiered', 'EdgeFanout', 'EdgeTiered')] [string] $Profile)
  if ($Profile -in @('Tiered', 'EdgeTiered')) { return @('Operational', 'Verbose') }
  @('Operational', 'Diagnostic')
}

function Get-TelemetryIngestionRoute {
  param([ValidateSet('Baseline', 'Transformed', 'Tiered')] [string] $Profile, [string] $NamePrefix)
  $name = "dcr-$NamePrefix-telemetry-ingestion"
  if ($Profile -eq 'Baseline') { $name += '-baseline' }
  if ($Profile -eq 'Tiered') { $name += '-tiered' }
  $name
}

function Get-TelemetryIngestionDcr {
  param([string] $SubscriptionId, [string] $ResourceGroup, [string] $NamePrefix, [string] $Profile)
  $name = Get-TelemetryIngestionRoute -Profile $Profile -NamePrefix $NamePrefix
  $dcr = Get-TelemetryIngestionAzJson @(
    'resource', 'show', '--subscription', $SubscriptionId, '-g', $ResourceGroup,
    '-n', $name, '--resource-type', 'Microsoft.Insights/dataCollectionRules',
    '--api-version', '2023-03-11', '-o', 'json'
  ) "Reading DCR $name"
  if ($dcr.name -ne $name -or -not $dcr.properties.immutableId -or
      -not $dcr.properties.streamDeclarations.'Custom-TelemetryIngestion') {
    throw "DCR $name is not configured for the telemetry ingestion fixture."
  }
  $dcr
}

function Get-TelemetryIngestionDce {
  param([string] $SubscriptionId, [string] $ResourceGroup, [string] $NamePrefix)
  $name = "dce-$NamePrefix-telemetry-ingestion"
  $dce = Get-TelemetryIngestionAzJson @(
    'resource', 'show', '--subscription', $SubscriptionId, '-g', $ResourceGroup,
    '-n', $name, '--resource-type', 'Microsoft.Insights/dataCollectionEndpoints',
    '--api-version', '2023-03-11', '-o', 'json'
  ) "Reading DCE $name"
  if ($dce.name -ne $name -or $dce.properties.logsIngestion.endpoint -notmatch '^https://') {
    throw "DCE $name has no logs ingestion endpoint."
  }
  $dce
}

function Get-TelemetryIngestionToken {
  param([string] $SubscriptionId, [string] $Resource)
  $response = Get-TelemetryIngestionAzJson @(
    'account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', $Resource, '-o', 'json'
  ) "Acquiring a token for $Resource"
  if (-not $response.accessToken) { throw "No token was returned for $Resource." }
  $response.accessToken
}

function Assert-TelemetryIngestionRows {
  param(
    [object[]] $Rows,
    [string[]] $ExpectedIds,
    [string] $RunId,
    [string] $Destination,
    [string] $Profile
  )
  $ids = @($Rows | ForEach-Object { $_.EventId })
  $missing = @($ExpectedIds | Where-Object { $_ -notin $ids })
  $unexpected = @($ids | Where-Object { $_ -notin $ExpectedIds } | Select-Object -Unique)
  $duplicates = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  $badSchema = @($Rows | Where-Object {
    $_.RunId -ne $RunId -or $_.SampleSetId -ne 'telemetry-ingestion-v1' -or
    $_.Severity -notin @('Error', 'Warning', 'Debug') -or -not $_.TimeGenerated -or
    $_.Workload -cne 'ingestion-demo' -or -not ([string]$_.EventId -match '^event-(\d{3})$') -or
    $_.Message -cne ('Synthetic {0} event {1}' -f $_.Severity, [int]$Matches[1])
  })
  $expectedUser = if ($Profile -eq 'Baseline') { 'demo.user@example.invalid' } else { '[REDACTED]' }
  $badRedaction = @($Rows | Where-Object {
    $_.SyntheticUser -cne $expectedUser -or
    -not [string]::IsNullOrEmpty([string]$_.DebugField)
  })
  $badNormalization = @($Rows | Where-Object {
    $_.NormalizedSeverity -cne $(if ($Profile -eq 'Baseline') { $_.Severity } else { ([string]$_.Severity).ToLowerInvariant() })
  })
  [pscustomobject]@{
    Destination = $Destination
    Expected = $ExpectedIds.Count
    Observed = $Rows.Count
    MissingIds = $missing
    UnexpectedIds = $unexpected
    DuplicateIds = $duplicates
    SchemaFailures = $badSchema.Count
    RedactionFailures = $badRedaction.Count
    NormalizationFailures = $badNormalization.Count
    Passed = $missing.Count -eq 0 -and $unexpected.Count -eq 0 -and
      $duplicates.Count -eq 0 -and $badSchema.Count -eq 0 -and
      $badRedaction.Count -eq 0 -and $badNormalization.Count -eq 0 -and
      $Rows.Count -eq $ExpectedIds.Count
  }
}
