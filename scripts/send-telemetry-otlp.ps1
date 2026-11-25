[CmdletBinding()]
param(
  [ValidateSet('Otlp', 'Syslog')] [string] $Mode = 'Otlp',
  [ValidateSet('Filtered', 'Bypass')] [string] $Profile = 'Filtered',
  [guid] $RunId = [guid]::NewGuid(),
  [ValidateRange(1, 100)] [int] $Count = 100,
  [string] $OutFile,
  [string] $Endpoint = 'http://127.0.0.1:4318/v1/logs',
  [ValidateRange(1, 65535)] [int] $SyslogPort = 6514,
  [string] $SyslogServerName,
  [string] $SyslogCaFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'telemetry-ingestion-helpers.ps1')

function Join-Bytes {
  param([byte[][]] $Parts)
  $buffer = [System.Collections.Generic.List[byte]]::new()
  foreach ($part in $Parts) { $buffer.AddRange($part) }
  return ,$buffer.ToArray()
}
function ConvertTo-Varint {
  param([ulong] $Value)
  $buffer = [System.Collections.Generic.List[byte]]::new()
  while ($Value -ge 128) {
    $buffer.Add([byte](($Value -band 127) -bor 128))
    $Value = $Value -shr 7
  }
  $buffer.Add([byte]$Value)
  return ,$buffer.ToArray()
}
function New-LengthField {
  param([int] $Number, [byte[]] $Value)
  Join-Bytes @((ConvertTo-Varint ([ulong](8 * $Number + 2))), (ConvertTo-Varint ([ulong]$Value.Length)), $Value)
}
function New-StringField {
  param([int] $Number, [string] $Value)
  New-LengthField $Number ([Text.Encoding]::UTF8.GetBytes($Value))
}
function New-Attribute {
  param([string] $Name, [string] $Value)
  $any = New-StringField 1 $Value
  Join-Bytes @((New-StringField 1 $Name), (New-LengthField 2 $any))
}
function New-Attributes {
  param([object] $Record)
  $fields = [System.Collections.Generic.List[byte]]::new()
  foreach ($field in @('TimeGenerated', 'RunId', 'EventId', 'SampleSetId', 'Severity', 'Workload', 'Message', 'SyntheticUser', 'DebugField')) {
    $fields.AddRange((New-LengthField 6 (New-Attribute $field ([string]$Record.$field))))
  }
  return ,$fields.ToArray()
}

$records = @(New-TelemetryIngestionFixture -RunId $RunId | Select-Object -First $Count)
foreach ($record in $records) {
  $record.TimeGenerated = [DateTimeOffset]::Parse(
    [string]$record.TimeGenerated, [Globalization.CultureInfo]::InvariantCulture
  ).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.ffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}
$dropped = @($records | Where-Object { [int]$_.EventId.Substring(6) -ge 61 }).Count
if ($Mode -eq 'Otlp') {
  if ($Profile -ne 'Filtered') { throw 'Bypass is only meaningful for the Syslog edge pipeline.' }
  $logRecords = [System.Collections.Generic.List[byte]]::new()
  foreach ($record in $records) {
    $severityNumber = switch ($record.Severity) { Error { 17 } Warning { 13 } Debug { 5 } }
    $ticks = [DateTimeOffset]::Parse([string]$record.TimeGenerated, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().Ticks - [DateTimeOffset]::UnixEpoch.Ticks
    $timestamp = [BitConverter]::GetBytes([long](($ticks - ($ticks % 10)) * 100L))
    if (-not [BitConverter]::IsLittleEndian) { [array]::Reverse($timestamp) }
    $log = Join-Bytes @(
      (ConvertTo-Varint 9), $timestamp,
      (ConvertTo-Varint 16), (ConvertTo-Varint ([ulong]$severityNumber)),
      (New-StringField 3 ([string]$record.Severity)),
      (New-LengthField 5 (New-StringField 1 ([string]$record.Message))),
      (New-Attributes $record)
    )
    $logRecords.AddRange((New-LengthField 2 $log))
  }
  $scope = Join-Bytes @((New-StringField 1 'telemetry-ingestion.fixture'), (New-StringField 2 '1.0.0'))
  $scopeLogs = Join-Bytes @((New-LengthField 1 $scope), $logRecords.ToArray())
  $resource = New-LengthField 1 (New-Attribute 'service.name' 'telemetry-ingestion-demo')
  $resourceLogs = Join-Bytes @((New-LengthField 1 $resource), (New-LengthField 2 $scopeLogs))
  $payload = New-LengthField 1 $resourceLogs
  if ($OutFile) {
    [IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile), $payload)
  } else {
    if ($Endpoint -ne 'http://127.0.0.1:4318/v1/logs' -and $Endpoint -ne 'http://localhost:4318/v1/logs') {
      throw 'Only the loopback Collector OTLP HTTP/protobuf listener is allowed.'
    }
    $response = Invoke-WebRequest -Method Post -Uri $Endpoint -ContentType 'application/x-protobuf' -Body $payload -TimeoutSec 30
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { throw "OTLP receiver returned HTTP $($response.StatusCode)." }
  }
  [pscustomobject]@{ RunId = $RunId.ToString('D'); Protocol = 'OTLP HTTP/protobuf'; Generated = $records.Count; Bytes = $payload.Length; ReceiverAccepted = (-not $OutFile); CloudObserved = 'not verified' }
} else {
  $messages = foreach ($record in $records) {
    $priority = switch ($record.Severity) { Error { 11 } Warning { 12 } Debug { 15 } }
    $edgeDrop = if ([int]$record.EventId.Substring(6) -ge 61) { 'true' } else { 'false' }
    $timestamp = $record.TimeGenerated
    "<$priority>1 $timestamp localhost telemetry-ingestion - fixture - RunId=$($record.RunId) EventId=$($record.EventId) SampleSetId=$($record.SampleSetId) Severity=$($record.Severity) Workload=$($record.Workload) SyntheticUser=[REDACTED] EdgeDrop=$edgeDrop Message=$($record.Message)"
  }
  if ($OutFile) {
    [IO.File]::WriteAllLines($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile), [string[]]$messages, [Text.UTF8Encoding]::new($false))
  } else {
    if ([string]::IsNullOrWhiteSpace($SyslogServerName) -or [string]::IsNullOrWhiteSpace($SyslogCaFile)) {
      throw 'Syslog TLS requires -SyslogServerName (a certificate DNS name) and -SyslogCaFile (the managed server CA PEM).'
    }
    if (-not (Test-Path -LiteralPath $SyslogCaFile -PathType Leaf)) {
      throw "Syslog server CA PEM not found: $SyslogCaFile"
    }
    $caPath = (Resolve-Path -LiteralPath $SyslogCaFile).ProviderPath
    $caCertificates = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $caCertificates.ImportFromPem([IO.File]::ReadAllText($caPath))
    if ($caCertificates.Count -eq 0) { throw 'Syslog server CA PEM contains no certificates.' }
    $chainPolicy = [Security.Cryptography.X509Certificates.X509ChainPolicy]::new()
    $chainPolicy.TrustMode = [Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
    foreach ($ca in $caCertificates) { [void]$chainPolicy.CustomTrustStore.Add($ca) }
    $chainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $tlsOptions = [Net.Security.SslClientAuthenticationOptions]::new()
    $tlsOptions.TargetHost = $SyslogServerName
    $tlsOptions.CertificateChainPolicy = $chainPolicy
    try {
      $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $SyslogPort)
      $stream = [Net.Security.SslStream]::new($client.GetStream(), $false)
      $stream.AuthenticateAsClient($tlsOptions)
      foreach ($message in $messages) {
        $bytes = [Text.Encoding]::UTF8.GetBytes("$message`n")
        $stream.Write($bytes, 0, $bytes.Length)
      }
      $stream.Flush()
    } finally {
      if ($stream) { $stream.Dispose() }
      if ($client) { $client.Dispose() }
      foreach ($ca in $caCertificates) { $ca.Dispose() }
    }
  }
  [pscustomobject]@{ RunId = $RunId.ToString('D'); Protocol = 'RFC5424 TLS loopback'; Generated = $records.Count; EdgeDropCandidates = $dropped; ExpectedForwarded = $(if ($Profile -eq 'Filtered') { $records.Count - $dropped } else { $records.Count }); ReceiverAccepted = 'not verified'; CloudObserved = 'not verified' }
}
