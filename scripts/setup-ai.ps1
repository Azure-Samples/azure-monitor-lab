<#
.SYNOPSIS
  Provision the AI-stage demo agents and (optionally) simulate GenAI traffic.

.DESCRIPTION
  Run AFTER the optional AI stage (infra/stages/50-ai.bicep) has been deployed. It:
    1. Resolves the Foundry project endpoint + Application Insights connection string
       (discovered from the resource group, or passed explicitly).
    2. Installs the Python deps in workloads/ai/requirements.txt.
    3. Creates the four demo agents (workloads/ai/create_agents.py).
    4. Unless -SkipTraffic, starts a finite background conversation batch
       (workloads/ai/background_traffic.py)
       so token / trace / cost telemetry flows to Application Insights and the Foundry
       portal Observability views + the token metric alerts light up.

  Requires: Python 3.10+, az login with rights on the Foundry project (the lab sub Owner
  qualifies), and the AI stage already deployed.

.PARAMETER ResourceGroup
  Resource group hosting the lab (alias -g, matching az CLI). Defaults to lab.config.json
  'resourceGroup' or 'rg-azure-monitor-lab' when not passed explicitly — pass -g/-ResourceGroup
  to override a stale or wrong value in lab.config.json.

.PARAMETER NamePrefix
  Lab name prefix used to locate the Foundry account + App Insights. Defaults to lab.config.json 'namePrefix' or 'amlab'.

.PARAMETER ProjectEndpoint
  Override the Foundry project endpoint (otherwise discovered from the resource group).

.PARAMETER AppInsightsConnectionString
  Optional pre-resolved connection string. The Cloud Shell wrapper supplies this
  through the core ARM CLI surface to avoid installing the App Insights extension.

.PARAMETER Conversations
  Number of simulated conversations for the traffic run. Default 150.

.PARAMETER SkipTraffic
  Create the agents but do not simulate traffic.

.PARAMETER BackgroundTraffic
  Compatibility switch. Traffic always starts in a separate background process
  unless SkipTraffic is supplied. Returns after startup with log/status paths.

.PARAMETER SubscriptionId
  Azure subscription ID (aliases -Subscription, -s). When TenantId is omitted,
  the expected tenant is read from .azure-target.json for the same subscription.

.PARAMETER TenantId
  Expected Microsoft Entra tenant ID. Required when SubscriptionId is not the
  subscription configured in .azure-target.json.

.EXAMPLE
  ./scripts/setup-ai.ps1

.EXAMPLE
  ./scripts/setup-ai.ps1 -g rg-azure-monitor-lab-bicep-staged

.EXAMPLE
  ./scripts/setup-ai.ps1 --subscription 00000000-0000-0000-0000-000000000000

.EXAMPLE
  ./scripts/setup-ai.ps1 -Conversations 300
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Alias('g')]
  [string] $ResourceGroup,
  [string] $NamePrefix,
  [string] $ProjectEndpoint,
  [string] $AppInsightsConnectionString,
  [string] $ChatDeployment   = 'gpt-5-mini',
  [string] $RouterDeployment = 'model-router',
  [ValidateRange(1, 2147483647)] [int] $Conversations = 150,
  [switch] $SkipTraffic,
  [switch] $BackgroundTraffic,
  [Alias('s', 'subscription')]
  [guid] $SubscriptionId,
  [guid] $TenantId,
  [Parameter(ValueFromRemainingArguments, DontShow)]
  [string[]] $RemainingArguments
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

if ($RemainingArguments.Count -gt 0) {
  if ($RemainingArguments.Count -ne 2 -or $RemainingArguments[0] -ne '--subscription') {
    throw "Unknown argument(s): $($RemainingArguments -join ' ')"
  }
  if ($null -ne $SubscriptionId -and $SubscriptionId -ne [guid]::Empty) {
    throw 'Specify the subscription only once.'
  }
  $parsedSubscriptionId = [guid]::Empty
  if (-not [guid]::TryParse($RemainingArguments[1], [ref] $parsedSubscriptionId)) {
    throw "'$($RemainingArguments[1])' is not a valid subscription ID."
  }
  $SubscriptionId = $parsedSubscriptionId
}

if ($SkipTraffic -and $BackgroundTraffic) { throw 'Choose SkipTraffic or BackgroundTraffic, not both.' }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Fall back to lab.config.json for RG + prefix when not passed explicitly.
$labConfigPath = Join-Path $repoRoot 'lab.config.json'
if (Test-Path $labConfigPath) {
  $labCfg = Get-Content -Raw $labConfigPath | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($ResourceGroup) -and -not [string]::IsNullOrWhiteSpace($labCfg.resourceGroup)) {
    $ResourceGroup = $labCfg.resourceGroup
    Write-Host "   Using resourceGroup '$ResourceGroup' from lab.config.json (pass -g to override)" -ForegroundColor DarkGray
  }
  if ([string]::IsNullOrWhiteSpace($NamePrefix)    -and -not [string]::IsNullOrWhiteSpace($labCfg.namePrefix))    { $NamePrefix    = $labCfg.namePrefix }
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) { $ResourceGroup = 'rg-azure-monitor-lab' }
if ([string]::IsNullOrWhiteSpace($NamePrefix))    { $NamePrefix    = 'amlab' }

# Subscription guardrail — same gate as deploy.ps1 / post-deploy.ps1.
$targetFile = Join-Path $repoRoot '.azure-target.json'
$target = if (Test-Path $targetFile) { Get-Content -Raw $targetFile | ConvertFrom-Json } else { $null }
if ($null -ne $SubscriptionId -and $SubscriptionId -ne [guid]::Empty) {
  $subscriptionIdText = $SubscriptionId.ToString()
  if ($null -eq $TenantId -or $TenantId -eq [guid]::Empty) {
    if ($null -ne $target -and $target.expectedSubscriptionId -eq $subscriptionIdText) {
      $TenantId = [guid] $target.expectedTenantId
    } else {
      throw 'An expected tenant is required with an explicit subscription that does not match .azure-target.json.'
    }
  }
  $tenantIdText = $TenantId.ToString()
  az account set --subscription $subscriptionIdText --only-show-errors
  $active = az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $active.id -ne $subscriptionIdText -or $active.tenantId -ne $tenantIdText) { throw 'AI setup subscription or tenant mismatch.' }
} elseif ($null -ne $target) {
  az account set --subscription $target.expectedSubscriptionId | Out-Null
  $active = az account show --query "{id:id, tenantId:tenantId}" -o json | ConvertFrom-Json
  if ($active.id -ne $target.expectedSubscriptionId -or $active.tenantId -ne $target.expectedTenantId) {
    throw "BLOCKED: not on allowed lab subscription. Aborting setup-ai."
  }
}

# Python must be on PATH.
$python = (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1) ?? (Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $python) { throw "Python 3.10+ is required on PATH (python/python3) to run the AI demo scripts." }
$python = $python.Source

# --- Resolve the Foundry project endpoint ---
if ([string]::IsNullOrWhiteSpace($ProjectEndpoint)) {
  Write-Step "Discovering the Foundry account in $ResourceGroup"
  # Filter in PowerShell, not via a chained "[?...] | [?...]" --query string — az.cmd on
  # Windows can mangle quoted JMESPath filters before the CLI ever sees them.
  $accounts = az cognitiveservices account list -g $ResourceGroup -o json | ConvertFrom-Json
  $aiAccounts = $accounts | Where-Object { $_.kind -eq 'AIServices' }
  $acct = ($aiAccounts | Where-Object { $_.name -like "ai$NamePrefix*" } | Select-Object -First 1).name
  if ([string]::IsNullOrWhiteSpace($acct)) {
    $acct = ($aiAccounts | Select-Object -First 1).name
  }
  if ([string]::IsNullOrWhiteSpace($acct)) {
    throw "No Foundry (AIServices) account found in $ResourceGroup. Deploy the AI stage (infra/stages/50-ai.bicep) first."
  }
  $projectName = "$NamePrefix-ai-proj"
  $ProjectEndpoint = "https://$acct.services.ai.azure.com/api/projects/$projectName"
  Write-Host "   Account : $acct" -ForegroundColor DarkGray
  Write-Host "   Project : $projectName" -ForegroundColor DarkGray
}
Write-Host "   Endpoint: $ProjectEndpoint" -ForegroundColor Green

# --- App Insights connection string (enables tracing export) ---
if ([string]::IsNullOrWhiteSpace($AppInsightsConnectionString)) {
  Write-Step "Looking up Application Insights connection string (appi-$NamePrefix-<suffix>)"
  $appInsightsName = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/components --query "[?starts_with(name, 'appi-$NamePrefix-')] | sort_by(@, &name) | [0].name" -o tsv 2>$null
  if (-not [string]::IsNullOrWhiteSpace($appInsightsName)) {
    $AppInsightsConnectionString = az monitor app-insights component show -g $ResourceGroup -a $appInsightsName --query connectionString -o tsv 2>$null
  }
}
if ([string]::IsNullOrWhiteSpace($AppInsightsConnectionString)) {
  Write-Host "   appi-$NamePrefix-<suffix> not found — traffic will run without tracing export." -ForegroundColor Yellow
}

# --- Environment for the Python steps ---
$env:AZURE_AI_PROJECT_ENDPOINT              = $ProjectEndpoint
$env:AZURE_CHAT_DEPLOYMENT                  = $ChatDeployment
$env:AZURE_ROUTER_DEPLOYMENT               = $RouterDeployment
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = $AppInsightsConnectionString

# --- Python deps + agents ---
$aiDir = Join-Path $repoRoot 'workloads' 'ai'
Write-Step "Installing Python dependencies"
& $python -m pip install -q -r (Join-Path $aiDir 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'AI dependency installation failed.' }

Write-Step "Creating demo agents"
& $python (Join-Path $aiDir 'create_agents.py')
if ($LASTEXITCODE -ne 0) { throw 'AI demo agents could not be prepared.' }

# --- Traffic ---
if ($SkipTraffic) {
  Write-Step 'Skipping traffic simulation (-SkipTraffic)'
} else {
  Write-Step "Starting $Conversations conversations in the background (token/trace/cost telemetry)"
  $launchJson = & $python (Join-Path $aiDir 'background_traffic.py') --conversations $Conversations
  if ($LASTEXITCODE -ne 0 -or -not $launchJson) { throw 'AI background traffic could not be started.' }
  $traffic = $launchJson | ConvertFrom-Json
  if ($traffic.state -notin @('running', 'completed', 'completed_with_errors') -or $traffic.processId -lt 1 -or -not $traffic.logPath -or -not $traffic.statusPath) {
    throw 'AI background traffic startup was not acknowledged.'
  }
  Write-Host "   Process: $($traffic.processId)" -ForegroundColor DarkGray
  Write-Host "   Status : $($traffic.statusPath)" -ForegroundColor DarkGray
  Write-Host "   Log    : $($traffic.logPath)" -ForegroundColor DarkGray
}

if ($SkipTraffic) {
  Write-Host "`nAI stage ready. Explore the Foundry project Observability/Tracing tab and Monitor > Alerts." -ForegroundColor Green
}
