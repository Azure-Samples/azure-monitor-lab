function Resolve-LabAppInsightsName {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $WebAppName = $env:LAB_WEB_APP_NAME,
    [string] $AppInsightsName
  )

  if ($WebAppName) {
    if ($WebAppName -cnotmatch '^app-[a-zA-Z0-9-]+$') { throw 'The Control Center Web App must use the lab app- naming convention.' }
    $expectedName = 'appi-' + $WebAppName.Substring(4)
    if ($AppInsightsName -and $AppInsightsName -cne $expectedName) { throw 'Application Insights does not match the configured Control Center Web App.' }
    $AppInsightsName = $expectedName
  }
  $json = az resource list --resource-group $ResourceGroup --resource-type Microsoft.Insights/components `
    --query '[].{name:name,tags:tags}' --output json
  if ($LASTEXITCODE -ne 0) { throw 'Could not discover the lab Application Insights target.' }
  $components = @($json | ConvertFrom-Json | Where-Object {
    $_.tags.'amlab-component' -cne 'customer-web-app' -and $_.name -notlike '*-customer'
  })
  if ($AppInsightsName) { $components = @($components | Where-Object name -CEQ $AppInsightsName) }
  if ($components.Count -ne 1) {
    throw "The Control Center Application Insights target was not uniquely resolved in '$ResourceGroup'. Specify -WebAppName or -AppInsightsName; customer telemetry is not an annotation target."
  }
  return [string]$components[0].name
}
