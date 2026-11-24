<#
.SYNOPSIS
  Validate a single synthetic telemetry run against each intended destination.
.DESCRIPTION
  Polls by RunId and checks exact event IDs, duplicates, schema, and redaction.
  Analytics tables use /query; Auxiliary uses workspace-scoped /search.
  Does not send telemetry or provision resources.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9._()-]+$')] [string] $ResourceGroup,
  [ValidatePattern('^[a-z0-9]{3,8}$')] [string] $NamePrefix = 'amlab',
  [ValidateSet('Baseline', 'Transformed', 'Tiered', 'EdgeFanout')] [string] $Profile = 'Transformed',
  [Parameter(Mandatory)] [guid] $RunId,
  [ValidateRange(1, 1800)] [int] $TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'telemetry-ingestion-helpers.ps1')

if ($RunId -eq [guid]::Empty) { throw 'RunId must not be the empty GUID.' }
$subscription = $SubscriptionId.ToString('D')
$null = Assert-TelemetryIngestionTarget -SubscriptionId $subscription
$workspaces = @(Get-TelemetryIngestionAzJson @(
  'monitor', 'log-analytics', 'workspace', 'list', '--subscription', $subscription,
  '-g', $ResourceGroup, '-o', 'json'
) 'Listing lab Log Analytics workspaces')
$central = @($workspaces | Where-Object { $_.name -like "law-$NamePrefix-central-*" })
if ($central.Count -ne 1 -or -not $central[0].customerId) {
  throw "Expected one central workspace matching law-$NamePrefix-central-* in $ResourceGroup."
}
$workspace = $central[0]
$token = Get-TelemetryIngestionToken -SubscriptionId $subscription -Resource 'https://api.loganalytics.io/'
$destinations = @(Get-TelemetryIngestionDestinations -Profile $Profile)
$results = @{}
$deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
$run = $RunId.ToString('D')

do {
  foreach ($destination in $destinations) {
    $table = "TelemetryIngestion${destination}_CL"
    $expected = @(Get-TelemetryIngestionExpectedIds -Profile $Profile -Destination $destination)
    $query = "$table | where RunId == '$run' | project TimeGenerated, RunId, EventId, SampleSetId, Severity, Workload, Message, SyntheticUser, DebugField=column_ifexists('DebugField', ''), NormalizedSeverity"
    $path = if ($destination -eq 'Verbose') { 'search' } else { 'query' }
    $uri = "https://api.loganalytics.io/v1/workspaces/$($workspace.customerId)/$path`?timespan=PT2H"
    $body = @{ query = $query } | ConvertTo-Json -Compress
    try {
      $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ Authorization = "Bearer $token" } `
        -ContentType 'application/json' -Body $body -TimeoutSec 30
    } catch {
      throw "Querying $table in workspace $($workspace.name) failed: $($_.Exception.Message)"
    }
    if (-not $response.tables -or $response.tables.Count -lt 1) {
      throw "Query for $table returned no table metadata."
    }
    $columns = @($response.tables[0].columns | ForEach-Object { $_.name })
    $rows = @($response.tables[0].rows | ForEach-Object {
      $values = $_
      $row = [ordered]@{}
      for ($index = 0; $index -lt $columns.Count; $index++) { $row[$columns[$index]] = $values[$index] }
      [pscustomobject]$row
    })
    $results[$destination] = Assert-TelemetryIngestionRows -Rows $rows -ExpectedIds $expected -RunId $run `
      -Destination $destination -Profile $Profile
  }
  if (@($results.Values | Where-Object { -not $_.Passed }).Count -eq 0) {
    return @($destinations | ForEach-Object { $results[$_] })
  }
  if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 10 }
} while ([datetime]::UtcNow -lt $deadline)

$details = @($destinations | ForEach-Object { $results[$_] | ConvertTo-Json -Compress -Depth 5 }) -join '; '
throw "Ingestion validation timed out for run $run (accepted upload is not delivery). $details"
