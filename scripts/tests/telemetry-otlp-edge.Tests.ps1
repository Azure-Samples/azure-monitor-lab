$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sender = Join-Path $root 'scripts\send-telemetry-otlp.ps1'
$setup = Join-Path $root 'scripts\setup-telemetry-ingestion-edge.ps1'
$templatePath = Join-Path $root 'workloads\telemetry-ingestion\edge\syslog-pipeline.arm.json'
$binary = Join-Path $root 'workloads\telemetry-ingestion\otel\.offline-test.pb'
$text = Join-Path $root 'workloads\telemetry-ingestion\edge\.offline-test.log'
$run = [guid]::NewGuid()

function Read-Varint {
  param([byte[]] $Bytes, [ref] $Position)
  [ulong]$value = 0
  $shift = 0
  do {
    if ($Position.Value -ge $Bytes.Length -or $shift -ge 70) { throw 'Malformed protobuf varint.' }
    $b = $Bytes[$Position.Value++]
    $value = $value -bor ([ulong]($b -band 127) -shl $shift)
    $shift += 7
  } while ($b -band 128)
  $value
}
function Read-Fields {
  param([byte[]] $Bytes)
  $position = 0
  $fields = @()
  while ($position -lt $Bytes.Length) {
    $tag = Read-Varint $Bytes ([ref]$position)
    $wire = [int]($tag -band 7)
    if ($wire -eq 2) {
      $length = [int](Read-Varint $Bytes ([ref]$position))
      if ($length -lt 0 -or $position + $length -gt $Bytes.Length) { throw 'Malformed protobuf length.' }
      $value = [byte[]]::new($length)
      [array]::Copy($Bytes, $position, $value, 0, $length)
      $position += $length
    } elseif ($wire -eq 0) {
      $value = Read-Varint $Bytes ([ref]$position)
    } elseif ($wire -eq 1) {
      if ($position + 8 -gt $Bytes.Length) { throw 'Malformed protobuf fixed64.' }
      $value = [BitConverter]::ToInt64($Bytes, $position)
      $position += 8
    } else { throw "Unexpected protobuf wire type $wire." }
    $fields += [pscustomobject]@{ Number = [int]($tag -shr 3); Wire = $wire; Value = $value }
  }
  $fields
}
function Get-Fields {
  param([object[]] $Fields, [int] $Number)
  @($Fields | Where-Object Number -EQ $Number)
}
function Decode-Text { param([byte[]] $Bytes) [Text.Encoding]::UTF8.GetString($Bytes) }

try {
  foreach ($path in @($sender, $setup)) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "PowerShell parsing failed: $path" }
  }
  $summary = & $sender -Mode Otlp -RunId $run -OutFile $binary
  if ($summary.Generated -ne 100 -or $summary.ReceiverAccepted -or $summary.Bytes -lt 10000) { throw 'OTLP dry run summary is incorrect.' }
  $request = Read-Fields ([IO.File]::ReadAllBytes($binary))
  $resourceLogs = Read-Fields (Get-Fields $request 1)[0].Value
  $resource = Read-Fields (Get-Fields $resourceLogs 1)[0].Value
  $kv = Read-Fields (Get-Fields $resource 1)[0].Value
  if ((Decode-Text (Get-Fields $kv 1)[0].Value) -ne 'service.name') { throw 'Missing OTLP resource service.name.' }
  $scopeLogs = Read-Fields (Get-Fields $resourceLogs 2)[0].Value
  $scope = Read-Fields (Get-Fields $scopeLogs 1)[0].Value
  if ((Decode-Text (Get-Fields $scope 1)[0].Value) -ne 'telemetry-ingestion.fixture' -or
      (Decode-Text (Get-Fields $scope 2)[0].Value) -ne '1.0.0') { throw 'Missing OTLP instrumentation scope.' }
  $logs = Get-Fields $scopeLogs 2
  if ($logs.Count -ne 100) { throw "Expected 100 OTLP logs, got $($logs.Count)." }
  $severities = @{}
  $ids = @()
  foreach ($entry in $logs) {
    $fields = Read-Fields $entry.Value
    $nameValues = @{}
    foreach ($attribute in (Get-Fields $fields 6)) {
      $pair = Read-Fields $attribute.Value
      $name = Decode-Text (Get-Fields $pair 1)[0].Value
      $any = Read-Fields (Get-Fields $pair 2)[0].Value
      $nameValues[$name] = Decode-Text (Get-Fields $any 1)[0].Value
    }
    if ($nameValues.RunId -ne $run.ToString('D') -or
        $nameValues.SampleSetId -ne 'telemetry-ingestion-v1' -or
        -not $nameValues.ContainsKey('SyntheticUser') -or
        -not $nameValues.ContainsKey('DebugField') -or
        $nameValues.TimeGenerated -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$') { throw 'OTLP log lost fixture attributes or UTC microsecond precision.' }
    $microseconds = [DateTimeOffset]::Parse($nameValues.TimeGenerated, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().Ticks - [DateTimeOffset]::UnixEpoch.Ticks
    if ((Get-Fields $fields 1)[0].Value -ne ($microseconds * 100L)) { throw 'OTLP time_unix_nano does not match the microsecond timestamp.' }
    $ids += $nameValues.EventId
    $severities[$nameValues.Severity]++
  }
  if ($ids.Count -ne @($ids | Select-Object -Unique).Count -or
      $severities.Error -ne 20 -or $severities.Warning -ne 30 -or $severities.Debug -ne 50) {
    throw 'OTLP fixture IDs or severities do not match the contract.'
  }
  $summary = & $sender -Mode Syslog -RunId $run -OutFile $text
  $lines = [IO.File]::ReadAllLines($text)
  $retained = @($lines | Where-Object { $_ -notmatch 'EdgeDrop=true' } | ForEach-Object {
    if ($_ -notmatch 'EventId=(event-[0-9]{3})') { throw 'Missing Syslog EventId.' }
    $Matches[1]
  })
  $expectedRetained = @(1..60 | ForEach-Object { 'event-{0:D3}' -f $_ })
  if ($summary.EdgeDropCandidates -ne 40 -or $summary.ExpectedForwarded -ne 60 -or
      $lines.Count -ne 100 -or
      @($lines | Where-Object { $_ -notmatch '^<[0-9]+>1 \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z ' }).Count -ne 0 -or
      @($lines | Where-Object { $_ -match 'EdgeDrop=true' }).Count -ne 40 -or
      @($lines | Where-Object { $_ -match 'demo.user@example.invalid|DebugField=|disposable-' -or $_ -notmatch 'SyntheticUser=\[REDACTED\]|Workload=ingestion-demo' }).Count -ne 0 -or
      (Compare-Object $expectedRetained $retained) -or
      @($lines | Where-Object { $_ -match 'EdgeDrop=true' -and $_ -notmatch 'EventId=event-0(?:6[1-9]|[7-9][0-9])|EventId=event-100' }).Count -ne 0) {
    throw 'Edge filter markers do not identify exactly event-061..event-100.'
  }
  $template = Get-Content -Raw $templatePath | ConvertFrom-Json
  $filter = $template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and $_.name -eq "[variables('flowName')]" }
  if ($filter.properties.dataSources.syslog[0].transform -ne 'edgeDrop' -or
      $filter.properties.transformations[0].headerProcessor.processor -ne 'header.SyslogFullyFormed' -or
      $filter.properties.transformations[0].processors[0].configuration.expression -notmatch 'extract.*EdgeDrop=.*where EdgeDropFlag !=.*true.*project-away EdgeDropFlag' -or
      @($template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRuleAssociations' -and -not $_.condition }).Count -ne 2) {
    throw 'Edge DCR lacks the on-host transform, normalization or extension associations.'
  }
  $bypass = & $sender -Mode Syslog -Profile Bypass -RunId $run -OutFile $text
  if ($bypass.ExpectedForwarded -ne 100) { throw 'Bypass summary is incorrect.' }
  $unsafeEndpointRejected = $false
  try { & $sender -Mode Otlp -Count 1 -Endpoint 'http://example.invalid/v1/logs' | Out-Null }
  catch { $unsafeEndpointRejected = $_.Exception.Message -match 'loopback Collector' }
  if (-not $unsafeEndpointRejected) { throw 'Remote OTLP endpoint was not blocked.' }
  $unboundedRejected = $false
  try { & $sender -Mode Syslog -Count 101 -OutFile $text | Out-Null }
  catch { $unboundedRejected = $true }
  if (-not $unboundedRejected) { throw 'Unbounded fixture count was accepted.' }
  Write-Output 'PASS: offline protobuf decode (100 records, resource/scope/record attributes), Syslog 40-drop marker, edge DCR transform/associations, bypass and PowerShell syntax.'
} finally {
  foreach ($path in @($binary, $text)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
