[CmdletBinding()]
param([string] $CompiledDirectory = (Join-Path $PSScriptRoot '..\..\infra'))
$ErrorActionPreference = 'Stop'

function Assert-True([bool] $Condition, [string] $Message) {
  if (-not $Condition) { throw $Message }
}

$main = Get-Content (Join-Path $CompiledDirectory 'main.json') -Raw | ConvertFrom-Json
$foundation = Get-Content (Join-Path $CompiledDirectory 'stages\00-foundation.json') -Raw | ConvertFrom-Json
$workloads = Get-Content (Join-Path $CompiledDirectory 'stages\10-workloads.json') -Raw | ConvertFrom-Json

foreach ($entry in @(
  @{ Name = 'main'; Template = $main },
  @{ Name = '00-foundation'; Template = $foundation }
)) {
  $template = $entry.Template
  $customerAppInsights = @($template.resources | Where-Object name -eq 'appi-customer')
  Assert-True ($customerAppInsights.Count -eq 1) "$($entry.Name) must deploy one customer Application Insights module."
  Assert-True ($customerAppInsights[0].condition -match "parameters\('enableSlotFailureScenario'\)") "$($entry.Name) must gate customer Application Insights with the customer app."
  Assert-True ($customerAppInsights[0].properties.parameters.workspaceId.value -match 'law-appinsights') "$($entry.Name) customer Application Insights must reuse the existing App Insights workspace."

  $observability = @($template.resources | Where-Object name -eq 'appinsights-observability')
  Assert-True ($observability.Count -eq 1) "$($entry.Name) must retain the Application Insights observability deployment."
  $customerBinding = $observability[0].properties.parameters.customerAppInsightsId | ConvertTo-Json -Depth 5 -Compress
  Assert-True ($customerBinding -match 'enableSlotFailureScenario' -and $customerBinding -match 'appi-customer') "$($entry.Name) must bind customer usage observability to the customer component when enabled."
}

$customerSite = @($main.resources | Where-Object name -eq 'customer-webapp')
Assert-True ($customerSite.Count -eq 1) 'Main deployment must contain the customer Web App module.'
Assert-True ($customerSite[0].properties.parameters.appInsightsConnectionString.value -match 'appi-customer') 'Main customer app must use the customer Application Insights connection string.'
Assert-True ($customerSite[0].properties.parameters.appInsightsInstrumentationKey.value -match 'appi-customer') 'Main customer app must use the customer Application Insights instrumentation key.'

$workloadSite = @($workloads.resources | Where-Object name -eq 'customer-webapp')
Assert-True ($workloadSite.Count -eq 1) 'Stage B must contain the customer Web App module.'
Assert-True ($workloadSite[0].properties.parameters.appInsightsConnectionString.value -match 'customerAppInsights') 'Stage B customer app must use the customer Application Insights connection string.'
Assert-True ($workloadSite[0].properties.parameters.appInsightsInstrumentationKey.value -match 'customerAppInsights') 'Stage B customer app must use the customer Application Insights instrumentation key.'

Write-Host 'Customer Application Insights isolation checks passed.'
