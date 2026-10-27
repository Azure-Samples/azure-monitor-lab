@description('Web App created by the parent deployment.')
param webAppName string

@description('Existing settings read by the parent after creating the Web App, avoiding a self-reference in the settings resource.')
@secure()
param existingAppSettings object

@description('Infrastructure-owned telemetry settings to merge with existing settings.')
@secure()
param appSettings object

resource site 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource settings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: site
  name: 'appsettings'
  properties: union(existingAppSettings, appSettings)
}
