$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$stage = Get-Content -LiteralPath (Join-Path $repo 'infra/stages/90-telemetry-ingestion.json') -Raw | ConvertFrom-Json
$main = Get-Content -LiteralPath (Join-Path $repo 'infra/main.json') -Raw | ConvertFrom-Json
$module = $stage.resources[0].properties.template
if (-not $module) { throw 'Stage 90 must embed the shared Bicep module.' }
$dcrs = @($module.resources | Where-Object type -eq 'Microsoft.Insights/dataCollectionRules')
$tables = @($module.resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces/tables')
if ($main.parameters.enableTelemetryIngestion.defaultValue -ne $false -or
    $main.parameters.enableTelemetryIngestionAuxiliary.defaultValue -ne $false -or
    $main.parameters.enableTelemetryIngestionNativeOtlp.defaultValue -ne $false -or
    $stage.parameters.enableAuxiliary.defaultValue -ne $false -or
    $stage.parameters.enableNativeOtlp.defaultValue -ne $false) {
  throw 'All ingestion, Auxiliary and native OTLP flags must default off.'
}
$jsonDcrs = @($dcrs | Where-Object apiVersion -eq '2023-03-11')
$native = @($dcrs | Where-Object apiVersion -eq '2024-03-11')
if ($jsonDcrs.Count -ne 3 -or $native.Count -ne 1 -or $tables.Count -ne 3) { throw 'Expected three JSON DCRs, one native OTLP DCR and three declared tables.' }
$transformed = $jsonDcrs | Where-Object { $_.name -notmatch 'baseline|tiered' } | Select-Object -First 1
$input = $module.variables.inputColumns
$expected = @('TimeGenerated', 'RunId', 'EventId', 'SampleSetId', 'Severity', 'Workload', 'Message', 'SyntheticUser', 'DebugField')
if (($input.name -join ',') -cne ($expected -join ',') -or $input[0].type -ne 'datetime') {
  throw 'The input stream schema differs from the frozen fixture contract.'
}
foreach ($dcr in $jsonDcrs) {
  if ($dcr.properties.dataFlows.Count -ne 2) { throw 'Each profile must route with exactly two DCR data flows.' }
  foreach ($flow in $dcr.properties.dataFlows) {
    if ($flow.streams[0] -ne "[variables('inputStream')]" -or
        $flow.transformKql -notmatch 'Transform' -or
        $flow.outputStream -notmatch '^Custom-TelemetryIngestion(Operational|Diagnostic|Verbose)_CL$') {
      throw "Invalid ingestion transform in $($dcr.name)."
    }
  }
}
if ($module.variables.projection -notmatch 'RunId, EventId, SampleSetId' -or
    $module.variables.projection -notmatch 'SyntheticUser = "\[REDACTED\]"' -or
    $module.variables.projection -notmatch 'tolower\(Severity\)' -or
    $module.variables.projection -match 'DebugField') {
  throw 'Transforms must preserve IDs, redact SyntheticUser and remove DebugField.'
}
if ($module.variables.baselineTransform -notmatch 'NormalizedSeverity = Severity' -or
    $module.variables.baselineTransform -notmatch 'Message, SyntheticUser$' -or
    $module.variables.baselineTransform -match '\[REDACTED\]|DebugField|tolower') {
  throw 'Baseline must retain the synthetic user and original severity while conforming to table schema.'
}
if ($module.variables.operationalTransform -notmatch 'Severity in' -or
    $module.variables.verboseTransform -notmatch 'Severity ==') {
  throw 'Operational and verbose routes must filter by severity.'
}
if (($tables | Where-Object { $_.properties.plan -eq 'Auxiliary' }).Count -ne 1 -or
    ($tables | Where-Object { $_.properties.plan -eq 'Analytics' }).Count -ne 2) {
  throw 'The expected plans are two Analytics and one optional Auxiliary.'
}
$auxiliaryTable = @($tables | Where-Object { $_.properties.plan -eq 'Auxiliary' })
if ($auxiliaryTable[0].apiVersion -ne '2025-07-01' -or
    $auxiliaryTable[0].condition -ne "[parameters('enableAuxiliary')]" -or
    $auxiliaryTable[0].properties.PSObject.Properties.Name -contains 'retentionInDays' -or
    $auxiliaryTable[0].properties.totalRetentionInDays -ne 30) {
  throw 'The optional Auxiliary table must use a supported API and total retention without Analytics retention.'
}
$roles = @($module.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
if ($roles.Count -ne 4 -or @($roles | Where-Object { $_.scope -notmatch 'Microsoft.Insights/dataCollectionRules' }).Count -gt 0) {
  throw 'Optional sender roles must be DCR-scoped, including the native OTLP DCR.'
}
if ($native[0].condition -ne "[parameters('enableNativeOtlp')]" -or
    $native[0].PSObject.Properties.Name -contains 'kind' -or
    $native[0].properties.dataCollectionEndpointId -ne $module.outputs.dceId.value -or
    $native[0].properties.directDataSources.otelLogs[0].streams[0] -cne 'Microsoft-OTel-Logs' -or
    $native[0].properties.directDataSources.otelLogs[0].enrichWithResourceAttributes[0] -ne '*' -or
    $native[0].properties.destinations.logAnalytics[0].name -ne 'nativeLogs' -or
    $native[0].properties.dataFlows[0].streams[0] -cne 'Microsoft-OTel-Logs' -or
    $native[0].properties.dataFlows[0].destinations[0] -ne 'nativeLogs' -or
    $native[0].properties.dataFlows[0].PSObject.Properties.Name -contains 'outputStream' -or
    $native[0].properties.PSObject.Properties.Name -contains 'streamDeclarations') {
  throw 'Native direct OTLP logs DCR must use the shared DCE, preserve attributes and route into standard OTelLogs.'
}
$nativeRole = @($roles | Where-Object { $_.condition -match 'enableNativeOtlp' })
if ($nativeRole.Count -ne 1 -or $nativeRole[0].condition -notmatch 'senderPrincipalId' -or
    $nativeRole[0].scope -notmatch 'dataCollectionRules' -or
    $nativeRole[0].properties.roleDefinitionId -notmatch 'publisherRoleId') {
  throw 'Native OTLP sender must have an opt-in, DCR-scoped Monitoring Metrics Publisher role.'
}
foreach ($name in @('nativeDcrId', 'nativeDcrImmutableId', 'dceEndpoint')) {
  if (-not $stage.outputs.$name) { throw "Missing $name output from the telemetry stage." }
}
foreach ($name in @('appInsightsLawName', 'workspaceTransformDcrName', 'summaryTableName')) {
  if (-not $main.outputs.$name) { throw "Existing main output $name must be preserved." }
}
foreach ($name in @('nativeDcrId', 'nativeDcrImmutableId', 'dceEndpoint')) {
  if ($main.outputs.PSObject.Properties.Name -contains $name) { throw "Native main output $name exceeds the ARM 64-output limit." }
}
if ($stage.outputs.nativeDcrImmutableId.value -notmatch 'enableNativeOtlp' -or
    $module.outputs.nativeOtlpLogsEndpoint.value -notmatch 'Microsoft-OTLP-Logs/otlp/v1/logs' -or
    $module.outputs.nativeOtlpReadiness.value -notmatch 'Collector') {
  throw 'Native OTLP outputs must be opt-in and retain the documented endpoint spelling and readiness caveat.'
}
Write-Output 'PASS: compiled ingestion stage, defaults, frozen schema, DCR projections and table plans.'
