@description('App Service Plan name.')
param planName string

@description('Web App name (must be globally unique).')
param webAppName string

@description('Region.')
param location string

@description('App Insights connection string.')
param appInsightsConnectionString string

@description('App Insights instrumentation key (legacy fallback).')
param appInsightsInstrumentationKey string

@description('Central LAW for diagnostic settings.')
param centralLawId string

@description('Optional: Storage Account resource ID for the "archive" fan-out diag setting. Empty = skip.')
param diagStorageAccountId string = ''

@description('Optional: Event Hub authorization rule ID + hub name for the SIEM fan-out diag setting. Empty = skip.')
param diagEventHubAuthRuleId string = ''

@description('Event hub name (only used if diagEventHubAuthRuleId is supplied).')
param diagEventHubName string = ''

@description('Resource tags.')
param tags object = {}

@description('Provision the opt-in broken deployment slot scenario. Requires Standard S1 instead of Basic B1.')
param enableSlotFailureScenario bool = false

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: enableSlotFailureScenario ? 'S1' : 'B1'
    tier: enableSlotFailureScenario ? 'Standard' : 'Basic'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/'
    }
  }
}

module appSettings './appservice-settings.bicep' = {
  name: 'app-settings'
  params: {
    webAppName: site.name
    existingAppSettings: list('${site.id}/config/appsettings', '2023-12-01').properties
    appSettings: {
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
      APPINSIGHTS_INSTRUMENTATIONKEY: appInsightsInstrumentationKey
      ApplicationInsightsAgent_EXTENSION_VERSION: '~3'
      XDT_MicrosoftApplicationInsights_Mode: 'recommended'
      XDT_MicrosoftApplicationInsights_PreemptSdk: '1'
      InstrumentationEngine_EXTENSION_VERSION: 'disabled'
      XDT_MicrosoftApplicationInsightsJava: '0'
      APPINSIGHTS_PROFILERFEATURE_VERSION: '1.0.0'
      DiagnosticServices_EXTENSION_VERSION: '~3'
      APPINSIGHTS_SNAPSHOTFEATURE_VERSION: '1.0.0'
      SnapshotDebugger_EXTENSION_VERSION: '~1'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
      WEBSITE_HTTPLOGGING_RETENTION_DAYS: '3'
      LabConsole__SlotScenarioEnabled: string(enableSlotFailureScenario)
      LabConsole__ForceOutage: 'false'
      WEBSITE_SWAP_WARMUP_PING_PATH: '/api/slot-warmup'
      WEBSITE_SWAP_WARMUP_PING_STATUSES: '200'
    }
  }
}

resource brokenSlot 'Microsoft.Web/sites/slots@2023-12-01' = if (enableSlotFailureScenario) {
  parent: site
  name: 'broken'
  location: location
  tags: union(tags, { 'amlab-scenario': 'broken-slot' })
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      healthCheckPath: '/api/slot-warmup'
      appSettings: [
        { name: 'LabConsole__SlotScenarioEnabled', value: 'true' }
        { name: 'LabConsole__ForceOutage', value: 'true' }
        { name: 'WEBSITE_SWAP_WARMUP_PING_PATH', value: '/api/slot-warmup' }
        { name: 'WEBSITE_SWAP_WARMUP_PING_STATUSES', value: '200' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
      ]
    }
  }
}

resource diagSite 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: site
  name: 'send-to-central-law'
  properties: {
    workspaceId: centralLawId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// FEATURE — Diagnostic-setting fan-out #2: archive copy in cool Blob storage.
resource diagSiteStorage 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(diagStorageAccountId)) {
  scope: site
  name: 'archive-to-blob'
  properties: {
    storageAccountId: diagStorageAccountId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

// FEATURE — Diagnostic-setting fan-out #3: real-time stream to an Event Hub
// (downstream SIEM/SOAR can consume the AMQP/Kafka stream).
resource diagSiteEventHub 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(diagEventHubAuthRuleId)) {
  scope: site
  name: 'stream-to-eventhub'
  properties: {
    eventHubAuthorizationRuleId: diagEventHubAuthRuleId
    eventHubName: diagEventHubName
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output webAppId string = site.id
output webAppName string = site.name
output defaultHost string = site.properties.defaultHostName
output planId string = plan.id
output brokenSlotId string = enableSlotFailureScenario ? brokenSlot!.id : ''
