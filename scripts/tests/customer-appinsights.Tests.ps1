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

foreach ($entry in @(
  @{ Name = 'main'; Module = $customerSite[0] },
  @{ Name = '10-workloads'; Module = $workloadSite[0] }
)) {
  $resources = $entry.Module.properties.template.resources
  $settings = @($resources | Where-Object name -eq 'customer-web-app-settings')
  Assert-True ($settings.Count -eq 1) "$($entry.Name) must deploy customer app settings separately."
  $siteDependency = "[resourceId('Microsoft.Resources/deployments', 'customer-web-app')]"
  Assert-True ($settings[0].dependsOn -contains $siteDependency) "$($entry.Name) customer settings must depend on site creation."
  $outerParameters = $settings[0].properties.parameters | ConvertTo-Json -Depth 10 -Compress
  Assert-True ($outerParameters -notmatch '\blist\(') "$($entry.Name) must not read customer settings before the nested settings deployment starts."
  Assert-True ($settings[0].properties.expressionEvaluationOptions.scope -eq 'inner') 'The deferred settings deployment must evaluate expressions in its own scope.'
  Assert-True ($settings[0].properties.parameters.webAppName.value -match "\.outputs\.name\.value") "$($entry.Name) must pass the created site's name into the nested settings deployment."
  $readTemplate = $settings[0].properties.template
  Assert-True ($readTemplate.parameters.appSettings.type -eq 'secureObject' -and -not $readTemplate.outputs) 'The deferred settings deployment must keep intended settings secure and expose no outputs.'
  $merge = @($readTemplate.resources | Where-Object name -eq 'merge-app-settings')
  Assert-True ($merge.Count -eq 1) 'The deferred settings deployment must invoke the separate settings writer.'
  $existingSettings = $merge[0].properties.parameters.existingAppSettings.value
  Assert-True ($existingSettings -ceq "[list(format('{0}/config/appsettings', resourceId('Microsoft.Web/sites', parameters('webAppName'))), '2023-12-01').properties]") 'Existing settings must be read only inside the deferred deployment scope.'
  $settingsTemplate = $merge[0].properties.template
  Assert-True ($settingsTemplate.parameters.existingAppSettings.type -eq 'secureObject' -and $settingsTemplate.parameters.appSettings.type -eq 'secureObject') 'Existing and intended customer settings must remain secure inputs.'
  $settingsResource = @($settingsTemplate.resources | Where-Object type -eq 'Microsoft.Web/sites/config')
  Assert-True ($settingsResource.Count -eq 1 -and $settingsResource[0].properties -ceq "[union(parameters('existingAppSettings'), parameters('appSettings'))]") 'Customer settings must preserve runtime-owned values without a list self-reference.'
  $brokenSlot = @($resources | Where-Object name -eq 'customer-broken-slot')
  Assert-True ($brokenSlot.Count -eq 1 -and $brokenSlot[0].dependsOn -contains "[resourceId('Microsoft.Resources/deployments', 'customer-web-app-settings')]") 'The broken slot must wait for the customer settings merge.'
}

Write-Host 'Customer Application Insights isolation checks passed.'
