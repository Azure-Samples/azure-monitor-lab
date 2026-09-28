$ErrorActionPreference = 'Stop'
$previousExitCode = $global:LASTEXITCODE
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$guide = Get-Content -LiteralPath (Join-Path $source 'docs/DEPLOY-BICEP-STEP-BY-STEP.md') -Raw
$guideStageE = $guide.IndexOf('--template-file ./infra/stages/40-optional-advanced.bicep')
$guideSentinelContent = $guide.IndexOf('--template-file ./infra/stages/41-sentinel-content.bicep')
if ($guideStageE -lt 0 -or $guideSentinelContent -le $guideStageE -or
    $guide -notmatch 'Run `41-sentinel-content` only when Sentinel is enabled' -or
    $guide -notmatch 'analytics-rule provider cannot preview a rule until the workspace is already onboarded') {
  throw 'The Bicep guide must document the ordered staged Sentinel deployment and its onboarding dependency.'
}
$blocks = [regex]::Matches($guide, '(?ms)^```powershell\r?\n(.*?)^```')
$helperImport = '. ./scripts/staged-deploy-helpers.ps1'
foreach ($relativePath in @('README.md', 'docs/DEPLOY-TERRAFORM-STEP-BY-STEP.md', 'docs/POST-DEPLOYMENT.md', 'docs/STAGE-AI.md', 'docs/STAGE-OBSERVABILITY-AGENT.md', 'scripts/README.md')) {
  $text = Get-Content -LiteralPath (Join-Path $source $relativePath) -Raw
  foreach ($example in [regex]::Matches($text, '(?ms)^```powershell\r?\n(.*?)^```')) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($example.Groups[1].Value, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Invalid PowerShell in ${relativePath}: $($errors.Message -join '; ')" }
  }
}
foreach ($block in $blocks) {
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$null, [ref]$parseErrors)
  if ($parseErrors.Count) { throw "Invalid PowerShell in the Bicep guide: $($parseErrors.Message -join '; ')" }
  if ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false).Count) {
    throw 'Load the versioned helper instead of embedding functions in the guide.'
  }
}

$sub = [guid]::NewGuid()
$tenant = [guid]::NewGuid()
$rg = 'test-rg'
$sourceParameters = (Get-Content -LiteralPath (Join-Path $source 'infra/main.parameters.json.template') -Raw | ConvertFrom-Json -AsHashtable).parameters
$sourceParameters.vmAdminPassword = @{ reference = @{ keyVault = @{ id = "/subscriptions/$sub/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-vault" }; secretName = 'vm-password' } }
$observabilityStage = Get-Content -LiteralPath (Join-Path $source 'infra/stages/70-observability-agent.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($name in @('enableObservabilityAgentAutomaticInvestigation', 'observabilityAgentInstructions')) {
  if (-not $observabilityStage.parameters.ContainsKey($name) -or -not $sourceParameters.ContainsKey($name)) {
    throw "Stage 70 must preserve shared Observability Agent parameter '$name'."
  }
}
foreach ($legacyName in @('enableAutomaticInvestigation', 'issueCreationInstructions')) {
  if ($observabilityStage.parameters.ContainsKey($legacyName)) {
    throw "Stage 70 must not use legacy parameter '$legacyName' because staged projection would drop its configured value."
  }
}
$stageE = Get-Content -LiteralPath (Join-Path $source 'infra/stages/40-optional-advanced.json') -Raw
$sentinelContent = Get-Content -LiteralPath (Join-Path $source 'infra/stages/41-sentinel-content.json') -Raw
if ($stageE -match 'Microsoft.SecurityInsights/alertRules' -or $stageE -notmatch 'Microsoft.SecurityInsights/onboardingStates' -or
    $sentinelContent -notmatch 'Microsoft.SecurityInsights/alertRules' -or $sentinelContent -match 'Microsoft.SecurityInsights/onboardingStates') {
  throw 'Staged Sentinel onboarding and analytics content must remain separate deployments.'
}
$fixture = @{
  Stage = ''; Overrides = @{}; Events = [Collections.Generic.List[string]]::new()
  Files = [Collections.Generic.List[string]]::new(); Confirm = 'yes'; Failure = ''; AccountChecks = 0
}

function Read-Host { return $fixture.Confirm }
function az {
  $global:LASTEXITCODE = 0
  switch ($args[0..1] -join ' ') {
    'account set' {
      if ($args[[Array]::IndexOf($args, '--subscription') + 1] -ne $sub.ToString()) { throw 'Account selection lost its subscription.' }
    }
    'account show' {
      $fixture.AccountChecks++
      $activeTenant = if ($fixture.Failure -eq 'account' -and $fixture.AccountChecks -gt 1) { [guid]::NewGuid() } else { $tenant }
      return @{ id = $sub; tenantId = $activeTenant } | ConvertTo-Json
    }
    'deployment group' {
      $operation = $args[2]
      if ($operation -notin @('what-if', 'create')) { throw 'Unexpected deployment operation.' }
      foreach ($expected in @{
        '--subscription' = $sub.ToString(); '--resource-group' = $rg; '--mode' = 'Incremental'
        '--name' = "stage-$($fixture.Stage)"; '--template-file' = "infra/stages/$($fixture.Stage).bicep"
      }.GetEnumerator()) {
        if ($args[[Array]::IndexOf($args, $expected.Key) + 1] -ne $expected.Value) { throw "Stage command lost $($expected.Key)." }
      }
      $parameterArgument = $args[[Array]::IndexOf($args, '--parameters') + 1]
      if (-not $parameterArgument.StartsWith('@') -or $args -match 'vmAdminPassword=') { throw 'Secure parameters must be passed through a file.' }
      $parameterPath = $parameterArgument.Substring(1)
      $fixture.Files.Add($parameterPath)
      if (-not $IsWindows -and [IO.File]::GetUnixFileMode($parameterPath) -ne ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)) {
        throw 'Temporary parameters must be readable and writable only by their owner.'
      }
      $parameters = (Get-Content -LiteralPath $parameterPath -Raw | ConvertFrom-Json -AsHashtable).parameters
      $schema = Get-Content -LiteralPath (Join-Path $source "infra/stages/$($fixture.Stage).json") -Raw | ConvertFrom-Json -AsHashtable
      foreach ($name in $parameters.Keys) {
        if (-not $schema.parameters.ContainsKey($name)) { throw "Unexpected stage parameter '$name'." }
        $expectedValue = if ($fixture.Overrides.ContainsKey($name)) { @{ value = $fixture.Overrides[$name] } } else { $sourceParameters[$name] }
        if (($parameters[$name] | ConvertTo-Json -Depth 20 -Compress) -ne ($expectedValue | ConvertTo-Json -Depth 20 -Compress)) { throw "Parameter '$name' was not preserved." }
      }
      foreach ($name in $schema.parameters.Keys) {
        if (-not $schema.parameters[$name].ContainsKey('defaultValue') -and -not $parameters.ContainsKey($name)) { throw "Missing required '$name'." }
        if ($sourceParameters.ContainsKey($name) -and -not $parameters.ContainsKey($name)) { throw "Shared input '$name' was dropped." }
      }
      if ($parameters.ContainsKey('vmAdminPassword') -and -not $parameters.vmAdminPassword.reference) { throw 'The Key Vault reference was lost.' }
      $fixture.Events.Add($operation)
      if ($fixture.Failure -eq $operation) { $global:LASTEXITCODE = 1 }
    }
    default { throw 'Unexpected Azure request from the documentation helper.' }
  }
}

Push-Location $source
try {
  function Assert-LabAccount { throw 'The stale account guard was not replaced.' }
  function Invoke-LabStage {
    param(
      [ValidateSet('00-foundation', '10-workloads', '20-alerting', '30-security-posture', '40-optional-advanced', '50-ai', '60-sre-agent')]
      [string] $Stage
    )
    throw 'The stale stage helper was not replaced.'
  }
  $originalInputs = @($sub, $tenant, $rg, $sourceParameters) | ConvertTo-Json -Depth 30 -Compress
  . ([scriptblock]::Create($helperImport))
  if ($fixture.AccountChecks -ne 0 -or $fixture.Events.Count -ne 0 -or
      (@($sub, $tenant, $rg, $sourceParameters) | ConvertTo-Json -Depth 30 -Compress) -cne $originalInputs) {
    throw 'Reloading stage helpers must not make Azure calls or change existing deployment inputs.'
  }
  $allowedStages = (Get-Command Invoke-LabStage).Parameters['Stage'].Attributes |
    Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] } |
    ForEach-Object { $_.ValidValues }
  if ($allowedStages -notcontains '41-sentinel-content') { throw 'Reloading must replace the stale Stage ValidateSet.' }
  Write-Output 'PASS: dot-sourcing replaces stale stage helpers, accepts Stage 41, and preserves inputs without Azure calls.'
  foreach ($stage in @('00-foundation', '10-workloads', '20-alerting', '30-security-posture', '40-optional-advanced', '41-sentinel-content', '50-ai', '60-sre-agent', '70-observability-agent')) {
    $templateReference = "--template-file ./infra/stages/$stage.bicep"
    $parameterReference = '--parameters "@$($stageParameterFiles[''{0}''])"' -f $stage
    if (-not $guide.Contains($templateReference) -or -not $guide.Contains($parameterReference)) {
      throw "The guide must deploy $stage with its native Azure CLI command and projected parameter file."
    }
  }
  if ([regex]::Matches($guide, '--confirm-with-what-if').Count -lt 9) {
    throw 'Every staged deployment command must include a what-if confirmation.'
  }
  foreach ($stage in @('00-foundation', '10-workloads', '20-alerting', '30-security-posture', '40-optional-advanced', '41-sentinel-content', '50-ai', '60-sre-agent', '70-observability-agent')) {
    $fixture.Stage = $stage
    $fixture.Events.Clear()
    $fixture.AccountChecks = 0
    Invoke-LabStage -Stage $stage
    if (($fixture.Events -join ',') -ne 'what-if,create' -or $fixture.AccountChecks -ne 2) { throw 'Every stage must preview, confirm, and reverify account before deployment.' }
  }
  $fixture.Stage = '50-ai'
  $fixture.Overrides = @{ enableHealthModel = $true; routerModelVersion = 'offline-version' }
  Invoke-LabStage -Stage $fixture.Stage -Overrides $fixture.Overrides
  $fixture.Overrides = @{}
  foreach ($failure in @('cancel', 'what-if', 'account', 'create', 'unknown', 'secure', 'missing')) {
    $fixture.Stage = '10-workloads'
    $fixture.Failure = $failure
    $fixture.Confirm = if ($failure -eq 'cancel') { 'no' } else { 'yes' }
    $fixture.AccountChecks = 0
    $fixture.Events.Clear()
    $arguments = @{}
    if ($failure -eq 'unknown') { $arguments.Overrides = @{ enableSreAgent = $true } }
    if ($failure -eq 'secure') { $arguments.Overrides = @{ vmAdminPassword = '<offline-test-placeholder>' } }
    $originalPassword = $sourceParameters.vmAdminPassword
    if ($failure -eq 'missing') { $sourceParameters.Remove('vmAdminPassword') }
    $rejected = $false
    try { Invoke-LabStage -Stage $fixture.Stage @arguments } catch { $rejected = $true }
    finally { $sourceParameters.vmAdminPassword = $originalPassword }
    if (-not $rejected) { throw "Stage helper accepted $failure." }
    if ($failure -ne 'create' -and $fixture.Events.Contains('create')) { throw 'An unapproved or failed preview reached deployment.' }
  }
  foreach ($path in $fixture.Files) {
    if (Test-Path -LiteralPath $path) { throw 'A temporary parameters file survived completion or failure.' }
  }
  foreach ($stage in @('AI', 'SRE Agent', 'Observability Agent')) {
    $section = [regex]::Match($guide, "(?ms)^### Stage $stage deploy.*?(?=^### |^## |\z)").Value
    if ($section -notmatch 'if \(\$webApp\)' -or $section -notmatch './scripts/deploy-webapp.ps1' -or $section -match './scripts/post-staged-deploy.ps1') {
      throw "$stage must refresh an existing console without requiring Stage B for standalone deployment."
    }
    if ($stage -eq 'AI' -and $section.IndexOf('./scripts/deploy-webapp.ps1') -gt $section.IndexOf('./scripts/setup-ai.ps1')) { throw 'Late AI traffic must follow console publication.' }
    if ($stage -eq 'SRE Agent' -and $section.IndexOf('./scripts/setup-sre-agent.ps1') -gt $section.IndexOf('./scripts/deploy-webapp.ps1')) { throw 'SRE validation must precede console publication.' }
    if ($stage -eq 'Observability Agent' -and $section.IndexOf('./scripts/setup-observability-agent.ps1') -gt $section.IndexOf('./scripts/deploy-webapp.ps1')) { throw 'Observability Agent validation must precede console publication.' }
  }
  if ($guide -match '--template-file infra/main.bicep') { throw 'A staged guide must not deploy the full-lab template.' }
  Write-Output 'PASS: all nine Bicep guide stages use valid projected parameters, preserve secure references, and enforce preview/account/cleanup guards. No Azure calls.'
  Write-Output 'PASS: late AI/SRE/Observability Agent instructions refresh existing consoles and preserve standalone A-only scenarios.'
} finally {
  Pop-Location
  foreach ($path in $fixture.Files | Select-Object -Unique) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  $global:LASTEXITCODE = $previousExitCode
}