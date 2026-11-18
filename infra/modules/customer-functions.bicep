// Composed from official functions_template_get(servicebus-trigger-csharp-azd),
// infra/core/host/functions-flexconsumption.bicep. Keep Flex deployment storage
// and runtime configuration separate from classic Consumption siteConfig.
param name string
param location string
param identityId string
param identityClientId string
param storageAccountName string
param virtualNetworkSubnetId string
param appInsightsName string
param centralLawId string
param appSettings object
param tags object = {}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}
resource insights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}
resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, identityId, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: insights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: reference(identityId, '2023-01-31').principalId
    principalType: 'ServicePrincipal'
  }
}
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${name}-plan'
  location: location
  tags: tags
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource functions 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identityId}': {} } }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: virtualNetworkSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}deployment'
          authentication: { type: 'UserAssignedIdentity', userAssignedIdentityResourceId: identityId }
        }
      }
      scaleAndConcurrency: { instanceMemoryMB: 2048, maximumInstanceCount: 40 }
      runtime: { name: 'dotnet-isolated', version: '8.0' }
    }
    siteConfig: { minTlsVersion: '1.2', ftpsState: 'Disabled' }
  }
  resource settings 'config' = {
    name: 'appsettings'
    properties: union(appSettings, {
      AzureWebJobsStorage__accountName: storage.name
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__clientId: identityClientId
      APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${identityClientId};Authorization=AAD'
    })
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-central-law'
  scope: functions
  properties: {
    workspaceId: centralLawId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ category: 'FunctionAppLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output name string = functions.name
output id string = functions.id
