<#
.SYNOPSIS
  Materialize per-user config files from a single central lab.config.json.

.DESCRIPTION
  Reads <repo>/lab.config.json (gitignored) and (re)generates:
    - <repo>/.azure-target.json           subscription / tenant guardrail used by deploy.ps1 + teardown.ps1
    - <repo>/infra/main.parameters.json   Bicep parameters file consumed by az deployment group create
    - <repo>/terraform/stages.tfvars      Terraform variable file consumed by terraform apply -var-file

  All three derived files are gitignored. lab.config.json is the single source of truth.

  Bootstrap flow for a fresh clone:
    1. Copy lab.config.json.example  to  lab.config.json
    2. Edit lab.config.json (fill subscriptionId, tenantId, alertEmail, vmAdminPassword, ...)
    3. Run this script  (or just run scripts/deploy.ps1 - it calls this automatically)

.PARAMETER ConfigPath
  Optional override for the central config file. Defaults to <repo>/lab.config.json.

.PARAMETER Force
  Overwrite existing derived files without prompting (default: yes, files are regenerated).

.EXAMPLE
  ./scripts/sync-config.ps1
#>

[CmdletBinding()]
param(
  [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'lab.config.json'),
  [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Done($msg) { Write-Host "    $msg" -ForegroundColor Green }

# ---------------------------------------------------------------------------
# Load + validate the central config
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
  Write-Error @"
Central config not found at: $ConfigPath

Bootstrap a fresh clone with:
  Copy-Item lab.config.json.example lab.config.json
  # then edit lab.config.json and re-run this script
"@
  return
}

Write-Step "Reading $ConfigPath"
$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json

# Required fields
$required = @('subscriptionId','tenantId','alertEmail','vmAdminPassword','resourceGroup','location','namePrefix')
$missing = @()
foreach ($k in $required) {
  $val = $cfg.$k
  if ([string]::IsNullOrWhiteSpace($val) -or $val -like '<*>') { $missing += $k }
}
if ($missing.Count -gt 0) {
  Write-Error "lab.config.json is missing or has placeholder values for: $($missing -join ', '). Edit the file and re-run."
  return
}

# Defaults for optional keys
function Coalesce($a, $b) { if ($null -ne $a -and $a -ne '') { $a } else { $b } }
$vmAdminUsername  = Coalesce $cfg.vmAdminUsername  'azureuser'
$dailyCapGb       = Coalesce $cfg.dailyCapGb       1
$aksNodeCount     = Coalesce $cfg.aksNodeCount     2
$deployWindowsVm  = if ($null -eq $cfg.deployWindowsVm) { $true } else { [bool]$cfg.deployWindowsVm }
$deployLinuxVm    = if ($null -eq $cfg.deployLinuxVm)   { $true } else { [bool]$cfg.deployLinuxVm }
$siemWebhookUrl   = Coalesce $cfg.siemWebhookUrl   ''
$subscriptionName = Coalesce $cfg.subscriptionName '<unset>'
$forbiddenSubs    = if ($null -eq $cfg.forbiddenSubscriptionIds) { @() } else { @($cfg.forbiddenSubscriptionIds) }

$grafanaAdminObjectId = Coalesce $cfg.grafanaAdminObjectId ''
if ($grafanaAdminObjectId -ne '') {
  $parsedGrafanaAdmin = [guid]::Empty
  if (-not [guid]::TryParseExact($grafanaAdminObjectId, 'D', [ref]$parsedGrafanaAdmin) -or $parsedGrafanaAdmin -eq [guid]::Empty) {
    throw 'grafanaAdminObjectId must be empty or a nonzero Microsoft Entra user or group object ID in GUID format.'
  }
}

$enableLawReplication   = if ($null -eq $cfg.enableLawReplication) { $false } else { [bool]$cfg.enableLawReplication }
$lawReplicationLocation = Coalesce $cfg.lawReplicationLocation ''
if ($enableLawReplication -and [string]::IsNullOrWhiteSpace($lawReplicationLocation)) {
  Write-Error "lab.config.json has enableLawReplication=true but lawReplicationLocation is empty. Set it to a supported secondary region — see https://learn.microsoft.com/en-us/azure/azure-monitor/logs/workspace-replication?tabs=azure-cli#supported-regions"
  return
}

$stages = $cfg.stageToggles
if ($null -eq $stages) { $stages = [pscustomobject]@{ enableStageA=$true; enableStageB=$true; enableStageC=$true; enableStageD=$true; enableStageE=$true; enableStageAI=$false; enableStageSreAgent=$false; enableStageObservabilityAgent=$false } }
# AI stage is optional and defaults off when absent from the config.
$enableStageAI = if ($null -eq $stages.enableStageAI) { $false } else { [bool]$stages.enableStageAI }
# SRE Agent is optional and defaults off when absent from the config.
$enableStageSreAgent = if ($null -eq $stages.enableStageSreAgent) { $false } else { [bool]$stages.enableStageSreAgent }
# Azure Copilot Observability Agent is optional and defaults off when absent.
$enableStageObservabilityAgent = if ($null -eq $stages.enableStageObservabilityAgent) { $false } else { [bool]$stages.enableStageObservabilityAgent }
$observabilityAgentLocation = Coalesce $cfg.observabilityAgentLocation 'westeurope'
$supportedObservabilityAgentLocations = @('australiaeast','canadacentral','centralus','eastasia','eastus','southcentralus','uksouth','westcentralus','westeurope')
if ($observabilityAgentLocation -notin $supportedObservabilityAgentLocations) {
  throw "observabilityAgentLocation '$observabilityAgentLocation' is unsupported. Use one of: $($supportedObservabilityAgentLocations -join ', ')."
}
$enableObservabilityAgentAutomaticInvestigation = if ($null -eq $cfg.enableObservabilityAgentAutomaticInvestigation) { $false } else { [bool]$cfg.enableObservabilityAgentAutomaticInvestigation }
$observabilityAgentInstructions = Coalesce $cfg.observabilityAgentInstructions 'Correlate alerts for the lab application and its dependencies when they describe the same customer impact. Keep unrelated infrastructure alerts separate. Always create an issue for severity 1 or severity 2 agent task failures. Add [OPS-REVIEW] to issue titles.'
if ($observabilityAgentInstructions.Length -gt 8192) {
  throw 'observabilityAgentInstructions must not exceed 8192 characters.'
}

# ---------------------------------------------------------------------------
# Resolve target paths
# ---------------------------------------------------------------------------
$repoRoot         = Resolve-Path (Join-Path $PSScriptRoot '..')
$azureTargetPath  = Join-Path $repoRoot '.azure-target.json'
$bicepParamsPath  = Join-Path $repoRoot 'infra' 'main.parameters.json'
$tfVarsPath       = Join-Path $repoRoot 'terraform' 'stages.tfvars'

# ---------------------------------------------------------------------------
# 1. .azure-target.json  (subscription guardrail consumed by deploy.ps1 / teardown.ps1)
# ---------------------------------------------------------------------------
Write-Step "Writing $azureTargetPath"
$azureTarget = [ordered]@{
  '$schema'                 = 'https://json-schema.org/draft/2020-12/schema'
  'title'                   = 'Azure Monitor Lab — allowed targets'
  'description'             = 'Auto-generated from lab.config.json by scripts/sync-config.ps1. Edit lab.config.json, not this file.'
  'expectedSubscriptionId'  = $cfg.subscriptionId
  'expectedSubscriptionName'= $subscriptionName
  'expectedTenantId'        = $cfg.tenantId
  'forbiddenSubscriptionIds'= $forbiddenSubs
}
$azureTarget | ConvertTo-Json -Depth 5 | Set-Content -Path $azureTargetPath -Encoding UTF8
Write-Done "OK"

# ---------------------------------------------------------------------------
# 2. infra/main.parameters.json  (Bicep parameters file)
# ---------------------------------------------------------------------------
Write-Step "Writing $bicepParamsPath"
$bicepParams = [ordered]@{
  '$schema'        = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
  'contentVersion' = '1.0.0.0'
  'parameters'     = [ordered]@{
    'location'        = @{ value = $cfg.location }
    'namePrefix'      = @{ value = $cfg.namePrefix }
    'alertEmail'      = @{ value = $cfg.alertEmail }
    'vmAdminUsername' = @{ value = $vmAdminUsername }
    'vmAdminPassword' = @{ value = $cfg.vmAdminPassword }
    'deployWindowsVm' = @{ value = $deployWindowsVm }
    'deployLinuxVm'   = @{ value = $deployLinuxVm }
    'dailyCapGb'      = @{ value = [int]$dailyCapGb }
    'aksNodeCount'    = @{ value = [int]$aksNodeCount }
    'grafanaAdminObjectId' = @{ value = $grafanaAdminObjectId }
    'enableAi'        = @{ value = $enableStageAI }
    'enableSreAgent'  = @{ value = $enableStageSreAgent }
    'enableObservabilityAgent' = @{ value = $enableStageObservabilityAgent }
    'observabilityAgentLocation' = @{ value = $observabilityAgentLocation }
    'enableObservabilityAgentAutomaticInvestigation' = @{ value = $enableObservabilityAgentAutomaticInvestigation }
    'observabilityAgentInstructions' = @{ value = $observabilityAgentInstructions }
    'enableLawReplication'   = @{ value = $enableLawReplication }
    'lawReplicationLocation' = @{ value = $lawReplicationLocation }
  }
}
if (-not [string]::IsNullOrWhiteSpace($siemWebhookUrl)) {
  $bicepParams.parameters['siemWebhookUrl'] = @{ value = $siemWebhookUrl }
}
$bicepParams | ConvertTo-Json -Depth 6 | Set-Content -Path $bicepParamsPath -Encoding UTF8
Write-Done "OK"

# ---------------------------------------------------------------------------
# 3. terraform/stages.tfvars  (Terraform var-file)
# ---------------------------------------------------------------------------
Write-Step "Writing $tfVarsPath"
function Esc($s) { ($s -replace '"','\"') }
$tfLines = @(
  "# AUTO-GENERATED by scripts/sync-config.ps1 from lab.config.json"
  "# Edit lab.config.json (not this file) and re-run sync-config.ps1."
  ""
  "subscription_id     = `"$(Esc $cfg.subscriptionId)`""
  "resource_group_name = `"$(Esc $cfg.resourceGroup)`""
  "location            = `"$(Esc $cfg.location)`""
  "name_prefix         = `"$(Esc $cfg.namePrefix)`""
  "alert_email         = `"$(Esc $cfg.alertEmail)`""
  "vm_admin_username   = `"$(Esc $vmAdminUsername)`""
  "vm_admin_password   = `"$(Esc $cfg.vmAdminPassword)`""
  "daily_cap_gb        = $([int]$dailyCapGb)"
  "aks_node_count      = $([int]$aksNodeCount)"
  "grafana_admin_object_id = `"$(Esc $grafanaAdminObjectId)`""
  "deploy_windows_vm   = $($deployWindowsVm.ToString().ToLower())"
  "deploy_linux_vm     = $($deployLinuxVm.ToString().ToLower())"
  "siem_webhook_url    = `"$(Esc $siemWebhookUrl)`""
  "enable_law_replication   = $($enableLawReplication.ToString().ToLower())"
  "law_replication_location = `"$(Esc $lawReplicationLocation)`""
  ""
  "enable_stage_a = $((($stages.enableStageA -as [bool]).ToString()).ToLower())"
  "enable_stage_b = $((($stages.enableStageB -as [bool]).ToString()).ToLower())"
  "enable_stage_c = $((($stages.enableStageC -as [bool]).ToString()).ToLower())"
  "enable_stage_d = $((($stages.enableStageD -as [bool]).ToString()).ToLower())"
  "enable_stage_e = $((($stages.enableStageE -as [bool]).ToString()).ToLower())"
  "enable_stage_ai = $($enableStageAI.ToString().ToLower())"
  "enable_stage_sre_agent = $($enableStageSreAgent.ToString().ToLower())"
)
Set-Content -Path $tfVarsPath -Value ($tfLines -join "`r`n") -Encoding UTF8
Write-Done "OK"

Write-Host ""
Write-Host "✅ Config synced. Derived files (all gitignored):" -ForegroundColor Green
Write-Host "   - $azureTargetPath" -ForegroundColor DarkGray
Write-Host "   - $bicepParamsPath" -ForegroundColor DarkGray
Write-Host "   - $tfVarsPath"      -ForegroundColor DarkGray
if ($enableStageSreAgent) {
  Write-Host "   - SRE Agent deployment enabled (swedencentral)" -ForegroundColor DarkGray
}
if ($enableStageObservabilityAgent) {
  Write-Host "   - Observability Agent deployment enabled ($observabilityAgentLocation)" -ForegroundColor DarkGray
  Write-Warn "Terraform provisioning is not supported for Observability Agent during preview; use the Bicep or portal deployment path."
}
