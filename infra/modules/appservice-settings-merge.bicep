@description('Web App created before this deployment starts.')
param webAppName string

@description('Infrastructure-owned settings to merge with existing runtime settings.')
@secure()
param appSettings object

// This deployment boundary defers the read until the caller's site dependency completes.
module settings './appservice-settings.bicep' = {
  name: 'merge-app-settings'
  params: {
    webAppName: webAppName
    existingAppSettings: list('${resourceId('Microsoft.Web/sites', webAppName)}/config/appsettings', '2023-12-01').properties
    appSettings: appSettings
  }
}
