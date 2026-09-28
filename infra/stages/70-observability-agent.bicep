// =====================================================================================
// Stage Observability Agent (optional) - autonomous alert correlation and investigations.
//
// Depends on Stage A for Application Insights. A dedicated Azure Monitor workspace is
// created in a supported region because the lab's primary region can be unsupported.
// Automatic deep investigation is off by default because it consumes Azure Agent Credits.
// =====================================================================================
targetScope = 'resourceGroup'

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

@description('Tag every resource with this owner.')
param ownerTag string = 'demo-lab'

@description('Supported region for the Observability Agent and its Azure Monitor workspace.')
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
param observabilityAgentLocation string = 'westeurope'

@description('Run billable deep investigations automatically for agent-created issues.')
param enableObservabilityAgentAutomaticInvestigation bool = false

@description('Natural-language guidance for alert correlation and issue creation.')
@maxLength(8192)
param observabilityAgentInstructions string = 'Correlate alerts for the lab application and its dependencies when they describe the same customer impact. Keep unrelated infrastructure alerts separate. Always create an issue for severity 1 or severity 2 agent task failures. Add [OPS-REVIEW] to issue titles.'

var suffix = uniqueString(resourceGroup().id)
var appInsightsName = 'appi-${namePrefix}'
var agentName = 'obs-${namePrefix}-${take(suffix, 5)}'
var monitoringAccountName = 'amw-${namePrefix}-obs'

var commonTags = {
  owner: ownerTag
  purpose: 'azure-monitor-lab'
  costCenter: 'demo'
  feature: 'observability-agent'
}

// Created by Stage A.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

module observabilityAgent '../modules/observability-agent.bicep' = {
  name: 'observability-agent'
  params: {
    name: agentName
    monitoringAccountName: monitoringAccountName
    location: observabilityAgentLocation
    appInsightsId: appInsights.id
    issueCreationInstructions: observabilityAgentInstructions
    enableAutomaticInvestigation: enableObservabilityAgentAutomaticInvestigation
    tags: commonTags
  }
}

module observabilityAgentSubscriptionRbac '../modules/observability-agent-subscription-rbac.bicep' = {
  name: 'observability-agent-subscription-rbac'
  scope: subscription()
  params: {
    principalId: observabilityAgent.outputs.principalId
  }
}

output observabilityAgentName string = observabilityAgent.outputs.name
output observabilityAgentId string = observabilityAgent.outputs.id
output observabilityAgentPortalUrl string = observabilityAgent.outputs.portalUrl
output observabilityAgentMonitoringAccountName string = observabilityAgent.outputs.monitoringAccountName
output automaticInvestigationEnabled bool = enableObservabilityAgentAutomaticInvestigation
