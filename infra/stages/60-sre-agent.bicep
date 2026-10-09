// =====================================================================================
// Stage SRE Agent (optional) - Azure SRE Agent and Azure Monitor connectors.
//
// Depends on Stage A for monitoring resources and Stage B when slot recovery is enabled.
// The agent and its managed identity are hard pinned to swedencentral by the shared module.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Grant the SRE Agent permission to reverse the opt-in broken-slot scenario.')
param enableSlotFailureScenario bool = false

var suffix = uniqueString(resourceGroup().id)
var appInsightsName = 'appi-${namePrefix}-${take(suffix, 5)}'
var centralLawName = 'law-${namePrefix}-central-${take(suffix, 5)}'
var sreAgentName = 'sre-${namePrefix}-${take(suffix, 5)}'
var webAppName = 'app-${namePrefix}-${take(suffix, 5)}'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
}

// Created by Stage A.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// Created by Stage A.
resource centralLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: centralLawName
}

resource webApp 'Microsoft.Web/sites@2023-12-01' existing = if (enableSlotFailureScenario) {
  name: webAppName
}

module sreAgent '../modules/sre-agent.bicep' = {
  name: 'sre-agent'
  params: {
    name: sreAgentName
    appInsightsId: appInsights.id
    appInsightsAppId: appInsights.properties.ApplicationId
    appInsightsConnectionString: appInsights.properties.ConnectionString
    logAnalyticsId: centralLaw.id
    managedResourceGroupId: resourceGroup().id
    webAppId: enableSlotFailureScenario ? webApp!.id : ''
    enableSlotFailureScenario: enableSlotFailureScenario
    tags: commonTags
  }
}

module sreAgentSubscriptionRbac '../modules/sre-agent-subscription-rbac.bicep' = {
  name: 'sre-agent-subscription-rbac'
  scope: subscription()
  params: {
    principalId: sreAgent.outputs.systemPrincipalId
  }
}

output sreAgentName string = sreAgent.outputs.name
output sreAgentEndpoint string = sreAgent.outputs.endpoint
output sreAgentPortalUrl string = sreAgent.outputs.portalUrl