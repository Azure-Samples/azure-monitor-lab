<#
.SYNOPSIS
  Validate the Azure SRE Agent deployed with the Azure Monitor Lab.

.DESCRIPTION
  Validates the deployed lab, SRE Agent resource, Azure Monitor connectors, and
  agent user-assigned managed identity roles.

  By default, the script is read-only. Use -GrantMissingRoles to add the
  documented minimum roles after explicit confirmation.

.PARAMETER SubscriptionId
  Subscription containing the lab. Defaults to .azure-target.json or
  lab.config.json when available.

.PARAMETER ResourceGroup
  Resource group containing the lab. Defaults to lab.config.json or
  rg-azure-monitor-lab.

.PARAMETER AgentPrincipalId
  Object (principal) ID of the SRE Agent user-assigned managed identity.

.PARAMETER GrantMissingRoles
  Grant any missing documented SRE Agent roles. Without this switch the script
  only reports role status.

.PARAMETER Yes
  Skip the GRANT confirmation when used with -GrantMissingRoles.

.EXAMPLE
  ./scripts/setup-sre-agent.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group>

.EXAMPLE
  ./scripts/setup-sre-agent.ps1 -SubscriptionId <subscription-id> -ResourceGroup <resource-group> `
    -AgentPrincipalId <object-id>
#>
[CmdletBinding()]
param(
  [string] $SubscriptionId,
  [string] $ResourceGroup,
  [string] $AgentPrincipalId,
  [switch] $GrantMissingRoles,
  [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$sreAgentLocation = 'swedencentral'

function Write-Step($Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Check($Label, $Passed, $Detail) {
  $status = if ($Passed) { 'PASS' } else { 'WARN' }
  $color = if ($Passed) { 'Green' } else { 'Yellow' }
  Write-Host ("  [{0}] {1}: {2}" -f $status, $Label, $Detail) -ForegroundColor $color
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI is required. Install it and run az login before continuing.'
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$labConfigPath = Join-Path $repoRoot 'lab.config.json'
$targetPath = Join-Path $repoRoot '.azure-target.json'
$labConfig = if (Test-Path $labConfigPath) { Get-Content -Raw $labConfigPath | ConvertFrom-Json } else { $null }
$target = if (Test-Path $targetPath) { Get-Content -Raw $targetPath | ConvertFrom-Json } else { $null }

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  if ($target -and -not [string]::IsNullOrWhiteSpace($target.expectedSubscriptionId)) {
    $SubscriptionId = $target.expectedSubscriptionId
  } elseif ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.subscriptionId)) {
    $SubscriptionId = $labConfig.subscriptionId
  }
}
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
  throw 'Pass -SubscriptionId or configure it in lab.config.json.'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
  $ResourceGroup = if ($labConfig -and -not [string]::IsNullOrWhiteSpace($labConfig.resourceGroup)) {
    $labConfig.resourceGroup
  } else {
    'rg-azure-monitor-lab'
  }
}

Write-Step "Pinning Azure CLI to subscription $SubscriptionId"
az account set --subscription $SubscriptionId | Out-Null
$activeAccount = az account show --query '{id:id,tenantId:tenantId,name:name}' -o json | ConvertFrom-Json
if ($activeAccount.id -ne $SubscriptionId) {
  throw "BLOCKED: active subscription is $($activeAccount.id), expected $SubscriptionId."
}
if ($target -and $target.expectedSubscriptionId -eq $SubscriptionId -and
    -not [string]::IsNullOrWhiteSpace($target.expectedTenantId) -and
    $activeAccount.tenantId -ne $target.expectedTenantId) {
  throw "BLOCKED: active tenant is $($activeAccount.tenantId), expected $($target.expectedTenantId)."
}
Write-Host "  Subscription: $($activeAccount.name) ($($activeAccount.id))" -ForegroundColor Green

Write-Step "Checking SRE Agent prerequisites in $ResourceGroup"
Write-Check 'SRE Agent region policy' $true "$sreAgentLocation (hard pinned)"
$resourceGroupDetails = az group show --subscription $SubscriptionId --name $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $resourceGroupDetails) {
  throw "Resource group '$ResourceGroup' was not found in subscription '$SubscriptionId'."
}

$resources = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup -o json | ConvertFrom-Json)
$requiredTypes = @(
  @{ Label = 'Log Analytics workspace'; Type = 'microsoft.operationalinsights/workspaces' }
  @{ Label = 'Application Insights'; Type = 'microsoft.insights/components' }
  @{ Label = 'App Service'; Type = 'microsoft.web/sites' }
  @{ Label = 'AKS'; Type = 'microsoft.containerservice/managedclusters' }
)
foreach ($requiredType in $requiredTypes) {
  $resourceNames = [System.Collections.Generic.List[string]]::new()
  foreach ($resource in $resources) {
    if ($resource.type.ToLowerInvariant() -eq $requiredType.Type) {
      $resourceNames.Add($resource.name)
    }
  }
  Write-Check $requiredType.Label ($resourceNames.Count -gt 0) ($(if ($resourceNames.Count -gt 0) { ($resourceNames -join ', ') } else { 'not found' }))
}

$alertTypes = @(
  'microsoft.insights/metricalerts'
  'microsoft.insights/scheduledqueryrules'
  'microsoft.insights/activitylogalerts'
)
$alerts = @($resources | Where-Object { $alertTypes -contains $_.type.ToLowerInvariant() })
Write-Check 'Azure Monitor alert rules' ($alerts.Count -gt 0) ("{0} rule(s) found" -f $alerts.Count)

$agents = @($resources | Where-Object { $_.type.ToLowerInvariant() -eq 'microsoft.app/agents' })
if ($agents.Count -eq 0) {
  throw "No Azure SRE Agent was found in '$ResourceGroup'. Set stageToggles.enableStageSreAgent=true, run scripts/sync-config.ps1, and rerun scripts/deploy.ps1."
}
if ($agents.Count -gt 1) {
  throw "Multiple Azure SRE Agents were found in '$ResourceGroup': $($agents.name -join ', '). Pass a resource group containing one lab agent."
}

$agentOutput = az resource show --subscription $SubscriptionId --ids $agents[0].id --api-version 2025-05-01-preview -o json 2>&1
if ($LASTEXITCODE -ne 0) {
  $agentError = $agentOutput -join "`n"
  if ($agentError -match 'InvalidApiVersion|ApiVersionNotSupported|NoRegisteredProviderFound') {
    throw 'Azure SRE Agent preview API 2025-05-01-preview is unavailable. Update the lab to the current Microsoft.App/agents API before deploying or validating the agent.'
  }
  throw "Could not read the Azure SRE Agent. Azure CLI returned:`n$agentError"
}
$agent = ($agentOutput -join "`n") | ConvertFrom-Json
Write-Check 'SRE Agent resource' ($agent.location -eq $sreAgentLocation) "$($agent.name) in $($agent.location)"
if ($agent.location -ne $sreAgentLocation) {
  throw "SRE Agent '$($agent.name)' is in '$($agent.location)', expected '$sreAgentLocation'."
}

$incidentPlatformType = $agent.properties.incidentManagementConfiguration.type
$incidentPlatformConnected = $incidentPlatformType -eq 'AzMonitor'
Write-Check 'Azure Monitor incident platform' $incidentPlatformConnected ($(if ($incidentPlatformConnected) { 'connected' } else { 'not connected; use Incidents > Triggers & response plans > Connect an incident platform' }))

$connectorOutput = az rest --method get --url "https://management.azure.com$($agent.id)/connectors?api-version=2025-05-01-preview" --query value -o json 2>&1
if ($LASTEXITCODE -ne 0) {
  $connectorError = $connectorOutput -join "`n"
  if ($connectorError -match 'InvalidApiVersion|ApiVersionNotSupported|NoRegisteredProviderFound') {
    throw 'Azure SRE Agent connector preview API 2025-05-01-preview is unavailable. Update the lab before validating connectors.'
  }
  throw "Could not read the Azure SRE Agent connectors. Azure CLI returned:`n$connectorError"
}
$connectors = @(($connectorOutput -join "`n") | ConvertFrom-Json)
foreach ($connectorName in @('app-insights', 'log-analytics', 'azure-monitor')) {
  $present = @($connectors | Where-Object { $_.name -eq $connectorName }).Count -gt 0
  Write-Check "Connector $connectorName" $present ($(if ($present) { 'configured' } else { 'not found' }))
  if (-not $present) {
    throw "Required SRE Agent connector '$connectorName' is missing."
  }
}

if ([string]::IsNullOrWhiteSpace($AgentPrincipalId)) {
  $identityIds = @($agent.identity.userAssignedIdentities.PSObject.Properties.Name)
  if ($identityIds.Count -ne 1) {
    throw "Expected one SRE Agent user-assigned identity, found $($identityIds.Count)."
  }
  $AgentPrincipalId = az identity show --subscription $SubscriptionId --ids $identityIds[0] --query principalId -o tsv
}

Write-Step "Checking SRE Agent managed identity roles"
$subscriptionScope = "/subscriptions/$SubscriptionId"
$resourceGroupScope = "$subscriptionScope/resourceGroups/$ResourceGroup"
$webApps = @($resources | Where-Object { $_.type.ToLowerInvariant() -eq 'microsoft.web/sites' -and $_.name -like 'app-*' })
$slotRollbackRequirement = @()
if ($webApps.Count -eq 1) {
  $slots = @(az webapp deployment slot list --subscription $SubscriptionId --resource-group $ResourceGroup --name $webApps[0].name -o json | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'Could not inspect App Service slots while validating SRE Agent access.' }
  if (@($slots | Where-Object name -eq 'broken').Count -eq 1) {
    $slotRollbackRequirement = @(@{ RolePrefix = 'Lab SRE Slot Rollback '; Scope = $webApps[0].id })
  }
}
$principalRequirements = @(
  @{ Label = 'Action UAMI'; PrincipalId = $AgentPrincipalId; Roles = @(
    @{ Role = 'Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Log Analytics Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Monitoring Reader'; Scope = $resourceGroupScope }
  ) + $slotRollbackRequirement }
  @{ Label = 'Connector system identity'; PrincipalId = $agent.identity.principalId; Roles = @(
    @{ Role = 'Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Log Analytics Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Monitoring Reader'; Scope = $resourceGroupScope }
    @{ Role = 'Monitoring Contributor'; Scope = $subscriptionScope }
  ) }
)

$missingRoles = [System.Collections.Generic.List[object]]::new()
foreach ($principalRequirement in $principalRequirements) {
  foreach ($requiredRole in $principalRequirement.Roles) {
    $assignments = @(az role assignment list --subscription $SubscriptionId --assignee-object-id $principalRequirement.PrincipalId `
      --scope $requiredRole.Scope --include-inherited -o json | ConvertFrom-Json)
    $roleLabel = if ($requiredRole.Role) { $requiredRole.Role } else { "$($requiredRole.RolePrefix)*" }
    $present = @($assignments | Where-Object {
      if ($requiredRole.Role) { $_.roleDefinitionName -eq $requiredRole.Role }
      else { $_.roleDefinitionName.StartsWith($requiredRole.RolePrefix, [StringComparison]::Ordinal) }
    }).Count -gt 0
    Write-Check "$($principalRequirement.Label): $roleLabel" $present $requiredRole.Scope
    if (-not $present) {
      $missingRoles.Add(@{
        Role = $requiredRole.Role
        RoleLabel = $roleLabel
        Scope = $requiredRole.Scope
        PrincipalId = $principalRequirement.PrincipalId
        Grantable = [bool]$requiredRole.Role
      })
    }
  }
}

if ($GrantMissingRoles -and $missingRoles.Count -gt 0) {
  $ungrantable = @($missingRoles | Where-Object { -not $_.Grantable })
  if ($ungrantable.Count -gt 0) {
    throw "The slot rollback role assignment is missing. Redeploy the SRE Agent stage with enableSlotFailureScenario=true before using -GrantMissingRoles."
  }
  if (-not $Yes) {
    Write-Host "`nThe script will create $($missingRoles.Count) role assignment(s)." -ForegroundColor Yellow
    $confirmation = Read-Host "Type GRANT to continue"
    if ($confirmation -cne 'GRANT') {
      throw 'Role assignment cancelled.'
    }
  }

  foreach ($missingRole in $missingRoles) {
    Write-Host "  Granting $($missingRole.Role) at $($missingRole.Scope)"
    az role assignment create --subscription $SubscriptionId --assignee-object-id $missingRole.PrincipalId `
      --assignee-principal-type ServicePrincipal --role $missingRole.Role --scope $missingRole.Scope -o none
  }
} elseif ($missingRoles.Count -gt 0) {
  Write-Host "`n  Rerun with -GrantMissingRoles after reviewing the scopes above." -ForegroundColor Yellow
} else {
  Write-Host "`n  All documented SRE Agent roles are present." -ForegroundColor Green
}

Write-Step 'Open the deployed agent'
Write-Host "  https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$($agent.name)"
Write-Host '  The agent is configured in Review mode with Azure Monitor, Application Insights, and Log Analytics connectors.'
Write-Host '  Add the lab response plans from docs/STAGE-SRE-AGENT.md before running scenarios 54 through 59.'
Write-Host "`nTrial note: baseline always-on charges are waived for 30 days, but active Azure Agent Unit usage is billed." -ForegroundColor Yellow
Write-Host 'See docs/STAGE-SRE-AGENT.md for the custom agent instructions, response plans, and demo flow.'