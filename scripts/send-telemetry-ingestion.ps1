<#
.SYNOPSIS
  Send the bounded synthetic ingestion fixture through a scenario-owned DCR.
.DESCRIPTION
  Requires the optional telemetry ingestion stage and Monitoring Metrics Publisher
  on the selected DCR. HTTP acceptance is not proof of Log Analytics ingestion.
  By default, queries both destinations using test-telemetry-ingestion.ps1.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [guid] $SubscriptionId,
  [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9._()-]+$')] [string] $ResourceGroup,
  [ValidatePattern('^[a-z0-9]{3,8}$')] [string] $NamePrefix = 'amlab',
  [ValidateSet('Baseline', 'Transformed', 'Tiered')] [string] $Profile = 'Transformed',
  [guid] $RunId = [guid]::NewGuid(),
  [switch] $SkipVerification
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'telemetry-ingestion-helpers.ps1')

if ($RunId -eq [guid]::Empty) { throw 'RunId must not be the empty GUID.' }
$subscription = $SubscriptionId.ToString('D')
$null = Assert-TelemetryIngestionTarget -SubscriptionId $subscription
$dcr = Get-TelemetryIngestionDcr -SubscriptionId $subscription -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix -Profile $Profile
$dce = Get-TelemetryIngestionDce -SubscriptionId $subscription -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
$fixture = @(New-TelemetryIngestionFixture -RunId $RunId)
if ($fixture.Count -ne 100) { throw 'The fixture must contain exactly 100 events.' }
$body = ConvertTo-Json -InputObject $fixture -Depth 4 -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
if ($bytes.Length -gt 1024 * 1024) { throw 'The fixture exceeds the 1 MiB demo upload cap.' }

$token = Get-TelemetryIngestionToken -SubscriptionId $subscription -Resource 'https://monitor.azure.com/'
$endpoint = $dce.properties.logsIngestion.endpoint.TrimEnd('/')
$immutableId = [uri]::EscapeDataString([string]$dcr.properties.immutableId)
$uri = "$endpoint/dataCollectionRules/$immutableId/streams/Custom-TelemetryIngestion?api-version=2023-01-01"
$headers = @{ Authorization = "Bearer $token"; 'x-ms-client-request-id' = $RunId.ToString('D') }
$attempt = 0
while ($true) {
  $attempt++
  $response = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' `
    -Body $bytes -SkipHttpErrorCheck -TimeoutSec 30
  if ([int]$response.StatusCode -eq 204) { break }
  $status = [int]$response.StatusCode
  if ($status -notin @(429, 500, 502, 503, 504) -or $attempt -ge 4) {
    throw "Upload to $($dcr.name) failed with HTTP $status after $attempt attempt(s): $($response.Content)"
  }
  $retryAfter = 0
  $retryHeader = [string]$response.Headers['Retry-After']
  if (-not [string]::IsNullOrWhiteSpace($retryHeader)) {
    if (-not [int]::TryParse($retryHeader, [ref]$retryAfter)) {
      $retryDate = [datetimeoffset]::MinValue
      if ([datetimeoffset]::TryParse($retryHeader, [ref]$retryDate)) {
        $retryAfter = [math]::Ceiling(($retryDate - [datetimeoffset]::UtcNow).TotalSeconds)
      }
    }
  }
  Start-Sleep -Seconds ([math]::Min(30, [math]::Max([math]::Pow(2, $attempt), $retryAfter)))
}

$result = [ordered]@{
  RunId = $RunId.ToString('D')
  Profile = $Profile
  Generated = $fixture.Count
  Uploaded = $fixture.Count
  Requests = $attempt
  Dcr = $dcr.id
  Dce = $dce.id
  Accepted = $true
  Verified = $false
}
if (-not $SkipVerification) {
  $validation = & (Join-Path $PSScriptRoot 'test-telemetry-ingestion.ps1') `
    -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix `
    -Profile $Profile -RunId $RunId
  if ($LASTEXITCODE -ne 0) { throw "Upload accepted but destination validation failed for run $RunId." }
  $result.Verified = $true
  $result['Destinations'] = $validation
}
[pscustomobject]$result
