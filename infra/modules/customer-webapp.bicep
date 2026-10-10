@description('Customer-facing Web App name.')
param webAppName string

@description('Region for the customer-facing Web App.')
param location string

@description('Resource ID of the existing App Service plan.')
param serverFarmResourceId string

@secure()
@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Application Insights instrumentation key.')
param appInsightsInstrumentationKey string

@description('Central Log Analytics workspace resource ID.')
param centralLawId string

@description('Resource tags.')
param tags object = {}

module site 'br/public:avm/res/web/site:0.24.0' = {
  name: 'customer-web-app'
  params: {
    name: webAppName
    location: location
    kind: 'app,linux'
    serverFarmResourceId: serverFarmResourceId
    enabled: true
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      systemAssigned: true
    }
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/healthz'
    }
    enableTelemetry: false
    tags: union(tags, { 'amlab-component': 'customer-web-app' })
  }
}

module appSettings './appservice-settings.bicep' = {
  name: 'customer-web-app-settings'
  params: {
    webAppName: site.outputs.name
    existingAppSettings: list('${resourceId('Microsoft.Web/sites', webAppName)}/config/appsettings', '2023-12-01').properties
    appSettings: {
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
      APPINSIGHTS_INSTRUMENTATIONKEY: appInsightsInstrumentationKey
      ApplicationInsightsAgent_EXTENSION_VERSION: '~3'
      XDT_MicrosoftApplicationInsights_Mode: 'recommended'
      XDT_MicrosoftApplicationInsights_PreemptSdk: '1'
      InstrumentationEngine_EXTENSION_VERSION: 'disabled'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
      LabConsole__CustomerAppMode: 'true'
      LabConsole__SlotScenarioEnabled: 'true'
      LabConsole__ForceOutage: 'false'
      WEBSITE_SWAP_WARMUP_PING_PATH: '/api/slot-warmup'
      WEBSITE_SWAP_WARMUP_PING_STATUSES: '200'
    }
  }
}

module brokenSlot 'br/public:avm/res/web/site/slot:0.5.0' = {
  name: 'customer-broken-slot'
  params: {
    appName: webAppName
    name: 'broken'
    kind: 'app,linux'
    location: location
    serverFarmResourceId: serverFarmResourceId
    enabled: true
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/api/slot-warmup'
    }
    enableTelemetry: false
    tags: union(tags, { 'amlab-scenario': 'customer-app-broken-slot' })
  }
  dependsOn: [appSettings]
}

resource customerSite 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-central-law'
  scope: customerSite
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
  dependsOn: [site]
}

output webAppId string = site.outputs.resourceId
output webAppName string = site.outputs.name
output defaultHost string = site.outputs.defaultHostname
