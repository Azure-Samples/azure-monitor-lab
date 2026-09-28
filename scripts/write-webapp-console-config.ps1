[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ResourceGroup,
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [Parameter(Mandatory)] [string] $OutputPath,
  [string] $CentralLawName,
  [switch] $EnableInfrastructureHealth,
  [switch] $EnableFoundryPlayground,
  [Alias('EnableSreConversation')] [switch] $EnableSreAssistant,
  [string] $TenantId,
  [string] $SreMcpExecutable,
  [string] $SreModelEndpoint,
  [string] $SreModelDeployment
)

$ErrorActionPreference = 'Stop'
if ($EnableInfrastructureHealth -and -not $TenantId) { throw 'Infrastructure health requires the intended tenant ID.' }
if ($EnableSreAssistant -and (-not $TenantId -or -not $SreMcpExecutable -or -not $SreModelEndpoint -or -not $SreModelDeployment)) {
  throw 'SRE MCP assistant requires a tenant ID, MCP executable, model endpoint, and model deployment.'
}
if ($SreModelEndpoint) {
  $modelUri = $null
  if (-not [Uri]::TryCreate($SreModelEndpoint, [UriKind]::Absolute, [ref]$modelUri) `
      -or $modelUri.Scheme -ne 'https' -or -not $modelUri.Host.EndsWith('.openai.azure.com') `
      -or $modelUri.UserInfo -or $modelUri.Query -or $modelUri.Fragment -or $modelUri.AbsolutePath -ne '/' -or -not $modelUri.IsDefaultPort) {
    throw 'SRE host model endpoint must be an HTTPS Azure OpenAI account root without credentials, query, or fragment.'
  }
}
$inventoryJson = az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
  --query '[].{id:id,name:name,type:type}' --output json
if ($LASTEXITCODE -ne 0) { throw 'Unable to discover monitoring resources for the web console.' }
$resources = @($inventoryJson | ConvertFrom-Json)
$appInsights = $resources | Where-Object { $_.type -ieq 'Microsoft.Insights/components' } |
  Sort-Object { $_.name.Length }, name | Select-Object -First 1
$workspaces = @($resources | Where-Object { $_.type -ieq 'Microsoft.OperationalInsights/workspaces' })
$workspace = if ($CentralLawName) {
  $workspaces | Where-Object { $_.name -eq $CentralLawName } | Select-Object -First 1
} else {
  $workspaces | Where-Object { $_.name -like '*central*' } | Select-Object -First 1
}
$grafana = $resources | Where-Object { $_.type -ieq 'Microsoft.Dashboard/grafana' } | Select-Object -First 1
$links = [ordered]@{ ApplicationInsights = $null; Logs = $null; Workbook = $null; Grafana = $null }
if ($appInsights) { $links.ApplicationInsights = "https://portal.azure.com/#resource$($appInsights.id)/overview" }
if ($workspace) { $links.Logs = "https://portal.azure.com/#resource$($workspace.id)/logs" }

$applicationWorkspaceId = $null
if ($appInsights) {
  $linkedWorkspace = az resource show --subscription $SubscriptionId --ids $appInsights.id `
    --api-version 2020-02-02 --query properties.WorkspaceResourceId --output tsv
  if ($LASTEXITCODE -eq 0 -and $linkedWorkspace) {
    $matchedWorkspace = $workspaces | Where-Object { $_.id -ieq $linkedWorkspace } | Select-Object -First 1
    if ($matchedWorkspace) { $applicationWorkspaceId = $matchedWorkspace.id }
  }
}

foreach ($workbook in ($resources | Where-Object { $_.type -ieq 'Microsoft.Insights/workbooks' })) {
  $displayName = az resource show --subscription $SubscriptionId --ids $workbook.id `
    --api-version 2022-04-01 --query properties.displayName --output tsv
  if ($LASTEXITCODE -eq 0 -and $displayName -match 'traffic.lights|health dashboard') {
    $links.Workbook = "https://portal.azure.com/#resource$($workbook.id)/workbook"
    break
  }
}
if ($grafana) {
  $endpoint = az resource show --subscription $SubscriptionId --ids $grafana.id `
    --api-version 2023-09-01 --query properties.endpoint --output tsv
  $parsedEndpoint = $null
  if ($LASTEXITCODE -eq 0 -and [Uri]::TryCreate([string]$endpoint, [UriKind]::Absolute, [ref]$parsedEndpoint) `
      -and $parsedEndpoint.Scheme -eq 'https' -and -not $parsedEndpoint.UserInfo) {
    $links.Grafana = $parsedEndpoint.AbsoluteUri
  }
}
$sreAgents = @($resources | Where-Object { $_.type -ieq 'Microsoft.App/agents' })
$observabilityAgents = @($resources | Where-Object { $_.type -ieq 'Microsoft.Monitor/observabilityAgents' })
$projects = @($resources | Where-Object { $_.type -ieq 'Microsoft.CognitiveServices/accounts/projects' })
$apps = @($resources | Where-Object { $_.type -ieq 'Microsoft.Web/sites' })
$links.SreAgent = $null
$links.ObservabilityAgent = $null
$links.Foundry = $null
$projectEndpoint = $null
if ($sreAgents.Count -eq 1) {
  $links.SreAgent = "https://sre.azure.com/#/agent/$SubscriptionId/$ResourceGroup/$($sreAgents[0].name)"
} elseif ($sreAgents.Count -gt 1) {
  Write-Warning 'Multiple SRE agents found. Configure LabConsole:Links:SreAgent explicitly.'
}
if ($observabilityAgents.Count -eq 1) {
  $links.ObservabilityAgent = "https://portal.azure.com/#resource$($observabilityAgents[0].id)"
} elseif ($observabilityAgents.Count -gt 1) {
  Write-Warning 'Multiple Observability Agents found. Configure LabConsole:Links:ObservabilityAgent explicitly.'
}
if ($projects.Count -eq 1) {
  $project = $projects[0]
  $endpoint = az resource show --subscription $SubscriptionId --ids $project.id `
    --api-version 2025-06-01 --query properties.endpoints --output json
  if ($LASTEXITCODE -eq 0 -and $endpoint) {
    $endpoints = $endpoint | ConvertFrom-Json
    foreach ($property in $endpoints.PSObject.Properties) {
      $candidate = $null
      if ([Uri]::TryCreate([string]$property.Value, [UriKind]::Absolute, [ref]$candidate) `
          -and $candidate.Scheme -eq 'https' -and -not $candidate.UserInfo `
          -and $candidate.Host.EndsWith('.services.ai.azure.com') `
          -and $candidate.AbsolutePath.StartsWith('/api/projects/') -and -not $candidate.Query -and -not $candidate.Fragment) {
        $projectEndpoint = $candidate.AbsoluteUri
        break
      }
    }
  }
  $links.Foundry = "https://ai.azure.com/nextgen/r/$($project.id.TrimStart('/'))"
} elseif ($projects.Count -gt 1) {
  Write-Warning 'Multiple Foundry projects found. Configure LabConsole:Foundry:ProjectEndpoint explicitly.'
}
$appName = if ($apps.Count -eq 1) { $apps[0].name } else { $null }
if ($EnableSreAssistant -and $sreAgents.Count -ne 1) { throw 'SRE MCP assistant requires exactly one discovered agent.' }
@{ LabConsole = @{
  Links = $links; ResourceGroup = $ResourceGroup; AppService = $appName
  Operations = @{ Enabled = $false; SubscriptionId = $SubscriptionId; TenantId = $TenantId }
  Health = @{
    Enabled = [bool]$EnableInfrastructureHealth; SubscriptionId = $SubscriptionId; TenantId = $TenantId
    CentralWorkspaceResourceId = $(if ($workspace) { $workspace.id } else { $null })
    AppInsightsWorkspaceResourceId = $applicationWorkspaceId
  }
  Foundry = @{ Enabled = [bool]$EnableFoundryPlayground; ProjectEndpoint = $projectEndpoint }
  Sre = @{
    Enabled = [bool]$EnableSreAssistant; SubscriptionId = $SubscriptionId; TenantId = $TenantId
    AgentName = $(if ($sreAgents.Count -eq 1) { $sreAgents[0].name } else { $null })
    McpExecutable = $SreMcpExecutable
    ModelEndpoint = $SreModelEndpoint; ModelDeployment = $SreModelDeployment
  }
} } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Web console monitoring links written to $OutputPath"