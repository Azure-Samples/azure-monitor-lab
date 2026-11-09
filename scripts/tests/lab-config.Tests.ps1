$ErrorActionPreference = 'Stop'
$repo = Join-Path $PSScriptRoot '..\..'
. (Join-Path $repo 'scripts\lab-config.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) "lab-config-test-$([guid]::NewGuid().ToString('N'))"
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
