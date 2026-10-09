@description('SRE Agent resource name.')
param name string

@description('Application Insights resource ID used by the agent connector and telemetry.')
param appInsightsId string

@description('Application Insights application ID.')
param appInsightsAppId string

@secure()
@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Log Analytics workspace resource ID used by the agent connector.')
param logAnalyticsId string

@description('Resource group ID the agent can investigate.')
param managedResourceGroupId string

@description('Resource tags.')
param tags object = {}

@description('Web App resource ID containing the opt-in broken slot.')
param webAppId string = ''

@description('Grant the SRE Agent action identity permission to reverse the broken-slot swap.')
param enableSlotFailureScenario bool = false

var location = 'swedencentral'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-${name}'
  location: location
  tags: tags
  properties: {
    isolationScope: 'Regional'
  }
}

resource reader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, identity.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, identity.id, '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, identity.id, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = if (enableSlotFailureScenario) {
  name: last(split(webAppId, '/'))
}

resource slotRollbackRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (enableSlotFailureScenario) {
  name: guid(resourceGroup().id, 'sre-agent-slot-rollback')
  properties: {
    roleName: 'Lab SRE Slot Rollback ${take(uniqueString(resourceGroup().id), 8)}'
    description: 'Read the lab Web App slots and reverse the controlled broken-slot swap.'
    type: 'CustomRole'
    assignableScopes: [resourceGroup().id]
    permissions: [
      {
        actions: [
          'Microsoft.Web/sites/read'
          'Microsoft.Web/sites/slots/read'
          'Microsoft.Web/sites/slots/slotsswap/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource slotRollbackAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableSlotFailureScenario) {
  name: guid(webApp!.id, identity.id, slotRollbackRole!.id)
  scope: webApp!
  properties: {
    roleDefinitionId: slotRollbackRole!.id
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

#disable-next-line BCP081
resource agent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: name
  location: location
  tags: union(tags, {
    'hidden-link: /app-insights-resource-id': appInsightsId
  })
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: identity.id
      managedResources: [managedResourceGroupId]
    }
    actionConfiguration: {
      accessLevel: 'Low'
      identity: identity.id
      mode: 'Review'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
    upgradeChannel: 'Preview'
    monthlyAgentUnitLimit: 1000
    defaultModel: {
      provider: 'MicrosoftFoundry'
      name: 'Automatic'
    }
    experimentalSettings: {
      EnableWorkspaceTools: true
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
  }
  dependsOn: [
    reader
    monitoringReader
    logAnalyticsReader
    slotRollbackAccess
  ]
}

resource systemReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, agent.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, agent.id, '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource systemLogAnalyticsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedResourceGroupId, agent.id, '73c42c96-874c-492b-b04d-ab87d138a893')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployerAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(agent.id, deployer().objectId, 'e79298df-d852-4c6d-84f9-5d13249d1e55')
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')
    principalId: deployer().objectId
  }
}

resource identityAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(agent.id, identity.id, 'e79298df-d852-4c6d-84f9-5d13249d1e55')
  scope: agent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      resource: {
        name: last(split(appInsightsId, '/'))
      }
      appId: appInsightsAppId
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsId
    extendedProperties: {
      armResourceId: logAnalyticsId
      resource: {
        name: last(split(logAnalyticsId, '/'))
      }
    }
    identity: 'system'
  }
  dependsOn: [appInsightsConnector]
}

#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'AzureMonitor'
    dataSource: subscription().id
    extendedProperties: {
      armResourceId: subscription().id
      lookbackDays: 7
    }
    identity: 'system'
  }
  dependsOn: [logAnalyticsConnector]
}

output name string = agent.name
output id string = agent.id
output principalId string = identity.properties.principalId
output systemPrincipalId string = agent.identity.principalId
output endpoint string = agent.properties.agentEndpoint
output portalUrl string = 'https://sre.azure.com/#/agent/${subscription().subscriptionId}/${resourceGroup().name}/${agent.name}'
