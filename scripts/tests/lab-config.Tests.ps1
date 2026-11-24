$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
. (Join-Path $repo 'scripts\lab-config.ps1')
$root = Join-Path $repo "scripts\tests\.lab-config-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts'), (Join-Path $root 'infra'), (Join-Path $root 'terraform')
foreach ($name in @('sync-config.ps1', 'lab-config.ps1', 'migrate-lab-config.ps1')) {
  Copy-Item -LiteralPath (Join-Path $repo "scripts\$name") -Destination (Join-Path $root 'scripts')
}
$configPath = Join-Path $root 'lab.config.json'
$outputs = @(
  (Join-Path $root '.azure-target.json'),
  (Join-Path $root 'infra\main.parameters.json'),
  (Join-Path $root 'terraform\stages.tfvars')
)

function Assert-SameSettings($Expected, $Actual) {
  if ($Expected.PSObject.Properties.Name.Count -ne $Actual.PSObject.Properties.Name.Count) {
    throw 'Config conversion changed the key count.'
  }
  foreach ($property in $Expected.PSObject.Properties) {
    $expectedJson = ConvertTo-Json -InputObject $property.Value -Depth 100 -Compress
    $actualJson = ConvertTo-Json -InputObject $Actual.($property.Name) -Depth 100 -Compress
    if ($expectedJson -cne $actualJson) { throw "Config conversion changed '$($property.Name)'." }
  }
}

try {
  $templatePath = Join-Path $repo 'lab.config.json.example'
  $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
  if (-not $template.basicConfiguration -or -not $template.advancedConfiguration.compute -or
      -not $template.advancedConfiguration.monitoring -or -not $template.advancedConfiguration.stageToggles) {
    throw 'The example must expose basic settings and grouped advanced settings.'
  }
  $flat = Read-LabConfig -Path $templatePath
  if ($template.advancedConfiguration.PSObject.Properties.Name -contains 'access' -or
      $template.advancedConfiguration.PSObject.Properties.Name -contains 'safety' -or
      $flat.fabricAutomation.PSObject.Properties.Name -contains 'appInsightsMirrorConnectionId') {
    throw 'The default example must omit rarely needed access, safety, and mirror-connection overrides.'
  }
  if (-not $template.advancedConfiguration.customerApplicationServices) {
    throw 'The example must use the customerApplicationServices group.'
  }

  $flat.subscriptionId = [guid]::NewGuid().ToString()
  $flat.tenantId = [guid]::NewGuid().ToString()
  $flat.vmAdminPassword = [guid]::NewGuid().ToString()
  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  $defaultHashes = (Get-FileHash -LiteralPath $outputs).Hash
  $defaultBicep = Get-Content -LiteralPath $outputs[1] -Raw | ConvertFrom-Json
  if ($defaultBicep.parameters.enableHealthModelDemo.value -ne $false -or
      (Get-Content -LiteralPath $outputs[2] -Raw) -notmatch 'enable_stage_health_model_demo = false') {
    throw 'Health Model Demo must default off in both deployment formats.'
  }
  if ($defaultBicep.parameters.enableTelemetryIngestion.value -ne $false -or
      $defaultBicep.parameters.enableTelemetryIngestionAuxiliary.value -ne $false -or
      $defaultBicep.parameters.enableTelemetryIngestionNativeOtlp.value -ne $false -or
      $flat.stageToggles.enableStageAzureMonitorPipeline -ne $false -or
      (Get-Content -LiteralPath $outputs[2] -Raw) -notmatch 'enable_stage_telemetry_ingestion = false') {
    throw 'Telemetry ingestion, Auxiliary and Azure Monitor pipeline must default off.'
  }
  $flat | Add-Member -NotePropertyName grafanaAdminObjectId -NotePropertyValue ''
  $flat | Add-Member -NotePropertyName forbiddenSubscriptionIds -NotePropertyValue @()
  $flat.fabricAutomation | Add-Member -NotePropertyName appInsightsMirrorConnectionId -NotePropertyValue ''
  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  if (Compare-Object $defaultHashes (Get-FileHash -LiteralPath $outputs).Hash) {
    throw 'Omitting optional empty overrides changed generated deployment inputs.'
  }
  $flat.grafanaAdminObjectId = [guid]::NewGuid().ToString()
  $flat.forbiddenSubscriptionIds = @([guid]::NewGuid().ToString())
  $flat.dailyCapGb = 7
  $flat.enableVmOtelMetrics = $false
  $flat.enableLawReplication = $true
  $flat.lawReplicationLocation = 'westeurope'
  $flat.stageToggles.enableStageAI = $true
  $flat.stageToggles.enableStageSreAgent = $true
  $flat.stageToggles.enableStageObservabilityAgent = $true
  $flat.stageToggles.enableStageFabric = $true
  $flat.stageToggles.enableStageHealthModelDemo = $true
  $flat.stageToggles.enableStageTelemetryIngestion = $true
  $flat.stageToggles.enableStageAzureMonitorPipeline = $true
  $flat.enableAuxiliary = $true
  $flat.stageToggles.enableSlotFailureScenario = $true
  $flat.stageToggles.enableCustomerDependencies = $true
  $flat.sqlEntraAdminObjectId = [guid]::NewGuid().ToString()
  $flat.sqlEntraAdminName = 'Fixture Operators'
  $flat.fabricAutomation.mirrorScope = @('fixture-workspace')
  $flat | Add-Member -NotePropertyName customSetting -NotePropertyValue ([pscustomobject]@{ enabled = $false; items = @() })

  $grouped = ConvertTo-GroupedLabConfig -Configuration $flat
  Assert-SameSettings $flat (ConvertTo-FlatLabConfig -Configuration $grouped)
  Assert-SameSettings $flat (ConvertTo-FlatLabConfig -Configuration (ConvertTo-GroupedLabConfig $grouped))
  $legacyGroup = $grouped | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $legacyGroup.advancedConfiguration | Add-Member -NotePropertyName customerDependencies -NotePropertyValue $legacyGroup.advancedConfiguration.customerApplicationServices
  $legacyGroup.advancedConfiguration.PSObject.Properties.Remove('customerApplicationServices')
  Assert-SameSettings $flat (ConvertTo-FlatLabConfig -Configuration $legacyGroup)
  $regrouped = ConvertTo-GroupedLabConfig -Configuration $legacyGroup
  if (-not $regrouped.advancedConfiguration.customerApplicationServices -or
      $regrouped.advancedConfiguration.PSObject.Properties.Name -contains 'customerDependencies') {
    throw 'Migration did not use the clearer customer application services group name.'
  }
  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  $before = (Get-FileHash -LiteralPath $outputs).Hash
  $grouped | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  if (Compare-Object $before (Get-FileHash -LiteralPath $outputs).Hash) {
    throw 'Grouped config changed generated Bicep, Terraform, or account inputs.'
  }
  $enabledBicep = Get-Content -LiteralPath $outputs[1] -Raw | ConvertFrom-Json
  if ($enabledBicep.parameters.enableHealthModelDemo.value -ne $true -or
      (Get-Content -LiteralPath $outputs[2] -Raw) -notmatch 'enable_stage_health_model_demo = true') {
    throw 'Health Model Demo enablement was lost during config generation.'
  }
  if ($enabledBicep.parameters.enableTelemetryIngestion.value -ne $true -or
      $enabledBicep.parameters.enableTelemetryIngestionAuxiliary.value -ne $true -or
      (Get-Content -LiteralPath $outputs[2] -Raw) -notmatch 'enable_telemetry_ingestion_auxiliary = true') {
    throw 'Telemetry ingestion or Auxiliary opt-in was lost during config generation.'
  }
  $independentPipeline = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $independentPipeline.stageToggles.enableStageTelemetryIngestion = $false
  $independentPipeline.enableAuxiliary = $false
  $independentPipeline | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  if ((Read-LabConfig -Path $configPath).stageToggles.enableStageAzureMonitorPipeline -ne $true) {
    throw 'Azure Monitor pipeline must be independently selectable without the JSON ingestion stage.'
  }
  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  foreach ($setting in @('enableStageTelemetryIngestion', 'enableAuxiliary')) {
    $invalid = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    if ($setting -eq 'enableAuxiliary') { $invalid.enableAuxiliary = 'true' } else { $invalid.stageToggles.enableStageTelemetryIngestion = 'true' }
    $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
    try {
      & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
      throw "Expected $setting to reject quoted booleans."
    } catch {
      if ($_.Exception.Message -notmatch 'must be a JSON Boolean') { throw }
    }
  }
  $native = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $native.stageToggles.enableStageAzureMonitorPipeline = $false
  $native.enableNativeOtlp = $true
  $native | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  $nativeBicep = Get-Content -LiteralPath $outputs[1] -Raw | ConvertFrom-Json
  if ($nativeBicep.parameters.enableTelemetryIngestionNativeOtlp.value -ne $true -or
      (Get-Content -LiteralPath $outputs[2] -Raw) -notmatch 'enable_telemetry_ingestion_native_otlp = true') {
    throw 'Native OTLP opt-in was lost without Azure Monitor pipeline.'
  }
  foreach ($missing in @('enableStageTelemetryIngestion', 'enableStageA', 'enableStageB', 'deployLinuxVm')) {
    $invalid = $native | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    if ($missing -eq 'deployLinuxVm') { $invalid.deployLinuxVm = $false }
    else { $invalid.stageToggles.$missing = $false }
    if ($missing -eq 'enableStageTelemetryIngestion') { $invalid.enableAuxiliary = $false }
    if ($missing -eq 'enableStageB') { $invalid.stageToggles.enableStageHealthModelDemo = $false }
    $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
    try {
      & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
      throw "Native OTLP accepted missing prerequisite $missing."
    } catch {
      if ($_.Exception.Message -notmatch 'enableNativeOtlp requires') { throw }
    }
  }
  $invalid = $native | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $invalid.enableNativeOtlp = 'true'
  $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  try {
    & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
    throw 'Native OTLP accepted a quoted Boolean.'
  } catch {
    if ($_.Exception.Message -notmatch 'enableNativeOtlp must be a JSON Boolean') { throw }
  }
  $invalid = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $invalid.stageToggles.enableStageTelemetryIngestion = $false
  $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  try {
    & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
    throw 'Auxiliary must require the JSON ingestion stage.'
  } catch {
    if ($_.Exception.Message -notmatch 'enableAuxiliary requires') { throw }
  }
  $invalid = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
  $invalid.stageToggles.enableStageAzureMonitorPipeline = 'true'
  $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  try {
    & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
    throw 'Pipeline opt-in accepted a quoted Boolean.'
  } catch {
    if ($_.Exception.Message -notmatch 'enableStageAzureMonitorPipeline must be a JSON Boolean') { throw }
  }
  foreach ($missing in @('enableStageB', 'deployLinuxVm')) {
    $invalid = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $invalid.stageToggles.enableStageHealthModelDemo = $false
    if ($missing -eq 'deployLinuxVm') { $invalid.deployLinuxVm = $false }
    else { $invalid.stageToggles.enableStageB = $false }
    $invalid | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
    try {
      & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
      throw "Pipeline opt-in accepted missing prerequisite $missing."
    } catch {
      if ($_.Exception.Message -notmatch 'Azure Monitor pipeline requires') { throw }
    }
  }
  $flat.stageToggles.enableStageAzureMonitorPipeline = $false
  $flat | Add-Member -NotePropertyName healthModelDemoCafeLocation -NotePropertyValue 'westeurope'
  $flat | Add-Member -NotePropertyName healthModelDemoCafeMonitoringReaderAssignmentName -NotePropertyValue ([guid]::NewGuid().ToString())
  $flat | Add-Member -NotePropertyName enableSentinel -NotePropertyValue $false
  $flat | Add-Member -NotePropertyName enablePlatformLogsDcr -NotePropertyValue $true
  $flat | Add-Member -NotePropertyName enableMetricsExportDcr -NotePropertyValue $true
  $flat | Add-Member -NotePropertyName routerModelVersion -NotePropertyValue 'fixture-router'
  $flat.sqlEntraAdminName = 'Fixture ${literal} %{literal} "Operators"\Group'
  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath
  $overrideBicep = (Get-Content -LiteralPath $outputs[1] -Raw | ConvertFrom-Json).parameters
  $overrideTf = Get-Content -LiteralPath $outputs[2] -Raw
  foreach ($setting in @(
    @{ Bicep = 'healthModelDemoCafeLocation'; Terraform = 'health_model_demo_cafe_location'; Value = 'westeurope' },
    @{ Bicep = 'healthModelDemoCafeMonitoringReaderAssignmentName'; Terraform = 'health_model_demo_cafe_monitoring_reader_assignment_name'; Value = $flat.healthModelDemoCafeMonitoringReaderAssignmentName },
    @{ Bicep = 'enableSentinel'; Terraform = 'enable_sentinel'; Value = $false },
    @{ Bicep = 'enablePlatformLogsDcr'; Terraform = 'enable_platform_logs_dcr'; Value = $true },
    @{ Bicep = 'enableMetricsExportDcr'; Terraform = 'enable_metrics_export_dcr'; Value = $true },
    @{ Bicep = 'routerModelVersion'; Terraform = 'router_model_version'; Value = 'fixture-router' }
  )) {
    $literal = if ($setting.Value -is [bool]) { $setting.Value.ToString().ToLower() } else { '"' + $setting.Value + '"' }
    if ($overrideBicep.($setting.Bicep).value -cne $setting.Value -or -not $overrideTf.Contains("$($setting.Terraform) = $literal")) {
      throw "Config sync lost shared override '$($setting.Bicep)'."
    }
  }
  if (-not $overrideTf.Contains('sql_entra_admin_name = "Fixture $${literal} %%{literal} \"Operators\"\\Group"')) {
    throw 'Terraform string projection must preserve literal interpolation markers, quotes and backslashes.'
  }
  Write-Output 'PASS: Cafe adoption settings, optional telemetry, Sentinel opt-out, router version and literal Terraform strings survive config sync.'
  $before = (Get-FileHash -LiteralPath $outputs).Hash
  foreach ($value in @('false', 0, $null)) {
    $invalidStage = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $invalidStage.stageToggles.enableStageHealthModelDemo = $value
    $invalidStage | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
    $rejected = $false
    try { & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath } catch {
      if ($_.Exception.Message -notmatch 'enableStageHealthModelDemo must be a JSON Boolean') { throw }
      $rejected = $true
    }
    if (-not $rejected) { throw 'Health Model Demo accepted a non-Boolean toggle.' }
  }
  foreach ($stage in @('enableStageA', 'enableStageB', 'enableStageC', 'enableStageE')) {
    $invalidStage = $flat | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $invalidStage.stageToggles.$stage = $false
    $invalidStage | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
    $rejected = $false
    try { & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath } catch {
      if ($_.Exception.Message -notmatch 'Health Model Demo requires') { throw }
      $rejected = $true
    }
    if (-not $rejected) { throw "Health Model Demo accepted missing prerequisite $stage." }
  }

  foreach ($invalid in @(
    '[]', '[{}]', 'null', '"config"',
    '{"basicConfiguration":null}',
    '{"basicConfiguration":[]}',
    '{"advancedConfiguration":false}',
    '{"advancedConfiguration":{"compute":[]}}',
    '{"advancedConfiguration":{"stageToggles":null}}',
    '{"advancedConfiguration":{"computee":{}}}',
    '{"location":"eastus","basicConfiguration":{"location":"westus"}}',
    '{"basicConfiguration":{"location":"eastus"},"advancedConfiguration":{"other":{"location":"westus"}}}',
    '{"advancedConfiguration":{"compute":{"vmSize":"a"},"other":{"vmSize":"b"}}}',
    '{"advancedConfiguration":{"customerDependencies":{"slotAppServicePlanSku":"S1"},"customerApplicationServices":{"slotAppServicePlanSku":"S2"}}}',
    '{"stageToggles":{},"advancedConfiguration":{"stageToggles":{}}}'
  )) {
    Set-Content -LiteralPath $configPath -Value $invalid
    $rejected = $false
    try { & (Join-Path $root 'scripts\sync-config.ps1') -ConfigPath $configPath } catch {
      if ($_.Exception.Message -notmatch 'JSON object|Duplicate lab configuration|Unknown advancedConfiguration') { throw }
      $rejected = $true
    }
    if (-not $rejected) { throw 'Malformed or ambiguous config was accepted.' }
    if (Compare-Object $before (Get-FileHash -LiteralPath $outputs).Hash) {
      throw 'Invalid config changed generated inputs.'
    }
  }

  $flat | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
  $originalHash = (Get-FileHash -LiteralPath $configPath).Hash
  & (Join-Path $root 'scripts\migrate-lab-config.ps1') -ConfigPath $configPath -WhatIf
  if ((Get-FileHash -LiteralPath $configPath).Hash -ne $originalHash -or (Test-Path "$configPath.bak")) {
    throw 'Migration WhatIf changed files.'
  }
  & (Join-Path $root 'scripts\migrate-lab-config.ps1') -ConfigPath $configPath
  if ((Get-FileHash -LiteralPath "$configPath.bak").Hash -ne $originalHash) { throw 'Migration backup changed the original.' }
  Assert-SameSettings $flat (Read-LabConfig -Path $configPath)
  $migrated = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if (-not $migrated.basicConfiguration -or -not $migrated.advancedConfiguration.compute) {
    throw 'Migration did not persist the grouped format.'
  }
  $migratedHash = (Get-FileHash -LiteralPath $configPath).Hash
  $rejected = $false
  try { & (Join-Path $root 'scripts\migrate-lab-config.ps1') -ConfigPath $configPath } catch {
    if ($_.Exception.Message -notmatch 'Backup already exists') { throw }
    $rejected = $true
  }
  if (-not $rejected -or (Get-FileHash -LiteralPath $configPath).Hash -ne $migratedHash) {
    throw 'Migration overwrote an existing backup or changed the config on failure.'
  }
  Write-Host 'PASS: flat/grouped equivalence, generated inputs, invalid configs, and safe migration.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force
}
