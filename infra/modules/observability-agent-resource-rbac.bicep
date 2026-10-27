targetScope = 'resourceGroup'

@description('System-assigned principal ID of the Azure Copilot Observability Agent.')
param principalId string

@description('Name of the monitored Application Insights component.')
param appInsightsName string

var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, principalId, monitoringReaderRoleId)
  scope: appInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringReaderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
