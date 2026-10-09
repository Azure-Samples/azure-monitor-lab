$ErrorActionPreference = 'Stop'
$source = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$trigger = Get-Content -LiteralPath (Join-Path $source 'scripts/trigger-broken-slot.ps1') -Raw
$rollback = Get-Content -LiteralPath (Join-Path $source 'scripts/rollback-broken-slot.ps1') -Raw
$runner = Get-Content -LiteralPath (Join-Path $source 'scripts/invoke-lab-operation.ps1') -Raw
$appService = Get-Content -LiteralPath (Join-Path $source 'infra/modules/appservice.bicep') -Raw
$sreAgent = Get-Content -LiteralPath (Join-Path $source 'infra/modules/sre-agent.bicep') -Raw

if ($trigger -notmatch "productionOutage -eq 'true'" -or $trigger -notmatch "brokenOutage -ne 'true'") {
  throw 'The trigger must reject repeated or unarmed swaps.'
}
if ($rollback -notmatch "productionOutage -ne 'true'" -or $rollback -notmatch "brokenOutage -eq 'true'") {
  throw 'The rollback must distinguish healthy, recoverable, and ambiguous slot states.'
}
if ($runner -notmatch "'slot-failure'\s*=\s*'trigger-broken-slot\.ps1'") {
  throw 'The independent runner must map the approved slot-failure operation to the bounded trigger script.'
}
if ($appService -notmatch "enableSlotFailureScenario \? 'S1' : 'B1'" -or
    $appService -notmatch "LabConsole__ForceOutage', value: 'true'" -or
    $appService -notmatch "healthCheckPath: '/api/slot-warmup'") {
  throw 'The slot scenario must be opt-in, use a slot-capable plan, and retain a healthy swap warm-up endpoint.'
}
if ($sreAgent -notmatch 'Microsoft\.Web/sites/slots/slotsswap/action' -or
    $sreAgent -notmatch "mode: 'Review'") {
  throw 'The SRE Agent must retain Review mode and receive only the slot-swap recovery action.'
}

Write-Output 'PASS: broken-slot trigger, rollback guardrails, infrastructure gating, and SRE Review-mode access are present.'
