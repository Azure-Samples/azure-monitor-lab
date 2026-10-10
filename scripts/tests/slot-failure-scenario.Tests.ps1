$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$trigger = Get-Content -LiteralPath (Join-Path $source 'scripts/trigger-broken-slot.ps1') -Raw
$rollback = Get-Content -LiteralPath (Join-Path $source 'scripts/rollback-broken-slot.ps1') -Raw
$runner = Get-Content -LiteralPath (Join-Path $source 'scripts/invoke-lab-operation.ps1') -Raw
$appService = Get-Content -LiteralPath (Join-Path $source 'infra/modules/appservice.bicep') -Raw
$customerWebApp = Get-Content -LiteralPath (Join-Path $source 'infra/modules/customer-webapp.bicep') -Raw
$prepare = Get-Content -LiteralPath (Join-Path $source 'scripts/prepare-broken-slot.ps1') -Raw
$sreAgent = Get-Content -LiteralPath (Join-Path $source 'infra/modules/sre-agent.bicep') -Raw

if ($trigger -notmatch '\$productionStatus -ne 200' -or $trigger -notmatch '\$brokenStatus -ne 503') {
  throw 'The trigger must reject repeated or unarmed swaps.'
}
if ($rollback -notmatch '\$productionStatus -eq 200 -and \$brokenStatus -eq 503' -or
    $rollback -notmatch '\$productionStatus -ne 503 -or \$brokenStatus -ne 200') {
  throw 'The rollback must distinguish healthy, recoverable, and ambiguous slot states.'
}
if ($runner -notmatch "'slot-failure'\s*=\s*'trigger-broken-slot\.ps1'") {
  throw 'The independent runner must map the approved slot-failure operation to the bounded trigger script.'
}
if ($appService -notmatch "enableSlotFailureScenario \? 'S1' : 'B1'" -or
    $appService -match 'module\s+brokenSlot') {
  throw 'The slot scenario must upgrade the shared plan while keeping its broken slot off the Control Center.'
}
if ($customerWebApp -notmatch "name: 'broken'" -or
    $customerWebApp -notmatch "healthCheckPath: '/api/slot-warmup'" -or
    $customerWebApp -notmatch "LabConsole__CustomerAppMode: 'true'" -or
    $prepare -notmatch "LabConsole__ForceOutage.*'true'") {
  throw 'The dedicated customer app must own the armed failure state and healthy slot warm-up endpoint.'
}
if ($sreAgent -notmatch 'Microsoft\.Web/sites/slots/slotsswap/action' -or
    $sreAgent -notmatch "mode: 'Review'") {
  throw 'The SRE Agent must retain Review mode and receive only the slot-swap recovery action.'
}

& {
  $fixture = @{
    ConfigurationFile = ''; RuntimeWrites = 0; Deployments = 0
    RuntimeFails = $false; DeployExitCode = 1; SlotEnabled = $true
    SlotState = 'Running'; SlotRuntimeEnabled = $true
    DeploymentId = [guid]::NewGuid().ToString('N')
  }
  function az {
    $global:LASTEXITCODE = 0
    switch ($args[0..2] -join ' ') {
      'webapp deployment slot' {
        if (-not $fixture.SlotEnabled) { return '[]' }
        return '[{"name":"broken","defaultHostName":"test-broken.azurewebsites.net"}]'
      }
      'webapp show --subscription' {
        return @{ state = $fixture.SlotState; enabled = $fixture.SlotRuntimeEnabled } | ConvertTo-Json -Compress
      }
      'rest --method post' { return '{"properties":{"ExistingSetting":"retained"}}' }
      'rest --method put' {
        $body = $args[[Array]::IndexOf($args, '--body') + 1]
        if (-not $body.StartsWith('@')) { throw 'App settings must use a JSON file.' }
        $settings = Get-Content -LiteralPath $body.Substring(1) -Raw | ConvertFrom-Json
        if ($settings.properties.ExistingSetting -ne 'retained' -or $settings.properties.LabConsole__ForceOutage -ne 'true') {
          throw 'Broken-slot preparation lost the cloned settings or outage flag.'
        }
        return
      }
      'webapp config set' {
        $configuration = $args[[Array]::IndexOf($args, '--generic-configurations') + 1]
        if (-not $configuration.StartsWith('@')) { throw 'Runtime configuration must use a JSON file to avoid native argument quoting.' }
        $fixture.ConfigurationFile = $configuration.Substring(1)
        $runtime = Get-Content -LiteralPath $fixture.ConfigurationFile -Raw | ConvertFrom-Json
        if ($runtime.healthCheckPath -ne '/api/slot-warmup' -or
            $args[[Array]::IndexOf($args, '--startup-file') + 1] -ne 'dotnet AmlabHello.dll') {
          throw 'Broken-slot runtime configuration changed.'
        }
        $fixture.RuntimeWrites++
        if ($fixture.RuntimeFails) { $global:LASTEXITCODE = 1 }
        return
      }
      'webapp deploy --subscription' {
        if ($args[[Array]::IndexOf($args, '--async') + 1] -ne 'true' -or
            $args[[Array]::IndexOf($args, '--type') + 1] -ne 'zip' -or
            $args[[Array]::IndexOf($args, '--slot') + 1] -ne 'broken') {
          throw 'Broken-slot ZIP deployment must submit asynchronously to the broken slot.'
        }
        $fixture.Deployments++
        $global:LASTEXITCODE = $fixture.DeployExitCode
        return
      }
      default { throw "Unexpected Azure CLI command: $($args -join ' ')" }
    }
  }
  function Invoke-RestMethod { return @{ ready = $true; deploymentId = $fixture.DeploymentId } }

  $parameters = @{
    SubscriptionId = [guid]::NewGuid(); ResourceGroup = 'test-rg'; WebAppName = 'test-app'
    ArchivePath = $PSCommandPath; DeploymentId = $fixture.DeploymentId
  }
  $prepare = Join-Path $source 'scripts/prepare-broken-slot.ps1'
  & $prepare @parameters
  if ($fixture.RuntimeWrites -ne 1 -or $fixture.Deployments -ne 1 -or (Test-Path -LiteralPath $fixture.ConfigurationFile)) {
    throw 'Preparation must configure the runtime, deploy once, and remove the temporary JSON file.'
  }

  $fixture.RuntimeFails = $true
  $failure = $null
  try { & $prepare @parameters } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -ne 'Could not configure the broken slot runtime.' -or
      $fixture.Deployments -ne 1 -or (Test-Path -LiteralPath $fixture.ConfigurationFile)) {
    throw 'Runtime configuration failures must stop deployment and clean up the temporary JSON file.'
  }

  $fixture.RuntimeFails = $false
  $fixture.SlotState = 'Stopped'
  $failure = $null
  try { & $prepare @parameters } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -notlike "*must be enabled and Running*" -or
      $fixture.RuntimeWrites -ne 2 -or $fixture.Deployments -ne 1) {
    throw 'A stopped broken slot must be rejected before runtime configuration or deployment.'
  }
  $fixture.SlotState = 'Running'
  $fixture.SlotRuntimeEnabled = $false
  $failure = $null
  try { & $prepare @parameters } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -notlike "*must be enabled and Running*" -or
      $fixture.RuntimeWrites -ne 2 -or $fixture.Deployments -ne 1) {
    throw 'A disabled broken slot must be rejected before runtime configuration or deployment.'
  }
  $fixture.SlotRuntimeEnabled = $true

  $publication = Get-Content -LiteralPath (Join-Path $source 'scripts/wait-webapp-publication.ps1') -Raw
  if ($publication -notmatch '\[int\]\s*\$MaxAttempts\s*=\s*90') {
    throw 'The production publication verifier must allow up to 15 minutes for App Service deployments.'
  }

  $fixture.SlotEnabled = $false
  & $prepare @parameters
  if ($fixture.RuntimeWrites -ne 2 -or $fixture.Deployments -ne 1) {
    throw 'Disabled slot scenarios must skip runtime configuration and deployment.'
  }
}

Write-Output 'PASS: broken-slot asynchronous publication, uncertain-result reconciliation, cleanup, failure handling, guardrails, and infrastructure gating.'
