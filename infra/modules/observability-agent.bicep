@description('Azure Copilot Observability Agent resource name.')
param name string

@description('Azure Monitor workspace name used to store issues.')
param monitoringAccountName string

@description('Supported Observability Agent region. Must match the Azure Monitor workspace region.')
@allowed([
  'australiaeast'
  'canadacentral'
  'centralus'
  'eastasia'
  'eastus'
  'southcentralus'
  'uksouth'
  'westcentralus'
  'westeurope'
])
param location string = 'westeurope'

@description('Application Insights resource ID monitored by the agent.')
param appInsightsId string

@description('Natural-language guidance for alert correlation and issue creation.')
@maxLength(8192)
param issueCreationInstructions string

@description('Run billable deep investigations automatically for agent-created issues.')
param enableAutomaticInvestigation bool = false

@description('Resource tags.')
param tags object = {}

var issueContributorRoleId = '8d7ecc5c-f27b-43cf-883f-46409d445502'

resource monitoringAccount 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: monitoringAccountName
  location: location
  tags: tags
  properties: {}
}

#disable-next-line BCP081
resource agent 'Microsoft.Monitor/observabilityAgents@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    monitoringAccountId: monitoringAccount.id
    enabled: true
    operations: [
      {
        type: 'IssueCreation'
        mode: 'Auto'
        instructions: issueCreationInstructions
      }
      {
        type: 'Investigation'
        mode: enableAutomaticInvestigation ? 'Auto' : 'Manual'
      }
    ]
  }
}

resource issueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(monitoringAccount.id, agent.id, issueContributorRoleId)
  scope: monitoringAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', issueContributorRoleId)
    principalId: agent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

#disable-next-line BCP081
resource monitoredApplication 'Microsoft.Monitor/observabilityAgents/monitoredResources@2026-05-01-preview' = {
  parent: agent
  name: 'application-insights'
  properties: {
    resourceId: appInsightsId
    enabled: true
    isAutonomous: true
  }
  dependsOn: [
    issueContributor
  ]
}

output id string = agent.id
output name string = agent.name
output principalId string = agent.identity.principalId
output monitoringAccountId string = monitoringAccount.id
output monitoringAccountName string = monitoringAccount.name
output portalUrl string = 'https://portal.azure.com/#resource${agent.id}'
