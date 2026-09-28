$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "observability-agent-config-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts'), (Join-Path $root 'infra'), (Join-Path $root 'terraform') -Force
$helper = Join-Path $root 'scripts/sync-config.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../sync-config.ps1') -Destination $helper
$configPath = Join-Path $root 'lab.config.json'
$config = @{
  subscriptionId = [guid]::NewGuid().ToString(); tenantId = [guid]::NewGuid().ToString()
  alertEmail = 'operator@example.com'; vmAdminPassword = [guid]::NewGuid().ToString()
  resourceGroup = 'test-rg'; location = 'northeurope'; namePrefix = 'test'
  observabilityAgentLocation = 'canadacentral'
  enableObservabilityAgentAutomaticInvestigation = $true
  observabilityAgentInstructions = 'Correlate only signals with the same demonstrated customer impact.'
  stageToggles = @{
    enableStageA = $true; enableStageB = $true; enableStageC = $true; enableStageD = $true
    enableStageE = $false; enableStageAI = $false; enableStageSreAgent = $false
    enableStageObservabilityAgent = $true
  }
}
try {
  $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
  & $helper -ConfigPath $configPath
  $bicep = Get-Content -LiteralPath (Join-Path $root 'infra/main.parameters.json') -Raw | ConvertFrom-Json
  if (-not $bicep.parameters.enableObservabilityAgent.value -or
      $bicep.parameters.observabilityAgentLocation.value -ne 'canadacentral' -or
      -not $bicep.parameters.enableObservabilityAgentAutomaticInvestigation.value -or
      $bicep.parameters.observabilityAgentInstructions.value -ne $config.observabilityAgentInstructions) {
    throw 'Observability Agent Bicep configuration was not preserved.'
  }
  $terraform = Get-Content -LiteralPath (Join-Path $root 'terraform/stages.tfvars') -Raw
  if ($terraform -match 'observability') { throw 'Unsupported Observability Agent provisioning must not be emitted into Terraform inputs.' }

  $before = Get-FileHash (Join-Path $root 'infra/main.parameters.json'), (Join-Path $root 'terraform/stages.tfvars'), (Join-Path $root '.azure-target.json')
  foreach ($invalidLocation in @('northeurope', 'eastus2euap', 'not-a-region')) {
    $config.observabilityAgentLocation = $invalidLocation
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
    $rejected = $false
    try { & $helper -ConfigPath $configPath } catch { $rejected = $true }
    if (-not $rejected) { throw "Unsupported Observability Agent region '$invalidLocation' was accepted." }
  }
  $after = Get-FileHash (Join-Path $root 'infra/main.parameters.json'), (Join-Path $root 'terraform/stages.tfvars'), (Join-Path $root '.azure-target.json')
  if (Compare-Object $before.Hash $after.Hash) { throw 'Invalid Observability Agent configuration changed generated inputs.' }

  $config.observabilityAgentLocation = 'westeurope'
  $config.observabilityAgentInstructions = 'x' * 8193
  $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
  $rejected = $false
  try { & $helper -ConfigPath $configPath } catch { $rejected = $true }
  if (-not $rejected) { throw 'Overlong Observability Agent instructions were accepted.' }
  Write-Host 'PASS: Observability Agent configuration, supported regions, instruction limit, and Bicep-only provisioning boundary.'
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
